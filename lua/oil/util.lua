local config = require("oil.config")
local M = {}

---@param url string
---@return nil|string
---@return nil|string
M.parse_url = function(url)
  return url:match("^(.*://)(.*)$")
end

---@param bufnr integer
---@return nil|oil.Adapter
M.get_adapter = function(bufnr)
  local bufname = vim.api.nvim_buf_get_name(bufnr)
  local adapter = config.get_adapter_by_scheme(bufname)
  if not adapter then
    vim.notify_once(
      string.format("[oil] could not find adapter for buffer '%s://'", bufname),
      vim.log.levels.ERROR
    )
  end
  return adapter
end

---@param text string
---@param length nil|integer
---@return string
M.rpad = function(text, length)
  if not length then
    return text
  end
  local textlen = vim.api.nvim_strwidth(text)
  local delta = length - textlen
  if delta > 0 then
    return text .. string.rep(" ", delta)
  else
    return text
  end
end

---@param text string
---@param length nil|integer
---@return string
M.lpad = function(text, length)
  if not length then
    return text
  end
  local textlen = vim.api.nvim_strwidth(text)
  local delta = length - textlen
  if delta > 0 then
    return string.rep(" ", delta) .. text
  else
    return text
  end
end

---@generic T : any
---@param tbl T[]
---@param start_idx? number
---@param end_idx? number
---@return T[]
M.tbl_slice = function(tbl, start_idx, end_idx)
  local ret = {}
  if not start_idx then
    start_idx = 1
  end
  if not end_idx then
    end_idx = #tbl
  end
  for i = start_idx, end_idx do
    table.insert(ret, tbl[i])
  end
  return ret
end

---@param entry oil.InternalEntry
---@return oil.Entry
M.export_entry = function(entry)
  local FIELD = require("oil.constants").FIELD
  return {
    name = entry[FIELD.name],
    type = entry[FIELD.type],
    id = entry[FIELD.id],
    meta = entry[FIELD.meta],
  }
end

---@param src_bufnr integer|string Buffer number or name
---@param dest_buf_name string
M.rename_buffer = function(src_bufnr, dest_buf_name)
  if type(src_bufnr) == "string" then
    src_bufnr = vim.fn.bufadd(src_bufnr)
    if not vim.api.nvim_buf_is_loaded(src_bufnr) then
      vim.api.nvim_buf_delete(src_bufnr, {})
      return
    end
  end

  local bufname = vim.api.nvim_buf_get_name(src_bufnr)
  local scheme = M.parse_url(bufname)
  -- If this buffer has a scheme (is not literally a file on disk), then we can use the simple
  -- rename logic. The only reason we can't use nvim_buf_set_name on files is because vim will
  -- think that the new buffer conflicts with the file next time it tries to save.
  if scheme or vim.fn.isdirectory(bufname) == 1 then
    -- This will fail if the dest buf name already exists
    local ok = pcall(vim.api.nvim_buf_set_name, src_bufnr, dest_buf_name)
    if ok then
      -- Renaming the buffer creates a new buffer with the old name. Find it and delete it.
      vim.api.nvim_buf_delete(vim.fn.bufadd(bufname), {})
      return
    end
  end

  local dest_bufnr = vim.fn.bufadd(dest_buf_name)
  vim.fn.bufload(dest_bufnr)
  if vim.bo[src_bufnr].buflisted then
    vim.bo[dest_bufnr].buflisted = true
  end
  -- Find any windows with the old buffer and replace them
  for _, winid in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_is_valid(winid) then
      if vim.api.nvim_win_get_buf(winid) == src_bufnr then
        vim.api.nvim_win_set_buf(winid, dest_bufnr)
      end
    end
  end
  if vim.bo[src_bufnr].modified then
    local src_lines = vim.api.nvim_buf_get_lines(src_bufnr, 0, -1, true)
    vim.api.nvim_buf_set_lines(dest_bufnr, 0, -1, true, src_lines)
  end
  -- Try to delete, but don't if the buffer has changes
  pcall(vim.api.nvim_buf_delete, src_bufnr, {})
end

---@param count integer
---@param cb fun(err: nil|string)
M.cb_collect = function(count, cb)
  return function(err)
    if err then
      cb(err)
      cb = function() end
    else
      count = count - 1
      if count == 0 then
        cb()
      end
    end
  end
end

---@param url string
---@return string[]
local function get_possible_buffer_names_from_url(url)
  local fs = require("oil.fs")
  local scheme, path = M.parse_url(url)
  local ret = {}
  for k, v in pairs(config.remap_schemes) do
    if v == scheme then
      if k ~= "default" then
        table.insert(ret, k .. path)
      end
    end
  end
  if vim.tbl_isempty(ret) then
    return { fs.posix_to_os_path(path) }
  else
    return ret
  end
end

---@param entry_type oil.EntryType
---@param src_url string
---@param dest_url string
M.update_moved_buffers = function(entry_type, src_url, dest_url)
  local src_buf_names = get_possible_buffer_names_from_url(src_url)
  local dest_buf_name = get_possible_buffer_names_from_url(dest_url)[1]
  if entry_type ~= "directory" then
    for _, src_buf_name in ipairs(src_buf_names) do
      M.rename_buffer(src_buf_name, dest_buf_name)
    end
  else
    M.rename_buffer(M.addslash(src_url), M.addslash(dest_url))
    -- If entry type is directory, we need to rename this buffer, and then update buffers that are
    -- inside of this directory

    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
      local bufname = vim.api.nvim_buf_get_name(bufnr)
      if vim.startswith(bufname, src_url) then
        -- Handle oil directory buffers
        vim.api.nvim_buf_set_name(bufnr, dest_url .. bufname:sub(src_url:len() + 1))
      elseif bufname ~= "" and vim.bo[bufnr].buftype == "" then
        -- Handle regular buffers
        local scheme = M.parse_url(bufname)

        -- If the buffer is a local file, make sure we're using the absolute path
        if not scheme then
          bufname = vim.fn.fnamemodify(bufname, ":p")
        end

        for _, src_buf_name in ipairs(src_buf_names) do
          if vim.startswith(bufname, src_buf_name) then
            M.rename_buffer(bufnr, dest_buf_name .. bufname:sub(src_buf_name:len() + 1))
            break
          end
        end
      end
    end
  end
end

---@param name_or_config string|table
---@return string
---@return table|nil
M.split_config = function(name_or_config)
  if type(name_or_config) == "string" then
    return name_or_config, nil
  else
    if not name_or_config[1] and name_or_config["1"] then
      -- This was likely loaded from json, so the first element got coerced to a string key
      name_or_config[1] = name_or_config["1"]
      name_or_config["1"] = nil
    end
    return name_or_config[1], name_or_config
  end
end

---@param lines oil.TextChunk[][]
---@param col_width integer[]
---@return string[]
---@return any[][] List of highlights {group, lnum, col_start, col_end}
M.render_table = function(lines, col_width)
  local str_lines = {}
  local highlights = {}
  for _, cols in ipairs(lines) do
    local col = 0
    local pieces = {}
    for i, chunk in ipairs(cols) do
      local text, hl
      if type(chunk) == "table" then
        text, hl = unpack(chunk)
      else
        text = chunk
      end
      text = M.rpad(text, col_width[i])
      table.insert(pieces, text)
      local col_end = col + text:len() + 1
      if hl then
        table.insert(highlights, { hl, #str_lines, col, col_end })
      end
      col = col_end
    end
    table.insert(str_lines, table.concat(pieces, " "))
  end
  return str_lines, highlights
end

---@param bufnr integer
---@param highlights any[][] List of highlights {group, lnum, col_start, col_end}
M.set_highlights = function(bufnr, highlights)
  local ns = vim.api.nvim_create_namespace("Oil")
  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
  for _, hl in ipairs(highlights) do
    vim.api.nvim_buf_add_highlight(bufnr, ns, unpack(hl))
  end
end

---@param path string
---@return string
M.addslash = function(path)
  if not vim.endswith(path, "/") then
    return path .. "/"
  else
    return path
  end
end

---@param winid nil|integer
---@return boolean
M.is_floating_win = function(winid)
  return vim.api.nvim_win_get_config(winid or 0).relative ~= ""
end

---@return integer
M.get_editor_height = function()
  local total_height = vim.o.lines - vim.o.cmdheight
  if vim.o.showtabline == 2 or (vim.o.showtabline == 1 and #vim.api.nvim_list_tabpages() > 1) then
    total_height = total_height - 1
  end
  if
    vim.o.laststatus >= 2 or (vim.o.laststatus == 1 and #vim.api.nvim_tabpage_list_wins(0) > 1)
  then
    total_height = total_height - 1
  end
  return total_height
end

local winid_map = {}
M.add_title_to_win = function(winid, opts)
  opts = opts or {}
  opts.align = opts.align or "left"
  if not vim.api.nvim_win_is_valid(winid) then
    return
  end
  local function get_title()
    local src_buf = vim.api.nvim_win_get_buf(winid)
    local title = vim.api.nvim_buf_get_name(src_buf)
    local scheme, path = M.parse_url(title)
    if config.adapters[scheme] == "files" then
      local fs = require("oil.fs")
      title = vim.fn.fnamemodify(fs.posix_to_os_path(path), ":~")
    end
    return title
  end
  -- HACK to force the parent window to position itself
  -- See https://github.com/neovim/neovim/issues/13403
  vim.cmd.redraw()
  local title = get_title()
  local width = math.min(vim.api.nvim_win_get_width(winid) - 4, 2 + vim.api.nvim_strwidth(title))
  local title_winid = winid_map[winid]
  local bufnr
  if title_winid and vim.api.nvim_win_is_valid(title_winid) then
    vim.api.nvim_win_set_width(title_winid, width)
    bufnr = vim.api.nvim_win_get_buf(title_winid)
  else
    bufnr = vim.api.nvim_create_buf(false, true)
    local col = 1
    if opts.align == "center" then
      col = math.floor((vim.api.nvim_win_get_width(winid) - width) / 2)
    elseif opts.align == "right" then
      col = vim.api.nvim_win_get_width(winid) - 1 - width
    elseif opts.align ~= "left" then
      vim.notify(
        string.format("Unknown oil window title alignment: '%s'", opts.align),
        vim.log.levels.ERROR
      )
    end
    title_winid = vim.api.nvim_open_win(bufnr, false, {
      relative = "win",
      win = winid,
      width = width,
      height = 1,
      row = -1,
      col = col,
      focusable = false,
      zindex = 151,
      style = "minimal",
      noautocmd = true,
    })
    winid_map[winid] = title_winid
    vim.api.nvim_win_set_option(
      title_winid,
      "winblend",
      vim.api.nvim_win_get_option(winid, "winblend")
    )
    vim.api.nvim_buf_set_option(bufnr, "bufhidden", "wipe")

    local update_autocmd = vim.api.nvim_create_autocmd("BufWinEnter", {
      desc = "Update oil floating window title when buffer changes",
      pattern = "*",
      callback = function(params)
        local winbuf = params.buf
        if vim.api.nvim_win_get_buf(winid) ~= winbuf then
          return
        end
        local new_title = get_title()
        local new_width =
          math.min(vim.api.nvim_win_get_width(winid) - 4, 2 + vim.api.nvim_strwidth(new_title))
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, true, { " " .. new_title .. " " })
        vim.bo[bufnr].modified = false
        vim.api.nvim_win_set_width(title_winid, new_width)
        local new_col = 1
        if opts.align == "center" then
          new_col = math.floor((vim.api.nvim_win_get_width(winid) - new_width) / 2)
        elseif opts.align == "right" then
          new_col = vim.api.nvim_win_get_width(winid) - 1 - new_width
        end
        vim.api.nvim_win_set_config(title_winid, {
          relative = "win",
          win = winid,
          row = -1,
          col = new_col,
          width = new_width,
          height = 1,
        })
      end,
    })
    vim.api.nvim_create_autocmd("WinClosed", {
      desc = "Close oil floating window title when floating window closes",
      pattern = tostring(winid),
      callback = function()
        if title_winid and vim.api.nvim_win_is_valid(title_winid) then
          vim.api.nvim_win_close(title_winid, true)
        end
        winid_map[winid] = nil
        vim.api.nvim_del_autocmd(update_autocmd)
      end,
      once = true,
      nested = true,
    })
  end
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, true, { " " .. title .. " " })
  vim.bo[bufnr].modified = false
  vim.api.nvim_win_set_option(
    title_winid,
    "winhighlight",
    "Normal:FloatTitle,NormalFloat:FloatTitle"
  )
end

---@param action oil.Action
---@return oil.Adapter
M.get_adapter_for_action = function(action)
  local adapter = config.get_adapter_by_scheme(action.url or action.src_url)
  if not adapter then
    error("no adapter found")
  end
  if action.dest_url then
    local dest_adapter = config.get_adapter_by_scheme(action.dest_url)
    if adapter ~= dest_adapter then
      if adapter.supports_xfer and adapter.supports_xfer[dest_adapter.name] then
        return adapter
      elseif dest_adapter.supports_xfer and dest_adapter.supports_xfer[adapter.name] then
        return dest_adapter
      else
        error(
          string.format(
            "Cannot copy files from %s -> %s; no cross-adapter transfer method found",
            action.src_url,
            action.dest_url
          )
        )
      end
    end
  end
  return adapter
end

M.render_centered_text = function(bufnr, text)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  if type(text) == "string" then
    text = { text }
  end
  local winid
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(win) == bufnr then
      winid = win
      break
    end
  end
  local height = 40
  local width = 30
  if winid then
    height = vim.api.nvim_win_get_height(winid)
    width = vim.api.nvim_win_get_width(winid)
  end
  local lines = {}
  for _ = 1, (height / 2) - (#text / 2) do
    table.insert(lines, "")
  end
  for _, line in ipairs(text) do
    line = string.rep(" ", (width - vim.api.nvim_strwidth(line)) / 2) .. line
    table.insert(lines, line)
  end
  vim.api.nvim_buf_set_option(bufnr, "modifiable", true)
  pcall(vim.api.nvim_buf_set_lines, bufnr, 0, -1, false, lines)
  vim.api.nvim_buf_set_option(bufnr, "modifiable", false)
  vim.bo[bufnr].modified = false
end

---Run a function in the context of a full-editor window
---@param bufnr nil|integer
---@param callback fun()
M.run_in_fullscreen_win = function(bufnr, callback)
  if not bufnr then
    bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_option(bufnr, "bufhidden", "wipe")
  end
  local winid = vim.api.nvim_open_win(bufnr, false, {
    relative = "editor",
    width = vim.o.columns,
    height = vim.o.lines,
    row = 0,
    col = 0,
    noautocmd = true,
  })
  local winnr = vim.api.nvim_win_get_number(winid)
  vim.cmd.wincmd({ count = winnr, args = { "w" }, mods = { noautocmd = true } })
  callback()
  vim.cmd.close({ count = winnr, mods = { noautocmd = true, emsg_silent = true } })
end

---This is a hack so we don't end up in insert mode after starting a task
---@param prev_mode string The vim mode we were in before opening a terminal
M.hack_around_termopen_autocmd = function(prev_mode)
  -- It's common to have autocmds that enter insert mode when opening a terminal
  vim.defer_fn(function()
    local new_mode = vim.api.nvim_get_mode().mode
    if new_mode ~= prev_mode then
      if string.find(new_mode, "i") == 1 then
        vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<ESC>", true, true, true), "n", false)
        if string.find(prev_mode, "v") == 1 or string.find(prev_mode, "V") == 1 then
          vim.cmd.normal({ bang = true, args = { "gv" } })
        end
      end
    end
  end, 10)
end

return M
