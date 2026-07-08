import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import * as net from "node:net";
import * as fs from "node:fs";
import * as path from "node:path";
import * as crypto from "node:crypto";

/**
 * pi-nvim: Exposes a unix socket so external tools (like a neovim plugin)
 * can send prompts/context into a running interactive pi session.
 *
 * Repo: https://github.com/carderne/pi-nvim
 *
 * Protocol: newline-delimited JSON over a unix socket.
 *
 * Commands:
 *   { "type": "prompt", "message": "..." }
 *   { "type": "prompt", "message": "...", "images": [...] }
 *   { "type": "chat", "message": "..." }        -- streaming, keeps conn open
 *   { "type": "ping" }
 *
 * Responses:
 *   { "ok": true }
 *   { "ok": true, "type": "pong" }
 *   { "ok": false, "error": "..." }
 *
 * Streaming responses (for "chat" type):
 *   { "type": "new_message" }                       -- new assistant message started (new chat entry)
 *   { "type": "token", "content": "..." }          -- delta text (append on neovim side)
 *   { "type": "done", "content": "full text" }      -- message complete (replaces with full)
 *   { "type": "agent_done" }                        -- agent loop finished
 *
 * Socket path: /tmp/pi-nvim-<hash-of-cwd>.sock
 * A symlink at /tmp/pi-nvim-latest.sock always points to the most recently
 * started session, so neovim can just connect there if there's only one.
 *
 * The socket path for a given cwd is also written to /tmp/pi-nvim-sockets/<hash>
 * as a plain text file containing the cwd, so neovim can list all running sessions.
 */

function cwdHash(cwd: string): string {
  return crypto.createHash("md5").update(cwd).digest("hex").slice(0, 12);
}

function getSocketPath(cwd: string): string {
  return path.join(SOCKETS_DIR, `${cwdHash(cwd)}-${process.pid}.sock`);
}

const SOCKETS_DIR = "/tmp/pi-nvim-sockets";
const LATEST_LINK = "/tmp/pi-nvim-latest.sock";

/** Extract text content from an assistant message event. */
function extractTokenText(event: any): string {
  if (!event) return "";
  // OpenAI / Anthropic streaming deltas
  if (event.delta?.text) return event.delta.text;
  if (event.delta?.content?.text) return event.delta.content.text;
  if (event.text) return event.text;
  if (event.content?.text) return event.content.text;
  if (typeof event.delta === "string") return event.delta;
  if (typeof event.content === "string") return event.content;
  // Anthropic content_block_delta
  if (event.delta?.partial_json) return event.delta.partial_json;
  return "";
}

export default function (pi: ExtensionAPI) {
  let server: net.Server | null = null;
  let socketPath: string | null = null;

  // Track active streaming connections and accumulated response text
  const activeChatConnections = new Set<net.Socket>();
  let currentResponseText = "";
  let isStreaming = false;

  /**
   * Extract the delta between incoming text and what we've already sent.
   * Handles three streaming event patterns:
   * 1. Delta: currentResponseText is a prefix of text → send the suffix
   * 2. Full-text reset: text is a prefix of (or equal to) currentResponseText → send nothing
   * 3. Replacement: no prefix relationship → send the whole text, reset accumulator
   *
   * Never corrupts currentResponseText by appending mismatched text.
   */
  function extractDelta(text: string, current: string): { token: string; newCurrent: string } {
    if (!current) {
      return { token: text, newCurrent: text };
    }
    if (text === current) {
      return { token: "", newCurrent: text };
    }
    if (text.startsWith(current)) {
      return { token: text.slice(current.length), newCurrent: text };
    }
    if (current.startsWith(text)) {
      // Full-text snapshot that's shorter than what we have — update but send nothing
      return { token: "", newCurrent: text };
    }
    // No clean prefix relationship — treat as a replacement (shouldn't happen in normal streaming)
    return { token: text, newCurrent: text };
  }

  // Stream assistant message tokens to all active chat connections.
  pi.on("message_update", async (_event, _ctx) => {
    if (activeChatConnections.size === 0) return;
    const ev = (_event as any).assistantMessageEvent;
    const text = extractTokenText(ev);
    if (!text) return;

    const { token, newCurrent } = extractDelta(text, currentResponseText);
    currentResponseText = newCurrent;

    if (!token) return;
    const payload = JSON.stringify({ type: "token", content: token }) + "\n";
    for (const conn of activeChatConnections) {
      try {
        conn.write(payload);
      } catch {
        // Connection dead, will clean up on error
      }
    }
  });

  // When a new assistant message starts, tell neovim to create a fresh
  // chat entry. This keeps each assistant message turn separate so that
  // text doesn't get mixed up when tool calls happen in between.
  pi.on("message_start", async (_event, _ctx) => {
    if (activeChatConnections.size === 0) return;
    const msg = (_event as any).message;
    if (msg?.role !== "assistant") return;

    currentResponseText = "";
    const payload = JSON.stringify({ type: "new_message" }) + "\n";
    for (const conn of activeChatConnections) {
      try {
        conn.write(payload);
      } catch {}
    }
  });

  // Signal message completion with the final full text.
  // Do NOT reset currentResponseText here — the next message_start or
  // agent_end will handle it.
  pi.on("message_end", async (_event, _ctx) => {
    if (activeChatConnections.size === 0) return;
    const donePayload = JSON.stringify({
      type: "done",
      content: currentResponseText,
    }) + "\n";
    for (const conn of activeChatConnections) {
      try {
        conn.write(donePayload);
      } catch {}
    }
  });

  // Signal agent loop completion and close connections
  pi.on("agent_end", async (_event, _ctx) => {
    if (activeChatConnections.size === 0) return;
    const donePayload = JSON.stringify({ type: "agent_done" }) + "\n";
    for (const conn of activeChatConnections) {
      try {
        conn.write(donePayload);
        conn.end();
      } catch {}
    }
    activeChatConnections.clear();
    currentResponseText = "";
    isStreaming = false;
  });

  pi.on("session_start", async (_event, ctx) => {
    const cwd = ctx.cwd;
    // Ensure sockets directory exists
    try {
      fs.mkdirSync(SOCKETS_DIR, { recursive: true });
    } catch {}

    socketPath = getSocketPath(cwd);

    // Clean up stale socket
    try {
      fs.unlinkSync(socketPath);
    } catch {}

    server = net.createServer((conn) => {
      let buffer = "";
      conn.on("data", (data) => {
        buffer += data.toString();
        let newlineIdx: number;
        while ((newlineIdx = buffer.indexOf("\n")) !== -1) {
          const line = buffer.slice(0, newlineIdx).trim();
          buffer = buffer.slice(newlineIdx + 1);
          if (!line) continue;
          handleMessage(line, conn, cwd);
        }
      });
      conn.on("error", () => {
        activeChatConnections.delete(conn);
      });
      conn.on("close", () => {
        activeChatConnections.delete(conn);
      });
    });

    server.listen(socketPath, () => {
      // Update latest symlink
      try {
        fs.unlinkSync(LATEST_LINK);
      } catch {}
      try {
        fs.symlinkSync(socketPath!, LATEST_LINK);
      } catch {}

      // Register in sockets directory for discovery
      try {
        fs.mkdirSync(SOCKETS_DIR, { recursive: true });
        // Write a manifest file alongside the socket for discovery
        fs.writeFileSync(
          socketPath + ".info",
          JSON.stringify({
            cwd,
            pid: process.pid,
            startedAt: new Date().toISOString(),
          }),
        );
      } catch {}
    });

    server.on("error", (err) => {
      ctx.ui.notify(`pi-nvim error: ${err.message}`, "error");
    });
  });

  function handleMessage(raw: string, conn: net.Socket, _cwd: string) {
    try {
      const msg = JSON.parse(raw);

      if (msg.type === "ping") {
        respond(conn, { ok: true, type: "pong" });
        return;
      }

      if (msg.type === "prompt" && typeof msg.message === "string") {
        // Exit kitty's scrollback viewer by switching to private screen mode
        // and back. This snaps to the bottom without clearing scrollback history.
        process.stdout.write("\x1b[?1049h\x1b[?1049l");
        pi.sendUserMessage(msg.message, { deliverAs: "followUp" });
        respond(conn, { ok: true });
        return;
      }

      if (msg.type === "chat" && typeof msg.message === "string") {
        process.stdout.write("\x1b[?1049h\x1b[?1049l");

        // Acknowledge that we're starting the stream
        respond(conn, { ok: true, type: "chat_started" });

        // Register this connection for streaming updates
        activeChatConnections.add(conn);
        currentResponseText = "";
        isStreaming = true;

        // Send the message to pi
        pi.sendUserMessage(msg.message, { deliverAs: "followUp" });
        return;
      }

      respond(conn, { ok: false, error: `Unknown command type: ${msg.type}` });
    } catch (e: any) {
      respond(conn, { ok: false, error: `Parse error: ${e.message}` });
    }
  }

  function respond(conn: net.Socket, obj: any) {
    try {
      conn.write(JSON.stringify(obj) + "\n");
    } catch {}
  }

  function cleanup() {
    // Close all active chat connections
    for (const conn of activeChatConnections) {
      try {
        conn.end();
      } catch {}
    }
    activeChatConnections.clear();

    if (server) {
      server.close();
      server = null;
    }
    try {
      fs.unlinkSync(socketPath!);
    } catch {}
    try {
      // Clean up latest symlink if it points to us
      const target = fs.readlinkSync(LATEST_LINK);
      if (target === socketPath) fs.unlinkSync(LATEST_LINK);
    } catch {}
    try {
      fs.unlinkSync(socketPath + ".info");
    } catch {}
  }

  pi.on("session_shutdown", async () => {
    cleanup();
  });

  // Also clean up on process exit
  process.on("exit", cleanup);

  pi.registerCommand("pi-nvim-info", {
    description: "Show pi-nvim socket path",
    handler: async (_args, ctx) => {
      if (socketPath) {
        ctx.ui.notify(`Socket: ${socketPath}`, "info");
      } else {
        ctx.ui.notify("pi-nvim not active", "warning");
      }
    },
  });
}
