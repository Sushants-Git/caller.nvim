-- Floating window that renders a caller tree and lets you walk it.
local config = require("caller.config")

local M = {}

local NS = vim.api.nvim_create_namespace("caller.nvim")

local HL = {
  header = "CallerHeader",
  symbol = "CallerSymbol",
  count = "CallerCount",
  file = "CallerFile",
  chevron = "CallerChevron",
  name = "CallerName",
  class = "CallerClass",
  recv = "CallerRecv",
  loc = "CallerLoc",
  snippet = "CallerSnippet",
  note = "CallerNote",
  ref = "CallerRef",
  hint = "CallerHint",
}

function M.setup_highlights()
  local link = {
    [HL.header] = "Title",
    [HL.symbol] = "Function",
    [HL.count] = "Number",
    [HL.file] = "Directory",
    [HL.chevron] = "Special",
    [HL.name] = "Function",
    [HL.class] = "Type",
    [HL.recv] = "Identifier",
    [HL.loc] = "LineNr",
    [HL.snippet] = "Comment",
    [HL.note] = "Comment",
    [HL.ref] = "WarningMsg",
    [HL.hint] = "NonText",
  }
  for group, target in pairs(link) do
    vim.api.nvim_set_hl(0, group, { link = target, default = true })
  end
end

---@class caller.View
local View = {}
View.__index = View

local function seg(parts, hl, text)
  if text == nil or text == "" then
    return
  end
  table.insert(parts, { hl = hl, text = text })
end

local function join(parts)
  local line, hls, col = "", {}, 0
  for _, p in ipairs(parts) do
    line = line .. p.text
    if p.hl then
      table.insert(hls, { p.hl, col, col + #p.text })
    end
    col = col + #p.text
  end
  return line, hls
end

local function truncate(s, n)
  if vim.fn.strdisplaywidth(s) <= n then
    return s
  end
  return vim.fn.strcharpart(s, 0, n - 1) .. "…"
end

function View:render()
  local tree = self.tree
  local lines, highlights = {}, {}
  self.row_at = {}

  local function push(parts)
    local line, hls = join(parts)
    table.insert(lines, line)
    for _, h in ipairs(hls) do
      table.insert(highlights, { #lines - 1, h[1], h[2], h[3] })
    end
    return #lines
  end

  -- Header
  local calls, refs, total = tree:count()
  local head = {}
  seg(head, HL.symbol, tree.symbol)
  seg(head, HL.header, "  ")
  seg(head, HL.count, tostring(calls))
  seg(head, HL.header, calls == 1 and " caller" or " callers")
  if refs > 0 then
    seg(head, HL.header, "  ·  ")
    seg(head, HL.count, tostring(refs))
    seg(head, HL.header, refs == 1 and " reference" or " references")
  end
  if total > calls + refs then
    seg(head, HL.header, "  ·  ")
    seg(head, HL.count, tostring(total))
    seg(head, HL.header, " in chain")
  end
  seg(head, HL.loc, "   " .. vim.fn.fnamemodify(tree.root, ":t"))
  if tree.engine and tree.engine.kind == "lsp" then
    seg(head, HL.class, "   via " .. (tree.engine.client and tree.engine.client.name or "lsp"))
  end
  push(head)

  if tree.engine and tree.engine.kind == "lsp" then
    local tl = {}
    seg(tl, HL.note, "resolved by the language server (" .. (tree.engine.method or "?") .. ")")
    push(tl)
  elseif tree.target_owner then
    local cls = tree.target_owner:match("^class:(.+)$")
    local tl = {}
    seg(tl, HL.note, "resolved  ")
    if cls then
      seg(tl, HL.class, cls)
      seg(tl, HL.note, "." .. tree.symbol)
    else
      seg(tl, HL.note, "free function in ")
      seg(tl, HL.file, (tree.target_owner:gsub("^module:", ""):gsub("^" .. vim.pesc(tree.root) .. "/", "")))
    end
    if not tree.filter then
      seg(tl, HL.ref, "   filter off")
    end
    push(tl)
  elseif #(tree.defs or {}) > 1 then
    push({ { hl = HL.ref, text = "ambiguous - " .. #tree.defs .. " definitions share this name; showing all" } })
  end

  for _, d in ipairs(tree.defs or {}) do
    local dl = {}
    seg(dl, HL.note, "defined  ")
    seg(dl, HL.class, d.caller_class and (d.caller_class .. "  ") or "")
    seg(dl, HL.loc, d.rel .. ":" .. d.lnum)
    push(dl)
  end

  push({ { hl = HL.hint, text = "" } })
  self.header_lines = #lines

  if tree.err then
    push({ { hl = "ErrorMsg", text = "  " .. tree.err } })
  elseif #tree.nodes == 0 then
    push({ { hl = HL.note, text = "  nothing calls this in " .. tree.root } })
  end

  local width = self.width or 100

  for _, row in ipairs(tree:rows()) do
    if row.kind == "file" then
      push({ { hl = HL.file, text = row.text } })
      self.row_at[#lines] = nil
    elseif row.kind == "note" then
      push({ { hl = HL.note, text = string.rep("  ", row.depth) .. "  " .. row.text } })
      self.row_at[#lines] = nil
    else
      local n = row.node
      local occ = n.occ
      local indent = string.rep("  ", n.depth)
      local parts = {}

      local expandable = n.expandable
      local chev
      if not expandable then
        chev = "· "
      elseif n.expanded then
        chev = "▾ "
      else
        chev = "▸ "
      end
      seg(parts, HL.chevron, indent .. chev)

      if n.kind == "ref" then
        seg(parts, HL.ref, "ref ")
      end

      local name = occ.caller or "‹module scope›"
      seg(parts, occ.caller and HL.name or HL.note, name)
      if occ.via_callback then
        seg(parts, HL.note, " ›callback")
      end
      if n.unresolvable then
        seg(parts, HL.ref, " ?")
      end
      if not n.resolved then
        seg(parts, HL.ref, " unresolved")
      end
      if occ.caller_class then
        seg(parts, HL.class, "  " .. occ.caller_class)
      end
      if occ.receiver and occ.receiver ~= "" then
        seg(parts, HL.recv, "  via " .. occ.receiver)
      end

      local loc = (n.depth == 1) and (":" .. occ.lnum) or (occ.rel .. ":" .. occ.lnum)
      seg(parts, HL.loc, "  " .. loc)

      local sofar = 0
      for _, p in ipairs(parts) do
        sofar = sofar + vim.fn.strdisplaywidth(p.text)
      end
      local room = width - sofar - 4
      if room > 20 then
        seg(parts, HL.snippet, "  " .. truncate(occ.line, room))
      end

      local ln = push(parts)
      self.row_at[ln] = n
    end
  end

  vim.bo[self.buf].modifiable = true
  vim.api.nvim_buf_set_lines(self.buf, 0, -1, false, lines)
  vim.bo[self.buf].modifiable = false

  vim.api.nvim_buf_clear_namespace(self.buf, NS, 0, -1)
  for _, h in ipairs(highlights) do
    pcall(vim.api.nvim_buf_set_extmark, self.buf, NS, h[1], h[3], {
      end_col = h[4],
      hl_group = h[2],
    })
  end
end

function View:node_under_cursor()
  local ln = vim.api.nvim_win_get_cursor(self.win)[1]
  return self.row_at[ln]
end

function View:close()
  if self.win and vim.api.nvim_win_is_valid(self.win) then
    vim.api.nvim_win_close(self.win, true)
  end
  self.win = nil
end

function View:jump(node, how)
  if not node then
    return
  end
  local occ = node.occ
  local prev = self.prev_win
  self:close()
  if prev and vim.api.nvim_win_is_valid(prev) then
    vim.api.nvim_set_current_win(prev)
  end
  local cmd = ({ edit = "edit", split = "split", vsplit = "vsplit", tab = "tabedit" })[how] or "edit"
  vim.cmd(cmd .. " " .. vim.fn.fnameescape(occ.path))
  pcall(vim.api.nvim_win_set_cursor, 0, { occ.lnum, math.max(occ.col - 1, 0) })
  vim.cmd("normal! zz")
end

local function map(buf, keys, fn)
  if type(keys) == "string" then
    keys = { keys }
  end
  for _, k in ipairs(keys or {}) do
    vim.keymap.set("n", k, fn, { buffer = buf, nowait = true, silent = true })
  end
end

function View:keymaps()
  local keys = config.options.keys
  local buf = self.buf

  map(buf, keys.close, function()
    self:close()
  end)

  map(buf, keys.expand, function()
    local n = self:node_under_cursor()
    if not n then
      return
    end
    if not n.expandable then
      vim.notify(
        n.unresolvable
            and ("caller: cannot search for '" .. n.occ.caller .. "' - not a plain identifier")
          or "caller: module-scope call - nothing above it",
        vim.log.levels.INFO
      )
      return
    end
    local pos = vim.api.nvim_win_get_cursor(self.win)
    self.tree:toggle(n)
    self:render()
    pcall(vim.api.nvim_win_set_cursor, self.win, pos)
  end)

  map(buf, keys.jump, function()
    self:jump(self:node_under_cursor(), "edit")
  end)
  map(buf, keys.split, function()
    self:jump(self:node_under_cursor(), "split")
  end)
  map(buf, keys.vsplit, function()
    self:jump(self:node_under_cursor(), "vsplit")
  end)
  map(buf, keys.tab, function()
    self:jump(self:node_under_cursor(), "tab")
  end)

  map(buf, keys.expand_all, function()
    self.tree:expand_all()
    self:render()
  end)
  map(buf, keys.collapse_all, function()
    self.tree:collapse_all()
    self:render()
  end)

  map(buf, keys.refresh, function()
    require("caller.scan").clear_cache()
    self.tree.nodes = {}
    self.tree:load({ refresh = true })
    self:render()
  end)

  map(buf, keys.toggle_filter, function()
    self.tree.filter = not self.tree.filter
    self:render()
    vim.notify(
      self.tree.filter and "caller: showing only calls that reach this definition"
        or "caller: showing every same-named call site",
      vim.log.levels.INFO
    )
  end)

  map(buf, keys.toggle_refs, function()
    config.options.show_refs = not config.options.show_refs
    self.tree.nodes = {}
    self.tree:load()
    self:render()
  end)

  map(buf, keys.help, function()
    local k = config.options.keys
    local first = function(v)
      return type(v) == "table" and v[1] or v
    end
    vim.notify(table.concat({
      "caller.nvim",
      first(k.expand) .. "  expand / collapse: who calls this caller?",
      first(k.jump) .. "  jump to the call site",
      k.vsplit .. " / " .. k.split .. " / " .. k.tab .. "  open in vsplit / split / tab",
      k.expand_all .. "  expand the whole tree   " .. k.collapse_all .. "  collapse it",
      k.toggle_filter .. "  toggle type filtering (same-name calls on other types)",
      k.toggle_refs .. "  toggle non-call references   " .. k.refresh .. "  rescan",
      first(k.close) .. "  close",
    }, "\n"), vim.log.levels.INFO)
  end)
end

function M.open(tree)
  M.setup_highlights()

  local ui = vim.api.nvim_list_uis()[1]
  local total_w = ui and ui.width or vim.o.columns
  local total_h = ui and ui.height or vim.o.lines
  local w = math.floor(total_w * config.options.window.width)
  local h = math.floor(total_h * config.options.window.height)

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = "caller"

  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = w,
    height = h,
    row = math.floor((total_h - h) / 2) - 1,
    col = math.floor((total_w - w) / 2),
    style = "minimal",
    border = config.options.window.border,
    title = config.options.window.title,
    title_pos = "center",
    footer = " <CR> expand  o jump  E expand-all  t filter  ? help ",
    footer_pos = "center",
  })
  vim.wo[win].wrap = false
  vim.wo[win].cursorline = true

  local view = setmetatable({
    buf = buf,
    win = win,
    width = w,
    tree = tree,
    prev_win = vim.fn.win_getid(vim.fn.winnr("#")),
  }, View)

  view:render()
  view:keymaps()

  -- Land the cursor on the first real entry.
  local target = nil
  for ln, _ in pairs(view.row_at) do
    if not target or ln < target then
      target = ln
    end
  end
  if target then
    pcall(vim.api.nvim_win_set_cursor, win, { target, 0 })
  end

  return view
end

return M
