-- The caller tree: a symbol at the root, its call sites as children, and each
-- of those expandable into *its own* callers, so you can walk a chain upwards.
local config = require("caller.config")
local scan = require("caller.scan")
local resolve = require("caller.resolve")
local lsp = require("caller.lsp")

local M = {}

local Tree = {}
Tree.__index = Tree

--- The owner a call site must belong to for it to count. Derived from the
--- function that contains the call: a method belongs to its class, a free
--- function to its module.
function M.owner_of_node(occ)
  if not occ then
    return nil
  end
  if occ.caller_class then
    return "class:" .. occ.caller_class
  end
  return "module:" .. occ.path
end

function M.new(symbol, root, target_owner, engine)
  return setmetatable({
    symbol = symbol,
    root = root,
    engine = engine or {},       -- { kind = "grep"|"lsp", client, method, item }
    target_owner = target_owner, -- nil = accept every owner
    nodes = {},                  -- top level children
    loaded = false,
    defs = {},
    err = nil,
    filter = config.options.filter_by_type and target_owner ~= nil,
  }, Tree)
end

local function make_call_node(occ, depth, ancestors, target_owner)
  local sym = occ.caller_search
  -- Identify a caller by owner *and* name: a controller `getUser` is not the
  -- same function as `UserService.getUser`, so seeing one is not recursion
  -- just because the other is already in the chain.
  local key = sym and ((M.owner_of_node(occ) or "?") .. "\0" .. sym) or nil
  local anc = vim.deepcopy(ancestors)
  if key then
    anc[key] = true
  end
  return {
    kind = occ.kind, -- "call" | "ref"
    occ = occ,
    depth = depth,
    ancestors = anc,
    children = nil,
    expanded = false,
    -- Expandable only when we have a name we can actually search for.
    expandable = sym ~= nil,
    -- A caller name we derived but cannot search (e.g. a computed key).
    unresolvable = occ.caller ~= nil and sym == nil,
    recursive = key ~= nil and ancestors[key] == true,
    -- Does this call site actually reach the target definition?
    match = occ.owner == "lsp" or target_owner == nil
      or resolve.owner_matches(occ.owner, target_owner, occ.path),
    resolved = occ.owner ~= nil,
  }
end

--- Build child nodes for a symbol.
local function children_for(symbol, root, depth, ancestors, target_owner, opts)
  local g, _, err = scan.callers(symbol, root, opts)
  if err then
    return nil, err
  end

  local out = {}
  for _, o in ipairs(g.calls) do
    table.insert(out, make_call_node(o, depth, ancestors, target_owner))
  end
  if config.options.show_refs then
    for _, o in ipairs(g.refs) do
      table.insert(out, make_call_node(o, depth, ancestors, target_owner))
    end
  end
  return out, nil, g.defs
end

function Tree:load(opts)
  -- LSP engine: the server already knows exactly who calls what, so there is
  -- no searching, no owner resolution and nothing to filter.
  if self.engine.kind == "lsp" then
    local occs
    if self.engine.item then
      occs = lsp.incoming(self.engine.client, self.engine.item, self.root, config.options.lsp_timeout)
    else
      occs = lsp.references_callers(self.engine.client, self.engine.bufnr or 0, self.root, config.options.lsp_timeout)
    end
    if not occs then
      self.err = "the language server did not answer in time"
      self.nodes = {}
      return false
    end
    local kids = {}
    for _, o in ipairs(occs) do
      table.insert(kids, make_call_node(o, 1, {}, nil))
    end
    table.sort(kids, function(a, b)
      if a.occ.rel ~= b.occ.rel then
        return a.occ.rel < b.occ.rel
      end
      return a.occ.lnum < b.occ.lnum
    end)
    self.nodes = kids
    self.defs = {}
    self.loaded = true
    self.filter = false
    self.err = nil
    return true
  end

  -- Seed the ancestor set with the queried symbol so a same-named function
  -- elsewhere in the repo is flagged instead of re-expanding the same search.
  local seed = {}
  if self.target_owner then
    seed[self.target_owner .. "\0" .. self.symbol] = true
  end
  local kids, err, defs = children_for(self.symbol, self.root, 1, seed, self.target_owner, opts)
  if err then
    self.err = err
    self.nodes = {}
    return false
  end
  self.err = nil
  self.nodes = kids
  self.defs = defs or {}
  self.loaded = true
  return true
end

--- Expand a node: find who calls *its* caller function.
function Tree:expand(node)
  if node.children then
    node.expanded = true
    return true
  end

  if self.engine.kind == "lsp" then
    local occs
    if node.occ.item then
      occs = lsp.incoming(self.engine.client, node.occ.item, self.root, config.options.lsp_timeout)
    elseif node.occ.ref_pos then
      occs = lsp.references_at(self.engine.client, node.occ.ref_pos, self.root, config.options.lsp_timeout)
    end
    if not occs then
      return false
    end
    local kids = {}
    for _, o in ipairs(occs) do
      table.insert(kids, make_call_node(o, node.depth + 1, node.ancestors, nil))
    end
    node.children = kids
    node.expanded = true
    return true
  end
  local sym = node.occ.caller_search
  if not sym then
    return false -- module scope, or a name we cannot search for
  end
  if node.recursive then
    node.children = {}
    node.expanded = true
    return true
  end
  -- Callers of *this* caller must resolve to whatever owns this caller.
  local kids, err = children_for(sym, self.root, node.depth + 1, node.ancestors, M.owner_of_node(node.occ))
  if err then
    self.err = err
    return false
  end
  node.children = kids
  node.expanded = true
  return true
end

function Tree:toggle(node)
  if node.expanded then
    node.expanded = false
    return true
  end
  return self:expand(node)
end

--- Expand everything down to `max_depth`.
function Tree:expand_all(max_depth)
  max_depth = max_depth or config.options.max_auto_depth
  local function walk(nodes)
    for _, n in ipairs(nodes) do
      if n.depth < max_depth and n.expandable and not n.recursive then
        self:expand(n)
        if n.children then
          walk(n.children)
        end
      end
    end
  end
  walk(self.nodes)
end

function Tree:collapse_all()
  local function walk(nodes)
    for _, n in ipairs(nodes) do
      n.expanded = false
      if n.children then
        walk(n.children)
      end
    end
  end
  walk(self.nodes)
end

--- Direct call sites of the queried symbol, and how many rows are on screen.
function Tree:count()
  local calls, refs = 0, 0
  for _, n in ipairs(self.nodes) do
    if self:visible(n) then
      if n.kind == "call" then
        calls = calls + 1
      else
        refs = refs + 1
      end
    end
  end

  local total = 0
  local function walk(nodes)
    for _, n in ipairs(nodes) do
      if self:visible(n) then
        total = total + 1
        if n.expanded and n.children then
          walk(n.children)
        end
      end
    end
  end
  walk(self.nodes)

  return calls, refs, total
end

--- Is this node currently visible?
function Tree:visible(n)
  return n.match or not self.filter
end

--- Flatten the tree into visible rows, grouping the top level by file.
---@return table[] rows  { kind, node, text }
function Tree:rows()
  local rows = {}

  local function emit_node(n)
    table.insert(rows, { kind = "entry", node = n })
    if n.expanded and n.children then
      local shown, hidden = {}, 0
      for _, c in ipairs(n.children) do
        if self:visible(c) then
          table.insert(shown, c)
        else
          hidden = hidden + 1
        end
      end
      if #shown == 0 and hidden == 0 then
        table.insert(rows, {
          kind = "note",
          depth = n.depth + 1,
          text = n.recursive and "recursive - already in this chain" or "no callers found (entry point)",
        })
      end
      for _, c in ipairs(shown) do
        emit_node(c)
      end
      if hidden > 0 then
        table.insert(rows, {
          kind = "note",
          depth = n.depth + 1,
          text = ("%d same-name %s on another type (t to show)"):format(hidden, hidden == 1 and "call" or "calls"),
        })
      end
    end
  end

  local last_file, hidden_top = nil, 0
  for _, n in ipairs(self.nodes) do
    if self:visible(n) then
      if n.occ.rel ~= last_file then
        last_file = n.occ.rel
        table.insert(rows, { kind = "file", text = n.occ.rel })
      end
      emit_node(n)
    else
      hidden_top = hidden_top + 1
    end
  end

  if hidden_top > 0 then
    table.insert(rows, { kind = "note", depth = 0, text = "" })
    table.insert(rows, {
      kind = "note",
      depth = 0,
      text = ("%d call %s a different %s of the same name - hidden (t to show)"):format(
        hidden_top,
        hidden_top == 1 and "site reaches" or "sites reach",
        "function"
      ),
    })
  end

  return rows
end

return M
