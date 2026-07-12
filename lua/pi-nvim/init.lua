local M = {}

--- @class pi_nvim.Config
--- @field socket_path string|nil  Override socket path (default: auto-discover)
--- @field set_default_keymaps boolean|nil  Whether to create the default <leader>p mappings (default: true)
--- @field use_chat boolean|nil  Whether to open chat window for :PiSend and :Pi commands (default: false)
--- @field include_diagnostics boolean|nil  Whether to include LSP diagnostics by default (default: false)
M.config = {
  socket_path = nil,
  set_default_keymaps = true,
  use_chat = false,
  include_diagnostics = false,
}

--- @param opts pi_nvim.Config|nil
function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", M.config, opts or {})

  -- Auto-reload buffers when files are changed externally (e.g. by pi agent).
  -- Only polls when a pi session is reachable. Respects existing autoread setting.
  if not vim.o.autoread then
    vim.o.autoread = true
  end
  local reload_timer = vim.uv.new_timer()
  reload_timer:start(0, 1000, vim.schedule_wrap(function()
    if M.get_socket_path() then
      pcall(vim.cmd, "silent! checktime")
    end
  end))

  -- Commands
  vim.api.nvim_create_user_command("PiSend", function()
    M.prompt()
  end, { desc = "Send a prompt to pi" })

  vim.api.nvim_create_user_command("PiSendFile", function()
    M.send_file()
  end, { desc = "Send current file to pi with a prompt" })

  vim.api.nvim_create_user_command("PiSendSelection", function()
    M.send_selection()
  end, { range = true, desc = "Send visual selection to pi with a prompt" })

  vim.api.nvim_create_user_command("PiSendBuffer", function()
    M.send_buffer()
  end, { desc = "Send entire buffer to pi with a prompt" })

  vim.api.nvim_create_user_command("PiSendDiagnostics", function()
    M.send_diagnostics()
  end, { desc = "Send LSP diagnostics to pi with a prompt" })

  -- Quiet / fire-and-forget commands (no chat window)
  vim.api.nvim_create_user_command("PiSendQuiet", function()
    M.prompt_quiet()
  end, { desc = "Send a prompt to pi (no chat)" })

  vim.api.nvim_create_user_command("PiSendFileQuiet", function()
    M.send_file_quiet()
  end, { desc = "Send current file to pi with a prompt (no chat)" })

  vim.api.nvim_create_user_command("PiSendSelectionQuiet", function()
    M.send_selection_quiet()
  end, { range = true, desc = "Send visual selection to pi with a prompt (no chat)" })

  vim.api.nvim_create_user_command("PiSendBufferQuiet", function()
    M.send_buffer_quiet()
  end, { desc = "Send entire buffer to pi with a prompt (no chat)" })

  vim.api.nvim_create_user_command("PiSendDiagnosticsQuiet", function()
    M.send_diagnostics_quiet()
  end, { desc = "Send LSP diagnostics to pi with a prompt (no chat)" })

  vim.api.nvim_create_user_command("PiChat", function(args)
    local chat = require("pi-nvim.chat")
    if args.args and args.args ~= "" then
      chat.open(args.args)
    else
      chat.open()
    end
  end, { nargs = "?", desc = "Open pi chat window" })

  vim.api.nvim_create_user_command("PiChatToggle", function()
    require("pi-nvim.chat").toggle()
  end, { desc = "Toggle pi chat window" })

  vim.api.nvim_create_user_command("PiChatClear", function()
    require("pi-nvim.chat").clear()
  end, { desc = "Clear pi chat history" })

  vim.api.nvim_create_user_command("PiChatSelection", function()
    local ui = require("pi-nvim.ui")
    local selection = ui.capture_selection()
    if selection then
      require("pi-nvim.chat").open_with_selection(selection)
    else
      vim.notify("No visual selection found", vim.log.levels.WARN)
    end
  end, { range = true, desc = "Open chat with visual selection" })

  vim.api.nvim_create_user_command("Pi", function(args)
    local ui = require("pi-nvim.ui")
    local selection = nil
    if args.range == 2 then
      selection = ui.capture_selection()
    end
    ui.open({ selection = selection })
  end, { range = true, desc = "Open pi send dialog" })

  if M.config.set_default_keymaps then
    -- Normal mode: open the dialog
    vim.keymap.set("n", "<leader>p", ":Pi<CR>", { silent = true, desc = "Send to pi" })
    -- Visual mode: open chat directly with selection (if use_chat) else dialog
    vim.keymap.set("v", "<leader>p", function()
      if M.config.use_chat then
        vim.cmd("PiChatSelection")
      else
        vim.cmd("'<,'>Pi")
      end
    end, { silent = true, desc = "Send selection to pi" })
  end

  vim.api.nvim_create_user_command("PiPing", function()
    M.ping()
  end, { desc = "Ping the pi session" })

  vim.api.nvim_create_user_command("PiSessions", function()
    M.list_sessions()
  end, { desc = "List running pi sessions" })
end

--- Resolve the socket path to use.
--- Priority: config override > cwd-based > latest symlink
--- @return string|nil
function M.get_socket_path()
  if M.config.socket_path then
    return M.config.socket_path
  end

  local sockets_dir = "/tmp/pi-nvim-sockets"
  local cwd = vim.uv.cwd()

  -- Scan the sockets directory for .info files
  local ok, files = pcall(vim.fn.glob, sockets_dir .. "/*.info", false, true)
  if ok and files then
    -- First pass: exact cwd match, prefer newest socket
    local best_sock = nil
    local best_mtime = 0
    for _, info_path in ipairs(files) do
      local content_ok, content = pcall(vim.fn.readfile, info_path)
      if content_ok and content and content[1] then
        local parsed_ok, info = pcall(vim.json.decode, content[1])
        if parsed_ok and info then
          local sock = info_path:sub(1, -6) -- strip ".info"
          local stat = vim.uv.fs_stat(sock)
          if info.cwd == cwd and stat then
            if stat.mtime.sec > best_mtime then
              best_mtime = stat.mtime.sec
              best_sock = sock
            end
          end
        end
      end
    end
    if best_sock then return best_sock end

    -- Second pass: any live session (newest)
    for _, info_path in ipairs(files) do
      local sock = info_path:sub(1, -6)
      local stat = vim.uv.fs_stat(sock)
      if stat then
        if stat.mtime.sec > best_mtime then
          best_mtime = stat.mtime.sec
          best_sock = sock
        end
      end
    end
    if best_sock then return best_sock end
  end

  -- Fall back to latest symlink
  local latest = "/tmp/pi-nvim-latest.sock"
  if vim.uv.fs_stat(latest) then
    return latest
  end

  return nil
end

--- Collect LSP diagnostics for the current buffer or a range.
--- @param bufnr number|nil
--- @param start_line number|nil  1-based
--- @param end_line number|nil  1-based
--- @return table
function M.get_diagnostics(bufnr, start_line, end_line)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local diagnostics = vim.diagnostic.get(bufnr)
  if not diagnostics or #diagnostics == 0 then
    return {}
  end

  -- Filter by range if provided
  if start_line and end_line then
    diagnostics = vim.tbl_filter(function(d)
      local lnum = d.lnum + 1 -- convert to 1-based
      return lnum >= start_line and lnum <= end_line
    end, diagnostics)
  end

  return diagnostics
end

--- Format diagnostics as a readable string.
--- @param diagnostics table
--- @param file string|nil
--- @return string
function M.format_diagnostics(diagnostics, file)
  if not diagnostics or #diagnostics == 0 then
    return "No diagnostics found."
  end

  local parts = {}
  table.insert(parts, "Diagnostics:")

  for _, d in ipairs(diagnostics) do
    local severity = "?"
    if d.severity == vim.diagnostic.severity.ERROR then
      severity = "ERROR"
    elseif d.severity == vim.diagnostic.severity.WARN then
      severity = "WARN"
    elseif d.severity == vim.diagnostic.severity.INFO then
      severity = "INFO"
    elseif d.severity == vim.diagnostic.severity.HINT then
      severity = "HINT"
    end

    local line = d.lnum + 1
    local col = d.col + 1
    local source = d.source or ""
    local code = d.code and (" [" .. tostring(d.code) .. "]") or ""
    local message = d.message:gsub("\n", " ")

    table.insert(parts, string.format("  Line %d:%d [%s%s] %s", line, col, severity, code, message))
    if source ~= "" then
      table.insert(parts, string.format("    (from %s)", source))
    end
  end

  return table.concat(parts, "\n")
end

--- Send a raw JSON message to the pi socket and call cb with the parsed response.
--- @param msg table
--- @param cb fun(err: string|nil, response: table|nil)|nil
function M.send_raw(msg, cb)
  local sock_path = M.get_socket_path()
  if not sock_path then
    local err = "No pi session found. Is pi running with pi-nvim extension?"
    vim.notify(err, vim.log.levels.ERROR)
    if cb then cb(err, nil) end
    return
  end

  local client = vim.uv.new_pipe(false)
  if not client then
    local err = "Failed to create pipe"
    vim.notify(err, vim.log.levels.ERROR)
    if cb then cb(err, nil) end
    return
  end

  client:connect(sock_path, function(err)
    if err then
      vim.schedule(function()
        vim.notify("Failed to connect to pi: " .. err, vim.log.levels.ERROR)
        if cb then cb(err, nil) end
      end)
      return
    end

    local payload = vim.json.encode(msg) .. "\n"
    client:write(payload)

    local buf = ""
    client:read_start(function(read_err, data)
      if read_err then
        client:close()
        vim.schedule(function()
          if cb then cb(read_err, nil) end
        end)
        return
      end
      if data then
        buf = buf .. data
        local nl = buf:find("\n")
        if nl then
          local line = buf:sub(1, nl - 1)
          client:read_stop()
          client:close()
          vim.schedule(function()
            local ok, resp = pcall(vim.json.decode, line)
            if ok and resp then
              if cb then cb(nil, resp) end
            else
              if cb then cb("Invalid response from pi", nil) end
            end
          end)
        end
      else
        -- EOF
        client:close()
      end
    end)
  end)
end

--- Send a prompt string to pi.
--- @param message string|nil  If nil, prompts the user for input
function M.prompt(message)
  if message then
    -- Check for a running pi terminal buffer
    local term_buf = nil
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].buftype == "terminal" then
        local name = vim.api.nvim_buf_get_name(buf)
        -- Match ":pi" or ":pi " at the end/middle of the term name
        if name:lower():match(":pi$") or name:lower():match(":pi%s") then
          term_buf = buf
          break
        end
      end
    end

    if term_buf then
      local id = vim.b[term_buf].terminal_job_id
      if id then
        -- Focus or open the terminal window
        local win = vim.fn.bufwinid(term_buf)
        if win ~= -1 then
          vim.api.nvim_set_current_win(win)
        else
          vim.cmd("botright split")
          vim.api.nvim_win_set_buf(0, term_buf)
        end

        -- Send via bracketed paste to handle newlines correctly, and append \r to submit
        local payload = "\x1b[200~" .. message .. "\x1b[201~\r"
        vim.api.nvim_chan_send(id, payload)
        vim.cmd("startinsert")

        vim.notify("Sent to pi terminal buffer", vim.log.levels.INFO)
        return
      end
    end

    -- Use chat window if configured
    if M.config.use_chat then
      require("pi-nvim.chat").open(message)
      return
    end

    M.send_raw({ type = "prompt", message = message }, function(err, resp)
      if err then return end
      if resp and resp.ok then
        vim.notify("Sent to pi", vim.log.levels.INFO)
      else
        vim.notify("pi error: " .. (resp and resp.error or "unknown"), vim.log.levels.ERROR)
      end
    end)
  else
    vim.ui.input({ prompt = "Pi prompt: " }, function(input)
      if input and input ~= "" then
        M.prompt(input)
      end
    end)
  end
end

--- Send the current file path with optional prompt.
function M.send_file()
  local file = vim.fn.expand("%:p")
  if file == "" then
    vim.notify("No file open", vim.log.levels.WARN)
    return
  end

  vim.ui.input({ prompt = "Pi prompt (file: " .. vim.fn.expand("%:.") .. "): " }, function(input)
    if not input then return end

    local message
    if input == "" then
      message = string.format("Look at this file: %s", file)
    else
      message = string.format("File: %s\n\n%s", file, input)
    end
    M.prompt(message)
  end)
end

--- Send the visual selection with a prompt.
function M.send_selection()
  -- Get the visual selection
  local start_pos = vim.fn.getpos("'<")
  local end_pos = vim.fn.getpos("'>")
  local lines = vim.fn.getregion(start_pos, end_pos, { type = vim.fn.visualmode() })
  local selection = table.concat(lines, "\n")

  if selection == "" then
    vim.notify("Empty selection", vim.log.levels.WARN)
    return
  end

  local file = vim.fn.expand("%:.")
  local start_line = start_pos[2]
  local end_line = end_pos[2]
  local ft = vim.bo.filetype

  vim.ui.input({ prompt = "Pi prompt (selection): " }, function(input)
    if not input then return end

    local header = string.format("%s lines %d-%d", file, start_line, end_line)
    local message
    if input == "" then
      message = string.format("Look at this code from %s:\n\n```%s\n%s\n```", header, ft, selection)
    else
      message = string.format("%s\n\nFrom %s:\n```%s\n%s\n```", input, header, ft, selection)
    end
    M.prompt(message)
  end)
end

--- Send the entire buffer contents with a prompt.
function M.send_buffer()
  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  local content = table.concat(lines, "\n")
  local file = vim.fn.expand("%:.")
  local ft = vim.bo.filetype

  vim.ui.input({ prompt = "Pi prompt (buffer): " }, function(input)
    if not input then return end

    local message
    if input == "" then
      message = string.format("Look at this file %s:\n\n```%s\n%s\n```", file, ft, content)
    else
      message = string.format("%s\n\nFile: %s\n```%s\n%s\n```", input, file, ft, content)
    end
    M.prompt(message)
  end)
end

--- Send LSP diagnostics with optional prompt.
function M.send_diagnostics()
  local bufnr = vim.api.nvim_get_current_buf()
  local diagnostics = M.get_diagnostics(bufnr)
  local formatted = M.format_diagnostics(diagnostics)
  local file = vim.fn.expand("%:.")

  vim.ui.input({ prompt = "Pi prompt (diagnostics): " }, function(input)
    if not input then return end

    local message
    if file ~= "" then
      message = string.format("File: %s\n\n%s\n\n%s", file, formatted, input)
    else
      message = string.format("%s\n\n%s", formatted, input)
    end
    M.prompt(message)
  end)
end

--- Send a prompt string to pi without opening chat (fire-and-forget).
--- @param message string|nil  If nil, prompts the user for input
function M.prompt_quiet(message)
  if message then
    M.send_raw({ type = "prompt", message = message }, function(err, resp)
      if err then return end
      if resp and resp.ok then
        vim.notify("Sent to pi", vim.log.levels.INFO)
      else
        vim.notify("pi error: " .. (resp and resp.error or "unknown"), vim.log.levels.ERROR)
      end
    end)
  else
    vim.ui.input({ prompt = "Pi prompt: " }, function(input)
      if input and input ~= "" then
        M.prompt_quiet(input)
      end
    end)
  end
end

--- Send the current file path with optional prompt (no chat).
function M.send_file_quiet()
  local file = vim.fn.expand("%:p")
  if file == "" then
    vim.notify("No file open", vim.log.levels.WARN)
    return
  end

  vim.ui.input({ prompt = "Pi prompt (file: " .. vim.fn.expand("%:.") .. "): " }, function(input)
    if not input then return end

    local message
    if input == "" then
      message = string.format("Look at this file: %s", file)
    else
      message = string.format("File: %s\n\n%s", file, input)
    end
    M.prompt_quiet(message)
  end)
end

--- Send the visual selection with a prompt (no chat).
function M.send_selection_quiet()
  local start_pos = vim.fn.getpos("'<")
  local end_pos = vim.fn.getpos("'>")
  local lines = vim.fn.getregion(start_pos, end_pos, { type = vim.fn.visualmode() })
  local selection = table.concat(lines, "\n")

  if selection == "" then
    vim.notify("Empty selection", vim.log.levels.WARN)
    return
  end

  local file = vim.fn.expand("%:.")
  local start_line = start_pos[2]
  local end_line = end_pos[2]
  local ft = vim.bo.filetype

  vim.ui.input({ prompt = "Pi prompt (selection): " }, function(input)
    if not input then return end

    local header = string.format("%s lines %d-%d", file, start_line, end_line)
    local message
    if input == "" then
      message = string.format("Look at this code from %s:\n\n```%s\n%s\n```", header, ft, selection)
    else
      message = string.format("%s\n\nFrom %s:\n```%s\n%s\n```", input, header, ft, selection)
    end
    M.prompt_quiet(message)
  end)
end

--- Send the entire buffer contents with a prompt (no chat).
function M.send_buffer_quiet()
  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  local content = table.concat(lines, "\n")
  local file = vim.fn.expand("%:.")
  local ft = vim.bo.filetype

  vim.ui.input({ prompt = "Pi prompt (buffer): " }, function(input)
    if not input then return end

    local message
    if input == "" then
      message = string.format("Look at this file %s:\n\n```%s\n%s\n```", file, ft, content)
    else
      message = string.format("%s\n\nFile: %s\n```%s\n%s\n```", input, file, ft, content)
    end
    M.prompt_quiet(message)
  end)
end

--- Send LSP diagnostics with optional prompt (no chat).
function M.send_diagnostics_quiet()
  local bufnr = vim.api.nvim_get_current_buf()
  local diagnostics = M.get_diagnostics(bufnr)
  local formatted = M.format_diagnostics(diagnostics)
  local file = vim.fn.expand("%:.")

  vim.ui.input({ prompt = "Pi prompt (diagnostics): " }, function(input)
    if not input then return end

    local message
    if file ~= "" then
      message = string.format("File: %s\n\n%s\n\n%s", file, formatted, input)
    else
      message = string.format("%s\n\n%s", formatted, input)
    end
    M.prompt_quiet(message)
  end)
end

--- Ping the pi session to check connectivity.
function M.ping()
  M.send_raw({ type = "ping" }, function(err, resp)
    if err then
      vim.notify("Pi not reachable: " .. err, vim.log.levels.ERROR)
    elseif resp and resp.type == "pong" then
      vim.notify("Pi is alive! ✓", vim.log.levels.INFO)
    else
      vim.notify("Unexpected response from pi", vim.log.levels.WARN)
    end
  end)
end

--- List all running pi sessions.
function M.list_sessions()
  local sockets_dir = "/tmp/pi-nvim-sockets"
  local ok, files = pcall(vim.fn.glob, sockets_dir .. "/*.info", false, true)
  if not ok or not files or #files == 0 then
    vim.notify("No pi sessions found", vim.log.levels.INFO)
    return
  end

  local sessions = {}
  for _, info_path in ipairs(files) do
    local content_ok, content = pcall(vim.fn.readfile, info_path)
    if content_ok and content and content[1] then
      local parsed_ok, info = pcall(vim.json.decode, content[1])
      if parsed_ok and info then
        local sock = info_path:sub(1, -6)
        local alive = vim.uv.fs_stat(sock) ~= nil
        if alive then
          -- Format start time as relative or short time
          local started = ""
          if info.startedAt then
            local ok2, ts = pcall(function()
              -- Parse ISO 8601: "2026-03-01T14:10:09.123Z"
              local y, mo, d, h, mi, s = info.startedAt:match("(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)")
              if h and mi then
                return string.format("%s:%s", h, mi)
              end
              return info.startedAt
            end)
            if ok2 then started = ts end
          end
          table.insert(sessions, {
            cwd = info.cwd or "?",
            pid = info.pid or "?",
            started = started,
            socket = sock,
          })
        end
      end
    end
  end

  if #sessions == 0 then
    vim.notify("No pi sessions found", vim.log.levels.INFO)
    return
  end

  local items = {}
  local current = M.get_socket_path()
  for _, s in ipairs(sessions) do
    local marker = (current == s.socket) and "●" or "○"
    local time_str = s.started ~= "" and string.format(" started %s", s.started) or ""
    table.insert(items, string.format("%s %s [pid %s%s]", marker, s.cwd, s.pid, time_str))
  end

  vim.ui.select(items, { prompt = "Pi sessions:" }, function(choice, idx)
    if not choice or not idx then return end
    local session = sessions[idx]
    if session then
      M.config.socket_path = session.socket
      vim.notify(string.format("Connected to pi at %s [pid %s]", session.cwd, session.pid), vim.log.levels.INFO)
    end
  end)
end

return M
