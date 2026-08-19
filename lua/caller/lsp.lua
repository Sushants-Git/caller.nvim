-- LSP engine.
--
-- The language server is a real type checker, so it beats our binding-follower
-- on correctness and works in any language it supports. What it does not give
-- you is a walkable chain, so we take its exact answers and keep caller.nvim's
-- presentation on top.
--
-- Preferred path is callHierarchy/incomingCalls, which already reports the
-- *calling function* for every call site. Servers without it fall back to
-- textDocument/references cross-referenced with documentSymbol, which is the
-- same thing assembled by hand.
local M = {}

local SYMBOL_FUNCTIONS = {
  [6] = true,  -- Method
  [9] = true,  -- Constructor
  [12] = true, -- Function
}
-- Containers a function can sit in; used to label a caller (`Class.method`).
local SYMBOL_CONTAINERS = {
  [5] = true,  -- Class
  [11] = true, -- Interface
  [23] = true, -- Struct
  [2] = true,  -- Module
  [3] = true,  -- Namespace
}

local line_cache = {}

function M.clear_cache()
  line_cache = {}
end

local function file_line(path, lnum)
  local lines = line_cache[path]
  if not lines then
    local bufnr = vim.fn.bufnr(path)
    if bufnr ~= -1 and vim.api.nvim_buf_is_loaded(bufnr) then
      lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    else
      lines = {}
      local fd = io.open(path, "r")
      if fd then
        for l in fd:lines() do
          lines[#lines + 1] = l
        end
        fd:close()
      end
    end
    line_cache[path] = lines
  end
  return vim.trim(lines[lnum] or "")
end

--- A client attached to `bufnr` that can answer the question.
---@return vim.lsp.Client|nil client, string|nil method  "callHierarchy" | "references"
function M.client(bufnr)
  bufnr = bufnr or 0
  local clients = vim.lsp.get_clients({ bufnr = bufnr })
  local fallback = nil
  for _, c in ipairs(clients) do
    if c.server_capabilities.callHierarchyProvider then
      return c, "callHierarchy"
    end
    if c.server_capabilities.referencesProvider and not fallback then
      fallback = c
    end
  end
  if fallback then
    return fallback, "references"
  end
  return nil, nil
end

local function request(client, method, params, timeout, bufnr)
  local ok, res = pcall(function()
    return client:request_sync(method, params, timeout or 10000, bufnr or 0)
  end)
  if not ok or not res or res.err then
    return nil
  end
  return res.result
end

--- Turn a CallHierarchyItem + one of its call ranges into an occurrence.
local function occurrence_from(item, range, root)
  local path = vim.uri_to_fname(item.uri)
  local lnum = range.start.line + 1
  local col = range.start.character + 1

  -- `detail` is where tsserver puts the containing class; gopls uses it for
  -- the package. Only keep it when it looks like a container name.
  local container = item.detail
  if container and (container:find("%s") or container == "") then
    container = nil
  end

  return {
    path = path,
    rel = root and path:sub(#root + 2) or path,
    lnum = lnum,
    col = col,
    kind = "call",
    receiver = nil,
    caller = item.name,
    caller_class = container,
    caller_search = item.name,
    caller_lnum = (item.selectionRange or item.range).start.line + 1,
    via_callback = false,
    line = file_line(path, lnum),
    -- carried so expanding this node can ask the server directly
    item = item,
    owner = "lsp", -- exact already; nothing to filter against
  }
end

--- Prepare a call-hierarchy item at a buffer position.
function M.prepare(client, bufnr, timeout)
  local params = vim.lsp.util.make_position_params(0, client.offset_encoding)
  local res = request(client, "textDocument/prepareCallHierarchy", params, timeout, bufnr)
  if not res or #res == 0 then
    return nil
  end
  return res[1]
end

--- Incoming calls for a prepared item.
---@return table[]|nil occurrences
function M.incoming(client, item, root, timeout)
  local res = request(client, "callHierarchy/incomingCalls", { item = item }, timeout, 0)
  if not res then
    return nil
  end
  local out = {}
  for _, call in ipairs(res) do
    local ranges = call.fromRanges
    if not ranges or #ranges == 0 then
      ranges = { call.from.selectionRange or call.from.range }
    end
    for _, r in ipairs(ranges) do
      table.insert(out, occurrence_from(call.from, r, root))
    end
  end
  return out
end

-- ---------------------------------------------------------------- fallback

local function flatten_symbols(symbols, out, container)
  out = out or {}
  for _, s in ipairs(symbols or {}) do
    local range = s.range or (s.location and s.location.range)
    if range then
      table.insert(out, {
        name = s.name,
        kind = s.kind,
        range = range,
        selectionRange = s.selectionRange or range,
        container = container or s.containerName,
        uri = s.location and s.location.uri or nil,
      })
    end
    if s.children then
      flatten_symbols(s.children, out, SYMBOL_CONTAINERS[s.kind] and s.name or container)
    end
  end
  return out
end

local function contains(range, line, char)
  local s, e = range.start, range["end"]
  if line < s.line or line > e.line then
    return false
  end
  if line == s.line and char < s.character then
    return false
  end
  if line == e.line and char > e.character then
    return false
  end
  return true
end

--- Innermost function symbol containing a position.
local function enclosing_symbol(symbols, line, char)
  local best = nil
  for _, s in ipairs(symbols) do
    if SYMBOL_FUNCTIONS[s.kind] and contains(s.range, line, char) then
      if not best or s.range.start.line > best.range.start.line then
        best = s
      end
    end
  end
  return best
end

--- references + documentSymbol, for servers without callHierarchy.
--- `params` defaults to the cursor position; recursion passes an explicit one.
function M.references_callers(client, bufnr, root, timeout, params)
  params = params or vim.lsp.util.make_position_params(0, client.offset_encoding)
  params.context = { includeDeclaration = false }
  local refs = request(client, "textDocument/references", params, timeout, bufnr)
  if not refs then
    return nil
  end

  local symbols_by_uri = {}
  local out = {}
  for _, loc in ipairs(refs) do
    local uri = loc.uri or loc.targetUri
    local range = loc.range or loc.targetSelectionRange
    if uri and range then
      local path = vim.uri_to_fname(uri)

      if symbols_by_uri[uri] == nil then
        local sbuf = vim.uri_to_bufnr(uri)
        vim.fn.bufload(sbuf)
        local res = request(client, "textDocument/documentSymbol", {
          textDocument = { uri = uri },
        }, timeout, sbuf)
        symbols_by_uri[uri] = flatten_symbols(res or {})
      end

      local sym = enclosing_symbol(symbols_by_uri[uri], range.start.line, range.start.character)
      table.insert(out, {
        path = path,
        rel = root and path:sub(#root + 2) or path,
        lnum = range.start.line + 1,
        col = range.start.character + 1,
        kind = "call",
        caller = sym and sym.name or nil,
        caller_class = sym and sym.container or nil,
        caller_search = sym and sym.name or nil,
        caller_lnum = sym and (sym.selectionRange.start.line + 1) or nil,
        line = file_line(path, range.start.line + 1),
        -- where to re-query from when this node is expanded
        ref_pos = sym and {
          textDocument = { uri = uri },
          position = {
            line = sym.selectionRange.start.line,
            character = sym.selectionRange.start.character,
          },
        } or nil,
        owner = "lsp",
      })
    end
  end
  return out
end

--- Callers of the function a previous result pointed at.
function M.references_at(client, pos, root, timeout)
  local bufnr = vim.uri_to_bufnr(pos.textDocument.uri)
  vim.fn.bufload(bufnr)
  return M.references_callers(client, bufnr, root, timeout, vim.deepcopy(pos))
end

return M
