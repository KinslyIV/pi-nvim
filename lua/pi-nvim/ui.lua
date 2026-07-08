local M = {}

--- Capture visual selection info before it's lost.
--- @return table|nil
function M.capture_selection()
  local start_pos = vim.fn.getpos("'<")
  local end_pos = vim.fn.getpos("'>")

  if start_pos[2] == 0 and end_pos[2] == 0 then
    return nil
  end

  local ok, lines = pcall(vim.fn.getregion, start_pos, end_pos, { type = vim.fn.visualmode() })
  if not ok or not lines or #lines == 0 then
    return nil
  end

  local text = table.concat(lines, "\n")
  if text == "" then return nil end

  return {
    text = text,
    file = vim.fn.expand("%:."),
    start_line = start_pos[2],
    end_line = end_pos[2],
    ft = vim.bo.filetype,
  }
end

--- Open the Pi send dialog as two floating windows.
--- @param opts { selection: table|nil }|nil
function M.open(opts)
  opts = opts or {}
  local pi = require("pi-nvim")
  local selection = opts.selection
  local file = vim.fn.expand("%:p")
  local rel_file = vim.fn.expand("%:.")
  local ft = vim.bo.filetype
  local send_buffer = false
  local send_diagnostics = false
  local source_buf = vim.api.nvim_get_current_buf()
  local buf_lines = vim.api.nvim_buf_get_lines(source_buf, 0, -1, false)
  local use_chat = pi.config.use_chat

  -- Gather diagnostics upfront
  local diagnostics = {}
  local has_diagnostics = false
  if selection then
    diagnostics = pi.get_diagnostics(source_buf, selection.start_line, selection.end_line)
  else
    diagnostics = pi.get_diagnostics(source_buf)
  end
  has_diagnostics = #diagnostics > 0

  -- Build info lines
  local file_info = "File: " .. (rel_file ~= "" and rel_file or "(no file)")
  local context_info
  if selection then
    local n = select(2, selection.text:gsub("\n", "")) + 1
    context_info = string.format("Selection: %d lines (%d-%d)", n, selection.start_line, selection.end_line)
  else
    context_info = "Send buffer: [ ] (Tab to toggle)"
  end

  -- Layout
  local width = math.min(72, math.floor(vim.o.columns * 0.5))
  local info_height = has_diagnostics and 4 or 3
  local max_input_height = 6
  local gap = 0 -- no gap between bubbles
  local top_row = math.floor((vim.o.lines - (info_height + 2 + gap + max_input_height + 2)) / 2)
  local col = math.floor((vim.o.columns - width - 2) / 2)

  -- Accent highlights
  local accent_hl = vim.api.nvim_get_hl(0, { name = "Function", link = false })
  local normal_hl = vim.api.nvim_get_hl(0, { name = "Normal", link = false })
  local accent_fg = accent_hl.fg
  vim.api.nvim_set_hl(0, "PiNvimBorder", { fg = accent_fg, bg = normal_hl.bg })
  vim.api.nvim_set_hl(0, "PiNvimTitle", { fg = accent_fg, bg = normal_hl.bg })

  -- Top bubble: info
  local info_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[info_buf].buftype = "nofile"

  local info_lines = {
    " " .. file_info,
    " " .. context_info,
  }
  if has_diagnostics then
    local diag_count = #diagnostics
    local err_count = vim.tbl_filter(function(d) return d.severity == vim.diagnostic.severity.ERROR end, diagnostics)
    local warn_count = vim.tbl_filter(function(d) return d.severity == vim.diagnostic.severity.WARN end, diagnostics)
    table.insert(info_lines, string.format(" Diagnostics: %d total (%d errors, %d warns) [ ] (d to toggle)",
      diag_count, #err_count, #warn_count))
  else
    table.insert(info_lines, " Diagnostics: none")
  end
  table.insert(info_lines, " Chat mode: [" .. (use_chat and "x" or " ") .. "] (c to toggle)")

  vim.api.nvim_buf_set_lines(info_buf, 0, -1, false, info_lines)
  vim.bo[info_buf].modifiable = false

  local info_win = vim.api.nvim_open_win(info_buf, false, {
    relative = "editor",
    width = width,
    height = info_height,
    row = top_row,
    col = col,
    style = "minimal",
    border = "rounded",
    title = " pi ",
    title_pos = "center",
    zindex = 50,
    noautocmd = true,
    focusable = false,
  })
  vim.wo[info_win].winhl = "NormalFloat:Normal,FloatBorder:PiNvimBorder,FloatTitle:PiNvimTitle"
  vim.wo[info_win].cursorline = false

  -- Bottom bubble: prompt input
  local input_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[input_buf].buftype = "nofile"
  vim.bo[input_buf].filetype = "pi-nvim-prompt"
  vim.api.nvim_buf_set_lines(input_buf, 0, -1, false, { "" })

  local input_row = top_row + info_height + 2 + gap -- +2 for info border
  local input_win = vim.api.nvim_open_win(input_buf, true, {
    relative = "editor",
    width = width,
    height = 1,
    row = input_row,
    col = col,
    style = "minimal",
    border = "rounded",
    title = " prompt ",
    title_pos = "center",
    zindex = 50,
    noautocmd = true,
  })
  vim.wo[input_win].winhl = "NormalFloat:Normal,FloatBorder:PiNvimBorder,FloatTitle:PiNvimTitle"
  vim.wo[input_win].wrap = true

  -- Resize the input window to fit content (1..max_input_height rows)
  local function resize_input()
    if not vim.api.nvim_win_is_valid(input_win) then return end
    local lines = vim.api.nvim_buf_get_lines(input_buf, 0, -1, false)
    -- Count visual rows (each buffer line may wrap across multiple display rows)
    local visual_rows = 0
    for _, line in ipairs(lines) do
      -- A blank line still takes 1 row
      visual_rows = visual_rows + math.max(1, math.ceil((#line == 0 and 1 or #line) / width))
    end
    local new_height = math.max(1, math.min(max_input_height, visual_rows))
    vim.api.nvim_win_set_height(input_win, new_height)
    -- Scroll so the cursor line is always visible (bottom of window)
    local cursor_line = vim.api.nvim_win_get_cursor(input_win)[1]
    local top_line = math.max(1, cursor_line - new_height + 1)
    vim.api.nvim_win_call(input_win, function()
      vim.fn.winrestview({ topline = top_line })
    end)
  end

  -- Highlight the visual selection in the source buffer while the dialog is open
  local sel_ns = nil
  if selection and vim.api.nvim_buf_is_valid(source_buf) then
    sel_ns = vim.api.nvim_create_namespace("pi_nvim_selection")
    for lnum = selection.start_line, selection.end_line do
      vim.api.nvim_buf_add_highlight(source_buf, sel_ns, "Visual", lnum - 1, 0, -1)
    end
  end

  -- Start in insert mode
  vim.cmd("noautocmd startinsert!")

  local closed = false

  local function close()
    if closed then return end
    closed = true
    vim.cmd("noautocmd stopinsert")
    -- Remove selection highlight from source buffer
    if sel_ns and vim.api.nvim_buf_is_valid(source_buf) then
      vim.api.nvim_buf_clear_namespace(source_buf, sel_ns, 0, -1)
    end
    pcall(vim.api.nvim_win_close, input_win, true)
    pcall(vim.api.nvim_win_close, info_win, true)
    pcall(vim.api.nvim_buf_delete, input_buf, { force = true })
    pcall(vim.api.nvim_buf_delete, info_buf, { force = true })
  end

  local function update_context()
    vim.bo[info_buf].modifiable = true
    local lines = {}
    table.insert(lines, " " .. file_info)
    if selection then
      local n = select(2, selection.text:gsub("\n", "")) + 1
      table.insert(lines, string.format(" Selection: %d lines (%d-%d)", n, selection.start_line, selection.end_line))
    else
      local marker = send_buffer and "[x]" or "[ ]"
      table.insert(lines, " Send buffer: " .. marker .. " (Tab to toggle)")
    end
    if has_diagnostics then
      local diag_count = #diagnostics
      local err_count = vim.tbl_filter(function(d) return d.severity == vim.diagnostic.severity.ERROR end, diagnostics)
      local warn_count = vim.tbl_filter(function(d) return d.severity == vim.diagnostic.severity.WARN end, diagnostics)
      local dmarker = send_diagnostics and "[x]" or "[ ]"
      table.insert(lines, string.format(" Diagnostics: %d total (%d errors, %d warns) %s (d to toggle)",
        diag_count, #err_count, #warn_count, dmarker))
    else
      table.insert(lines, " Diagnostics: none")
    end
    local cmarker = use_chat and "[x]" or "[ ]"
    table.insert(lines, " Chat mode: " .. cmarker .. " (c to toggle)")
    vim.api.nvim_buf_set_lines(info_buf, 0, -1, false, lines)
    vim.bo[info_buf].modifiable = false
  end

  local function send()
    local lines = vim.api.nvim_buf_get_lines(input_buf, 0, -1, false)
    local prompt_text = vim.fn.trim(table.concat(lines, "\n"))
    close()

    local message
    if selection then
      local header = string.format("%s lines %d-%d", selection.file, selection.start_line, selection.end_line)
      if prompt_text == "" then
        message = string.format("Look at this code from %s:\n\n```%s\n%s\n```", header, selection.ft, selection.text)
      else
        message = string.format("%s\n\nFrom %s:\n```%s\n%s\n```", prompt_text, header, selection.ft, selection.text)
      end
    elseif send_buffer and rel_file ~= "" then
      local content = table.concat(buf_lines, "\n")
      if prompt_text == "" then
        message = string.format("Look at this file %s:\n\n```%s\n%s\n```", rel_file, ft, content)
      else
        message = string.format("%s\n\nFile: %s\n```%s\n%s\n```", prompt_text, rel_file, ft, content)
      end
    elseif file ~= "" then
      if prompt_text == "" then
        message = string.format("Look at this file: %s", file)
      else
        message = string.format("File: %s\n\n%s", file, prompt_text)
      end
    else
      if prompt_text == "" then
        vim.notify("Nothing to send", vim.log.levels.WARN)
        return
      end
      message = prompt_text
    end

    -- Append diagnostics if requested
    if send_diagnostics and has_diagnostics then
      local formatted = pi.format_diagnostics(diagnostics)
      message = message .. "\n\n" .. formatted
    end

    if use_chat then
      require("pi-nvim.chat").open(message)
    else
      pi.prompt(message)
    end
  end

  local kopts = { buffer = input_buf, noremap = true, silent = true }

  -- Smart <CR>: insert newline when there is content after the cursor line,
  -- otherwise send the prompt.
  vim.keymap.set({ "i", "n" }, "<CR>", function()
    local lines = vim.api.nvim_buf_get_lines(input_buf, 0, -1, false)
    local cursor = vim.api.nvim_win_get_cursor(input_win)
    local has_content_after = false
    for i = cursor[1] + 1, #lines do
      if lines[i] ~= "" then
        has_content_after = true
        break
      end
    end
    if has_content_after then
      -- Still editing: insert a newline
      vim.api.nvim_buf_set_lines(input_buf, cursor[1], cursor[1], false, { "" })
      vim.api.nvim_win_set_cursor(input_win, { cursor[1] + 1, 0 })
      resize_input()
    else
      send()
    end
  end, kopts)
  vim.keymap.set({ "i", "n" }, "<Esc>", close, kopts)
  vim.keymap.set({ "i", "n" }, "<C-c>", close, kopts)
  -- Toggles: only in normal mode so they don't interfere with typing
  vim.keymap.set("n", "<Tab>", function()
    if not selection then
      send_buffer = not send_buffer
      update_context()
    end
  end, kopts)
  vim.keymap.set("n", "d", function()
    if has_diagnostics then
      send_diagnostics = not send_diagnostics
      update_context()
    end
  end, kopts)
  vim.keymap.set("n", "c", function()
    use_chat = not use_chat
    update_context()
  end, kopts)

  -- Resize window as text is typed
  vim.api.nvim_create_autocmd({ "TextChangedI", "TextChanged" }, {
    buffer = input_buf,
    callback = resize_input,
  })

  vim.api.nvim_create_autocmd("BufLeave", {
    buffer = input_buf,
    once = true,
    callback = function()
      vim.schedule(close)
    end,
  })
end

return M
