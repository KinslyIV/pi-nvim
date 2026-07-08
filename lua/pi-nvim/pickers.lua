local M = {}

--- Check if a plugin is loaded/available
local function has_plugin(name)
  local ok, _ = pcall(require, name)
  return ok
end

--- Try snacks.picker, telescope, or fall back to vim.ui.select
---@param opts { title: string, items: string[], on_select: fun(item: string), on_cancel: fun()|nil }
function M.select(opts)
  opts = opts or {}

  -- Try snacks.picker
  if has_plugin("snacks.picker") then
    local snacks = require("snacks.picker")
    -- For generic list selection, use vim.ui.select via snacks
    vim.ui.select(opts.items, { prompt = opts.title }, function(choice)
      if choice then
        opts.on_select(choice)
      elseif opts.on_cancel then
        opts.on_cancel()
      end
    end)
    return
  end

  -- Try telescope
  if has_plugin("telescope.pickers") then
    local pickers = require("telescope.pickers")
    local finders = require("telescope.finders")
    local conf = require("telescope.config").values
    local actions = require("telescope.actions")
    local action_state = require("telescope.actions.state")

    pickers.new({}, {
      prompt_title = opts.title,
      finder = finders.new_table({ results = opts.items }),
      sorter = conf.generic_sorter({}),
      attach_mappings = function(prompt_bufnr, _)
        actions.select_default:replace(function()
          local selection = action_state.get_selected_entry()
          actions.close(prompt_bufnr)
          if selection then
            opts.on_select(selection[1])
          elseif opts.on_cancel then
            opts.on_cancel()
          end
        end)
        return true
      end,
    }):find()
    return
  end

  -- Fallback to plain vim.ui.select
  vim.ui.select(opts.items, { prompt = opts.title }, function(choice)
    if choice then
      opts.on_select(choice)
    elseif opts.on_cancel then
      opts.on_cancel()
    end
  end)
end

--- Pick a file using the best available picker.
--- Inserts the file path or content at the current cursor position in the given buffer.
---@param bufnr number Buffer to insert into
---@param opts { insert_content: boolean|nil, cursor: number[]|nil, on_done: fun()|nil }
function M.pick_file(bufnr, opts)
  opts = opts or {}
  local insert_content = opts.insert_content or false
  local insert_cursor = opts.cursor
  local on_done = opts.on_done

  -- Check for snacks.picker
  if has_plugin("snacks.picker") then
    require("snacks.picker").files({
      confirm = function(picker, item)
        picker:close()
        if not item then return end
        local file = item.file
        M._insert_at_cursor(bufnr, file, insert_content, insert_cursor)
        if on_done then on_done() end
      end,
    })
    return
  end

  -- Check for telescope
  if has_plugin("telescope.builtin") then
    local builtin = require("telescope.builtin")
    builtin.find_files({
      attach_mappings = function(prompt_bufnr, _)
        local actions = require("telescope.actions")
        local action_state = require("telescope.actions.state")
        actions.select_default:replace(function()
          local selection = action_state.get_selected_entry()
          actions.close(prompt_bufnr)
          if selection then
            local file = selection[1] or selection.path or selection.value
            M._insert_at_cursor(bufnr, file, insert_content, insert_cursor)
            if on_done then vim.schedule(on_done) end
          end
        end)
        return true
      end,
    })
    return
  end

  -- Fallback: use vim.ui.select with glob results
  local cwd = vim.fn.getcwd()
  local ok, files = pcall(vim.fn.glob, cwd .. "/**/*", false, true)
  if not ok or not files then
    vim.notify("No file picker available", vim.log.levels.ERROR)
    return
  end

  vim.ui.select(files, { prompt = "Select file:" }, function(choice)
    if choice then
      M._insert_at_cursor(bufnr, choice, insert_content, insert_cursor)
    end
    if on_done then on_done() end
  end)
end

--- Fetch LSP symbols directly from a specific buffer.
--- This bypasses picker plugins that always query the *current* buffer.
---@param bufnr number The source buffer to query
---@param scope "document"|"workspace"
---@param cb fun(err: string|nil, items: table[])
local function fetch_lsp_symbols(bufnr, scope, cb)
  local clients = vim.lsp.get_clients({ bufnr = bufnr })
  if #clients == 0 then
    cb("No LSP client attached to buffer", {})
    return
  end

  local method = scope == "document" and "textDocument/documentSymbol" or "workspace/symbol"
  local params
  if scope == "document" then
    params = { textDocument = vim.lsp.util.make_text_document_params(bufnr) }
  else
    params = { query = "" }
  end

  -- Track if any client responded
  local responded = false
  local all_items = {}

  for _, client in ipairs(clients) do
    if client.supports_method(method) then
      client.request(method, params, function(err, result)
        if responded then return end -- only use first response
        responded = true

        if err then
          cb("LSP error: " .. tostring(err), {})
          return
        end
        if not result or vim.tbl_isempty(result) then
          cb("No symbols found", {})
          return
        end

        -- Flatten document symbol tree into a list
        local items = {}
        local function collect(symbols, prefix)
          prefix = prefix or ""
          for _, sym in ipairs(symbols) do
            local name = sym.name or "?"
            local kind = sym.kind and vim.lsp.protocol.SymbolKind[sym.kind] or "?"
            local detail = sym.detail and (" " .. sym.detail) or ""
            local display = prefix .. name .. detail .. " [" .. kind .. "]"
            table.insert(items, {
              name = name,
              kind = kind,
              detail = sym.detail,
              range = sym.range or (sym.selectionRange and sym.selectionRange),
              _raw = sym,
              _display = display,
            })
            if sym.children then
              collect(sym.children, prefix .. name .. ".")
            end
          end
        end

        if scope == "document" then
          collect(result)
        else
          -- workspace/symbol returns a flat list
          for _, sym in ipairs(result) do
            local name = sym.name or "?"
            local kind = sym.kind and vim.lsp.protocol.SymbolKind[sym.kind] or "?"
            local container = sym.containerName and (" in " .. sym.containerName) or ""
            table.insert(items, {
              name = name,
              kind = kind,
              container = sym.containerName,
              uri = sym.location and sym.location.uri,
              range = sym.location and sym.location.range,
              _raw = sym,
              _display = name .. container .. " [" .. kind .. "]",
            })
          end
        end

        cb(nil, items)
      end, bufnr)
      return -- only send to first capable client
    end
  end

  if not responded then
    cb("No LSP client supports " .. method, {})
  end
end

--- Pick an LSP symbol (document or workspace) using the best available picker.
--- Queries the specified bufnr, not the current buffer.
---@param insert_bufnr number Buffer to insert the selected symbol into
---@param opts { scope: "document"|"workspace"|nil, bufnr: number|nil, cursor: number[]|nil, input_win: number|nil, on_done: fun()|nil }
function M.pick_symbol(insert_bufnr, opts)
  opts = opts or {}
  local scope = opts.scope or "document"
  local target_bufnr = opts.bufnr or vim.api.nvim_get_current_buf()
  local insert_cursor = opts.cursor
  local input_win = opts.input_win
  local on_done = opts.on_done

  -- Check if target buffer has LSP
  local clients = vim.lsp.get_clients({ bufnr = target_bufnr })
  if #clients == 0 then
    vim.notify("No LSP client attached to buffer " .. target_bufnr, vim.log.levels.WARN)
    return
  end

  -- Fetch symbols from the target buffer
  fetch_lsp_symbols(target_bufnr, scope, function(err, items)
    if err then
      vim.notify(err, vim.log.levels.WARN)
      return
    end
    if #items == 0 then
      vim.notify("No symbols found", vim.log.levels.INFO)
      return
    end

    -- Build display list
    local displays = {}
    for _, item in ipairs(items) do
      table.insert(displays, item._display)
    end

    -- Helper to insert and call on_done
    local function insert_item(idx)
      if idx then
        -- Use the saved cursor if available, otherwise current window cursor
        local cursor = insert_cursor
        if not cursor and input_win and vim.api.nvim_win_is_valid(input_win) then
          cursor = vim.api.nvim_win_get_cursor(input_win)
        end
        M._insert_symbol_at_cursor(insert_bufnr, items[idx], cursor)
      end
      if on_done then on_done() end
    end

    -- Use snacks.picker if available (generic list picker)
    if has_plugin("snacks.picker") then
      local snacks = require("snacks.picker")
      -- snacks.picker doesn't have a direct generic list API that's stable,
      -- so we use vim.ui.select which snacks will override with its own UI
      vim.ui.select(displays, { prompt = "LSP symbols (" .. scope .. "):" }, function(choice, idx)
        insert_item(idx)
      end)
      return
    end

    -- Use telescope if available
    if has_plugin("telescope.pickers") then
      local pickers = require("telescope.pickers")
      local finders = require("telescope.finders")
      local conf = require("telescope.config").values
      local actions = require("telescope.actions")
      local action_state = require("telescope.actions.state")

      pickers.new({}, {
        prompt_title = "LSP symbols (" .. scope .. ")",
        finder = finders.new_table({ results = displays }),
        sorter = conf.generic_sorter({}),
        attach_mappings = function(prompt_bufnr, _)
          actions.select_default:replace(function()
            local selection = action_state.get_selected_entry()
            actions.close(prompt_bufnr)
            if selection then
              local idx = selection.index
              insert_item(idx)
            else
              if on_done then on_done() end
            end
          end)
          return true
        end,
      }):find()
      return
    end

    -- Fallback to plain vim.ui.select
    vim.ui.select(displays, { prompt = "LSP symbols (" .. scope .. "):" }, function(choice, idx)
      insert_item(idx)
    end)
  end)
end

--- Internal: insert text at cursor position in a buffer
function M._insert_at_cursor(bufnr, filepath, insert_content, insert_cursor)
  if not vim.api.nvim_buf_is_valid(bufnr) then return end

  local text
  if insert_content then
    -- Read file content
    local ok, lines = pcall(vim.fn.readfile, filepath)
    if ok and lines then
      local ft = vim.filetype.match({ filename = filepath }) or ""
      text = string.format("```%s\n%s\n```", ft, table.concat(lines, "\n"))
    else
      text = filepath
    end
  else
    text = filepath
  end

  vim.bo[bufnr].modifiable = true
  -- Use provided cursor, fall back to window 0
  local cursor = insert_cursor or vim.api.nvim_win_get_cursor(0)
  local row = cursor[1] - 1
  local col = cursor[2]
  local line = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1] or ""
  local before = line:sub(1, col)
  local after = line:sub(col + 1)
  local new_line = before .. text .. after

  -- If multi-line text, split and insert properly
  local text_lines = vim.split(text, "\n", { plain = true })
  if #text_lines > 1 then
    local first = before .. text_lines[1]
    local last = text_lines[#text_lines] .. after
    local middle = {}
    for i = 2, #text_lines - 1 do
      table.insert(middle, text_lines[i])
    end
    local all_lines = { first }
    vim.list_extend(all_lines, middle)
    table.insert(all_lines, last)
    vim.api.nvim_buf_set_lines(bufnr, row, row + 1, false, all_lines)
  else
    vim.api.nvim_buf_set_lines(bufnr, row, row + 1, false, { new_line })
  end
  -- Chat input must stay editable after insertion
end

--- Internal: insert symbol info at cursor
---@param bufnr number Buffer to insert into
---@param item table The symbol item
---@param cursor number[]|nil Optional {row, col} cursor position; falls back to win 0
function M._insert_symbol_at_cursor(bufnr, item, cursor)
  if not vim.api.nvim_buf_is_valid(bufnr) then return end

  local name = item.name or (item.text and item.text:match("%S+") or "unknown")
  -- Handle both numeric kind (from external pickers) and string kind (from our fetcher)
  local kind
  if type(item.kind) == "number" then
    kind = vim.lsp.protocol.SymbolKind[item.kind] or "?"
  elseif type(item.kind) == "string" then
    kind = item.kind
  else
    kind = "?"
  end

  -- Extract location info
  local file = item.filename or item.uri or ""
  local lnum = item.lnum or 0
  if lnum == 0 and item.range then
    lnum = (item.range.start and item.range.start.line + 1) or (item.range.line and item.range.line + 1) or 0
  end

  -- Build richer symbol reference text
  local parts = { "`" .. name .. "`" }

  -- Add detail (function signature, etc.) if available
  if item.detail and item.detail ~= "" then
    table.insert(parts, "(" .. item.detail .. ")")
  else
    table.insert(parts, "(" .. kind .. ")")
  end

  -- Add container context if available (e.g., "in class Foo")
  local container = item.containerName or (item._raw and item._raw.containerName)
  if container and container ~= "" then
    table.insert(parts, "in `" .. container .. "`")
  end

  -- Add file:line reference
  if file ~= "" and lnum > 0 then
    local filepath = file:gsub("^file://", "")
    table.insert(parts, "at " .. filepath .. ":" .. lnum)
  end

  local text = table.concat(parts, " ")

  vim.bo[bufnr].modifiable = true
  -- Use provided cursor, fall back to window 0
  local use_cursor = cursor or vim.api.nvim_win_get_cursor(0)
  local row = use_cursor[1] - 1
  local col = use_cursor[2]
  local line = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1] or ""
  local before = line:sub(1, col)
  local after = line:sub(col + 1)
  vim.api.nvim_buf_set_lines(bufnr, row, row + 1, false, { before .. text .. after })
  -- Chat input must stay editable after insertion
end

return M
