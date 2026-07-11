local M = {}

-- Chat state
local chat_win = nil
local chat_buf = nil
local input_win = nil
local input_buf = nil
local active_connection = nil
local chat_history = {}
local ns_highlight = nil
local is_open = false
local source_buf = nil
local diagnostics_included = false
local selection_start_line = nil
local selection_end_line = nil
local picker_active = false  -- suspends BufLeave auto-close while pickers are open

--- Get accent color from current theme
local function get_accent_hl()
  local accent_hl = vim.api.nvim_get_hl(0, { name = "Function", link = false })
  local normal_hl = vim.api.nvim_get_hl(0, { name = "Normal", link = false })
  return accent_hl.fg, normal_hl.bg
end

--- Create or update highlight groups
local function setup_highlights()
  local accent_fg, normal_bg = get_accent_hl()
  vim.api.nvim_set_hl(0, "PiNvimChatBorder", { fg = accent_fg, bg = normal_bg })
  vim.api.nvim_set_hl(0, "PiNvimChatTitle", { fg = accent_fg, bg = normal_bg })
  vim.api.nvim_set_hl(0, "PiNvimChatUser", { fg = accent_fg, bg = normal_bg, bold = true })
  vim.api.nvim_set_hl(0, "PiNvimChatPi", { fg = "#50fa7b", bg = normal_bg, bold = true })
  vim.api.nvim_set_hl(0, "PiNvimChatSeparator", { fg = "#6272a4", bg = normal_bg })
end

--- Format chat content into display lines
local function format_chat_content()
  local lines = {}
  for _, entry in ipairs(chat_history) do
    if entry.role == "user" then
      table.insert(lines, "")
      table.insert(lines, " You: " .. entry.content:gsub("\n", " "))
    elseif entry.role == "pi" then
      table.insert(lines, "")
      table.insert(lines, " pi: ")
      for _, text_line in ipairs(vim.split(entry.content, "\n", { plain = true })) do
        table.insert(lines, " " .. text_line)
      end
    end
  end
  return lines
end

--- Scroll chat to bottom
local function scroll_to_bottom()
  if not chat_win or not vim.api.nvim_win_is_valid(chat_win) then return end
  local line_count = vim.api.nvim_buf_line_count(chat_buf)
  vim.api.nvim_win_set_cursor(chat_win, { math.max(1, line_count), 0 })
end

--- Update chat buffer content
local function refresh_chat()
  if not chat_buf or not vim.api.nvim_buf_is_valid(chat_buf) then return end
  local lines = format_chat_content()
  vim.bo[chat_buf].modifiable = true
  vim.api.nvim_buf_set_lines(chat_buf, 0, -1, false, lines)
  vim.bo[chat_buf].modifiable = false
  scroll_to_bottom()
end

--- Append a token to the last pi response (streaming deltas)
local function append_pi_text(text)
  if #chat_history == 0 then return end
  local last = chat_history[#chat_history]
  if last.role ~= "pi" then
    table.insert(chat_history, { role = "pi", content = text })
  else
    last.content = last.content .. text
  end
  refresh_chat()
end

--- Start a new empty pi message entry. Reuses the last empty pi entry
--- if one already exists at the end (avoids duplicates on rapid events).
local function start_new_pi_message()
  if #chat_history > 0 then
    local last = chat_history[#chat_history]
    if last.role == "pi" and last.content == "" then
      return
    end
  end
  table.insert(chat_history, { role = "pi", content = "" })
  refresh_chat()
end

--- Mark the last pi response as complete (replaces with full accumulated text).
--- Skips empty final_text so that tool-only message_end events don't clear
--- the display.
local function finalize_pi_text(full_text)
  if #chat_history == 0 then return end
  if full_text == "" then return end
  local last = chat_history[#chat_history]
  if last.role == "pi" then
    last.content = full_text
    refresh_chat()
  end
end

--- Add a user message to history
local function add_user_message(text)
  table.insert(chat_history, { role = "user", content = text })
  refresh_chat()
end

--- Close the chat window and clean up
function M.close()
  is_open = false
  source_buf = nil
  picker_active = false
  selection_start_line = nil
  selection_end_line = nil
  if active_connection then
    pcall(function() active_connection:read_stop() end)
    pcall(function() active_connection:close() end)
    active_connection = nil
  end
  if input_win and vim.api.nvim_win_is_valid(input_win) then
    pcall(vim.api.nvim_win_close, input_win, true)
  end
  if chat_win and vim.api.nvim_win_is_valid(chat_win) then
    pcall(vim.api.nvim_win_close, chat_win, true)
  end
  if input_buf and vim.api.nvim_buf_is_valid(input_buf) then
    pcall(vim.api.nvim_buf_delete, input_buf, { force = true })
  end
  if chat_buf and vim.api.nvim_buf_is_valid(chat_buf) then
    pcall(vim.api.nvim_buf_delete, chat_buf, { force = true })
  end
  chat_win = nil
  chat_buf = nil
  input_win = nil
  input_buf = nil
end

--- Get the current accumulated text in the input buffer
local function get_input_text()
  if not input_buf or not vim.api.nvim_buf_is_valid(input_buf) then return "" end
  local lines = vim.api.nvim_buf_get_lines(input_buf, 0, -1, false)
  return vim.fn.trim(table.concat(lines, "\n"))
end

--- Clear the input buffer
local function clear_input()
  if not input_buf or not vim.api.nvim_buf_is_valid(input_buf) then return end
  vim.bo[input_buf].modifiable = true
  vim.api.nvim_buf_set_lines(input_buf, 0, -1, false, { "" })
end

--- Resize input window based on content
local function resize_input()
  if not input_win or not vim.api.nvim_win_is_valid(input_win) then return end
  local width = vim.api.nvim_win_get_width(input_win)
  local lines = vim.api.nvim_buf_get_lines(input_buf, 0, -1, false)
  local visual_rows = 0
  for _, line in ipairs(lines) do
    visual_rows = visual_rows + math.max(1, math.ceil((#line == 0 and 1 or #line) / width))
  end
  local new_height = math.max(1, math.min(4, visual_rows))
  vim.api.nvim_win_set_height(input_win, new_height)
end

--- Send a chat message to pi using streaming protocol
function M.send_chat(message, on_complete)
  local pi = require("pi-nvim")
  local sock_path = pi.get_socket_path()
  if not sock_path then
    vim.notify("No pi session found. Is pi running with pi-nvim extension?", vim.log.levels.ERROR)
    return
  end

  -- Close any previous connection to prevent duplicate streams
  if active_connection then
    pcall(function() active_connection:read_stop() end)
    pcall(function() active_connection:close() end)
    active_connection = nil
  end

  -- Add user message to chat history.
  -- The empty pi entry is created by the extension's new_message event
  -- so that each assistant message turn gets its own chat entry.
  add_user_message(message)

  local client = vim.uv.new_pipe(false)
  if not client then
    vim.notify("Failed to create pipe", vim.log.levels.ERROR)
    return
  end

  active_connection = client

  client:connect(sock_path, function(err)
    if err then
      vim.schedule(function()
        vim.notify("Failed to connect to pi: " .. err, vim.log.levels.ERROR)
        active_connection = nil
      end)
      return
    end

    local payload = vim.json.encode({ type = "chat", message = message }) .. "\n"
    client:write(payload)

    local buf = ""
    client:read_start(function(read_err, data)
      if read_err then
        vim.schedule(function()
          if read_err then
            -- Connection error, probably agent_done closed it
          end
        end)
        return
      end
      if data then
        buf = buf .. data
        local nl
        while true do
          nl = buf:find("\n")
          if not nl then break end
          local line = buf:sub(1, nl - 1)
          buf = buf:sub(nl + 1)
          if line == "" then goto continue end

          local ok, resp = pcall(vim.json.decode, line)
          if ok and resp then
            if resp.type == "new_message" then
              vim.schedule(function()
                start_new_pi_message()
              end)
            elseif resp.type == "token" and resp.content then
              vim.schedule(function()
                append_pi_text(resp.content)
              end)
            elseif resp.type == "done" then
              vim.schedule(function()
                finalize_pi_text(resp.content or "")
              end)
            elseif resp.type == "agent_done" then
              vim.schedule(function()
                active_connection = nil
                if on_complete then on_complete() end
              end)
            elseif resp.ok and resp.type == "chat_started" then
              -- Stream started successfully
            elseif resp.ok == false then
              vim.schedule(function()
                vim.notify("pi error: " .. (resp.error or "unknown"), vim.log.levels.ERROR)
                active_connection = nil
              end)
            end
          end
          ::continue::
        end
      else
        -- EOF
        vim.schedule(function()
          active_connection = nil
        end)
      end
    end)
  end)
end

--- Send a follow-up message from the chat input
local function send_followup()
  local text = get_input_text()
  if text == "" then return end
  clear_input()
  M.send_chat(text)
end

--- Open the floating chat window.
--- Accepts either:
---   - a string (backward compat): sends it as a chat message
---   - a table: { message = "..." } to send, or { prefill = "..." } to fill the input
function M.open(opts)
  -- Backward compat: string argument = send as message
  if type(opts) == "string" then
    opts = { message = opts }
  end
  opts = opts or {}
  local initial_message = opts.message
  local prefill = opts.prefill

  if is_open then
    -- Window already open
    if initial_message then
      M.send_chat(initial_message)
    end
    if prefill and input_buf and vim.api.nvim_buf_is_valid(input_buf) then
      vim.bo[input_buf].modifiable = true
      local lines = vim.split(prefill, "\n", { plain = true })
      vim.api.nvim_buf_set_lines(input_buf, 0, -1, false, lines)
      vim.api.nvim_win_set_cursor(input_win, {#lines, 0})
    end
    -- Focus input window
    if input_win and vim.api.nvim_win_is_valid(input_win) then
      vim.api.nvim_set_current_win(input_win)
      vim.cmd("startinsert!")
    end
    return
  end

  is_open = true
  diagnostics_included = false
  selection_start_line = nil
  selection_end_line = nil
  setup_highlights()

  -- Remember the source buffer for LSP symbol queries
  source_buf = vim.api.nvim_get_current_buf()

  local width = math.min(80, math.floor(vim.o.columns * 0.7))
  local chat_height = math.min(20, math.floor(vim.o.lines * 0.5))
  local input_height = 2
  local gap = 1
  local total_height = chat_height + gap + input_height + 4 -- borders
  local row = math.floor((vim.o.lines - total_height) / 2)
  local col = math.floor((vim.o.columns - width - 2) / 2)

  -- Chat output buffer
  chat_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[chat_buf].buftype = "nofile"
  vim.bo[chat_buf].modifiable = false
  vim.bo[chat_buf].filetype = "markdown"

  chat_win = vim.api.nvim_open_win(chat_buf, false, {
    relative = "editor",
    width = width,
    height = chat_height,
    row = row,
    col = col,
    style = "minimal",
    border = "rounded",
    title = " pi chat ",
    title_pos = "center",
    zindex = 50,
    noautocmd = true,
    focusable = true,
  })
  vim.wo[chat_win].winhl = "NormalFloat:Normal,FloatBorder:PiNvimChatBorder,FloatTitle:PiNvimChatTitle"
  vim.wo[chat_win].wrap = true
  vim.wo[chat_win].cursorline = false

  -- Input buffer
  input_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[input_buf].buftype = "nofile"
  vim.bo[input_buf].filetype = "pi-nvim-chat-input"
  if prefill then
    local lines = vim.split(prefill, "\n", { plain = true })
    vim.api.nvim_buf_set_lines(input_buf, 0, -1, false, lines)
  else
    vim.api.nvim_buf_set_lines(input_buf, 0, -1, false, { "" })
  end

  local input_row = row + chat_height + 2 + gap
  input_win = vim.api.nvim_open_win(input_buf, true, {
    relative = "editor",
    width = width,
    height = 1,
    row = input_row,
    col = col,
    style = "minimal",
    border = "rounded",
    title = " follow-up [C-f:file C-r:content C-s:sym] [C-d:diag] ",
    title_pos = "center",
    zindex = 50,
    noautocmd = true,
  })
  vim.wo[input_win].winhl = "NormalFloat:Normal,FloatBorder:PiNvimChatBorder,FloatTitle:PiNvimChatTitle"
  vim.wo[input_win].wrap = true

  -- Set input buffer modifiable for the user, but we'll control it on send
  vim.bo[input_buf].modifiable = true

  -- Keymaps for input buffer
  local kopts = { buffer = input_buf, noremap = true, silent = true }

  vim.keymap.set("i", "<CR>", function()
    local lines = vim.api.nvim_buf_get_lines(input_buf, 0, -1, false)
    local cursor = vim.api.nvim_win_get_cursor(input_win)
    local cursor_row = cursor[1]
    -- Check if there's non-empty content after the cursor line
    local has_content_after = false
    for i = cursor_row + 1, #lines do
      if lines[i]:match("%S") then
        has_content_after = true
        break
      end
    end
    -- Only insert newline if there's real content below (cursor is in the middle)
    if has_content_after then
      return "\n"
    end
    -- Otherwise: send the message (trailing empty lines are just padding)
    send_followup()
    return ""
  end, vim.tbl_extend("force", kopts, { expr = true }))

  vim.keymap.set("i", "<S-CR>", "\n", kopts)
  vim.keymap.set({ "i", "n" }, "<Esc>", M.close, kopts)
  vim.keymap.set({ "i", "n" }, "<C-c>", M.close, kopts)
  vim.keymap.set({ "n" }, "q", M.close, kopts)
  vim.keymap.set({ "n" }, "<CR>", send_followup, kopts)

  local function restore_chat_input()
    picker_active = false
    vim.schedule(function()
      if input_win and vim.api.nvim_win_is_valid(input_win) then
        vim.api.nvim_set_current_win(input_win)
        vim.cmd("startinsert")
      end
    end)
  end

  -- File picker: insert file path
  vim.keymap.set("i", "<C-f>", function()
    picker_active = true
    require("pi-nvim.pickers").pick_file(input_buf, {
      insert_content = false,
      on_done = restore_chat_input,
    })
  end, kopts)
  -- File picker: insert file content
  vim.keymap.set("i", "<C-r>", function()
    picker_active = true
    local cursor = vim.api.nvim_win_get_cursor(input_win)
    require("pi-nvim.pickers").pick_file(input_buf, {
      insert_content = true,
      cursor = cursor,
      on_done = restore_chat_input,
    })
  end, kopts)
  -- LSP document symbol picker
  vim.keymap.set("i", "<C-s>", function()
    picker_active = true
    local cursor = vim.api.nvim_win_get_cursor(input_win)
    require("pi-nvim.pickers").pick_symbol(input_buf, {
      scope = "document",
      bufnr = source_buf,
      cursor = cursor,
      input_win = input_win,
      on_done = restore_chat_input,
    })
  end, kopts)
  -- LSP workspace symbol picker
  vim.keymap.set("i", "<C-w>", function()
    picker_active = true
    local cursor = vim.api.nvim_win_get_cursor(input_win)
    require("pi-nvim.pickers").pick_symbol(input_buf, {
      scope = "workspace",
      bufnr = source_buf,
      cursor = cursor,
      input_win = input_win,
      on_done = restore_chat_input,
    })
  end, kopts)

  -- Toggle diagnostics: append/remove LSP diagnostics from the input buffer
  vim.keymap.set({ "i", "n" }, "<C-d>", function()
    local bufnr = source_buf and vim.api.nvim_buf_is_valid(source_buf) and source_buf
      or vim.api.nvim_get_current_buf()
    local diags = require("pi-nvim").get_diagnostics(bufnr, selection_start_line, selection_end_line)
    if not diags or #diags == 0 then
      vim.notify("No LSP diagnostics found", vim.log.levels.INFO)
      return
    end
    local formatted = require("pi-nvim").format_diagnostics(diags)
    local file = vim.fn.expand("%:.", bufnr)

    -- Get current input content
    local lines = vim.api.nvim_buf_get_lines(input_buf, 0, -1, false)
    local content = table.concat(lines, "\n")

    if diagnostics_included then
      -- Remove diagnostics block: find the sentinel
      local diag_start = content:find("\n%-%- DIAGNOSTICS %-%-\n")
      if diag_start then
        content = content:sub(1, diag_start - 1)
        -- Trim trailing whitespace
        content = content:gsub("\n+$", "")
      end
      diagnostics_included = false
      vim.notify("Diagnostics removed", vim.log.levels.INFO)
    else
      -- Append diagnostics at the end
      local diag_block = "\n\n-- DIAGNOSTICS --\n" .. formatted
      content = content .. diag_block
      diagnostics_included = true
      vim.notify("Diagnostics appended", vim.log.levels.INFO)
    end

    -- Update input buffer
    local new_lines = vim.split(content, "\n", { plain = true })
    vim.bo[input_buf].modifiable = true
    vim.api.nvim_buf_set_lines(input_buf, 0, -1, false, new_lines)

    -- Update title
    local title = " follow-up [C-f:file C-r:content C-s:sym]"
    if diagnostics_included then
      title = title .. " [diag:on]"
    else
      title = title .. " [C-d:diag]"
    end
    pcall(vim.api.nvim_win_set_config, input_win, { title = title .. " " })

    -- Resize to fit
    resize_input()

    -- Stay in insert mode at end
    vim.api.nvim_win_set_cursor(input_win, { #new_lines, #new_lines[#new_lines] })
  end, kopts)

  -- Resize input as text changes
  vim.api.nvim_create_autocmd({ "TextChangedI", "TextChanged" }, {
    buffer = input_buf,
    callback = resize_input,
  })

  -- Close chat when leaving the input buffer (suspended while pickers are open)
  vim.api.nvim_create_autocmd("BufLeave", {
    buffer = input_buf,
    once = false,
    callback = function()
      if picker_active then return end
      vim.schedule(M.close)
    end,
  })

  -- Make chat window close together
  vim.api.nvim_create_autocmd("WinClosed", {
    pattern = tostring(input_win),
    once = true,
    callback = function()
      vim.schedule(M.close)
    end,
  })

  -- Position cursor and start insert mode
  if prefill and input_win then
    local lines = vim.split(prefill, "\n", { plain = true })
    vim.api.nvim_win_set_cursor(input_win, {#lines, 0})
  end
  vim.cmd("noautocmd startinsert!")

  -- If there's an initial message, send it (after window renders)
  if initial_message then
    vim.schedule(function()
      M.send_chat(initial_message)
    end)
  end
end

--- Open chat with a visual selection pre-filled in the input buffer.
--- The selection is pasted as editable text — the user can add a prompt before sending.
---@param selection table The visual selection data from capture_selection()
function M.open_with_selection(selection)
  if not selection or not selection.text then
    vim.notify("No selection to send", vim.log.levels.WARN)
    return
  end

  -- Track selection range so diagnostics toggle can filter to it
  selection_start_line = selection.start_line or 1
  selection_end_line = selection.end_line or 1

  local file = selection.file or vim.fn.expand("%:.")
  local ft = selection.ft or vim.bo.filetype
  local start_line = selection.start_line or 1
  local end_line = selection.end_line or 1

  -- Build prefill text: selection as context the user can edit
  local lines = {
    string.format("From %s lines %d-%d:", file, start_line, end_line),
    "```" .. ft,
  }
  vim.list_extend(lines, vim.split(selection.text, "\n", { plain = true }))
  table.insert(lines, "```")
  table.insert(lines, "")
  table.insert(lines, "")

  local prefill = table.concat(lines, "\n")
  M.open({ prefill = prefill })
end

--- Toggle chat window visibility
function M.toggle()
  if is_open then
    M.close()
  else
    M.open()
  end
end

--- Get the source buffer (the file that was active when chat opened)
function M.get_source_buf()
  if source_buf and vim.api.nvim_buf_is_valid(source_buf) then
    return source_buf
  end
  return nil
end

--- Clear chat history and reset the chat display
function M.clear()
  -- Close any active streaming connection to stop old responses
  if active_connection then
    pcall(function() active_connection:read_stop() end)
    pcall(function() active_connection:close() end)
    active_connection = nil
  end

  chat_history = {}

  if is_open then
    refresh_chat()
  end
end

return M
