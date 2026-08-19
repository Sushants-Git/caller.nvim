local config = require("caller.config")
local scan = require("caller.scan")
local lsp = require("caller.lsp")
local tree = require("caller.tree")
local ui = require("caller.ui")

local M = {}

M.setup = function(opts)
  config.setup(opts)
  ui.setup_highlights()
  -- Register :Telescope caller when telescope is available.
  pcall(function()
    require("telescope").load_extension("caller")
  end)
  return M
end

--- Telescope picker over the same results.
function M.pick(opts)
  return require("caller.pick").callers(opts)
end

--- Identifier under the cursor, preferring the treesitter node so that
--- `svc.getProfile(id)` resolves to `getProfile`.
function M.symbol_under_cursor()
  local ok, node = pcall(vim.treesitter.get_node)
  if ok and node then
    local t = node:type()
    if t == "identifier" or t == "property_identifier" or t == "shorthand_property_identifier" then
      local ok2, txt = pcall(vim.treesitter.get_node_text, node, 0)
      if ok2 and txt and txt ~= "" then
        return txt
      end
    end
  end
  local cword = vim.fn.expand("<cword>")
  return cword ~= "" and cword or nil
end

--- Which of possibly several same-named functions did the user mean?
--- Prefer whatever sits under the cursor: a definition names itself, and a
--- call site names its receiver's type. Fall back to the sole definition.
---@return string|nil owner, table|nil occurrence
function M.target_owner(occs, symbol)
  local path = vim.api.nvim_buf_get_name(0)
  local lnum = vim.api.nvim_win_get_cursor(0)[1]

  local here = nil
  for _, o in ipairs(occs) do
    if o.path == path and o.lnum == lnum then
      -- a definition on this line wins outright
      if o.kind == "def" then
        return o.owner, o
      end
      here = here or o
    end
  end
  if here and here.owner then
    return here.owner, here
  end

  local defs = {}
  for _, o in ipairs(occs) do
    if o.kind == "def" then
      table.insert(defs, o)
    end
  end
  if #defs == 1 then
    return defs[1].owner, defs[1]
  end

  return nil, nil
end

--- Decide which engine answers this question.
--- "auto" prefers the language server, because it is a real type checker and
--- works in whatever language it speaks; ripgrep+treesitter is the fallback
--- when no capable server is attached.
---@return table engine  { kind, client, method, item, bufnr }
function M.pick_engine(opts)
  local want = opts.engine or config.options.engine
  if want == "grep" then
    return { kind = "grep" }
  end

  local bufnr = vim.api.nvim_get_current_buf()
  local client, method = lsp.client(bufnr)
  if not client then
    if want == "lsp" then
      return { kind = "none", reason = "no language server attached to this buffer" }
    end
    return { kind = "grep" }
  end

  local engine = { kind = "lsp", client = client, method = method, bufnr = bufnr }
  if method == "callHierarchy" then
    local item = lsp.prepare(client, bufnr, config.options.lsp_timeout)
    if not item then
      if want == "lsp" then
        return { kind = "none", reason = "the server found no symbol under the cursor" }
      end
      return { kind = "grep" }
    end
    engine.item = item
    engine.symbol = item.name
  end
  return engine
end

--- Open the caller tree for `symbol` (defaults to the symbol under the cursor).
---@param symbol? string
---@param opts? { root?: string, refresh?: boolean }
function M.find(symbol, opts)
  opts = opts or {}
  opts.symbol_given = symbol ~= nil
  symbol = symbol or M.symbol_under_cursor()
  if not symbol or symbol == "" then
    vim.notify("caller: no symbol under the cursor", vim.log.levels.WARN)
    return
  end
  if not symbol:match("^[%a_$][%w_$]*$") then
    vim.notify("caller: '" .. symbol .. "' is not an identifier", vim.log.levels.WARN)
    return
  end

  local root = opts.root or scan.root(vim.api.nvim_buf_get_name(0))
  if opts.refresh then
    scan.clear_cache()
    lsp.clear_cache()
  end

  -- The engine is chosen from the *cursor*, so only do it when we were not
  -- handed an explicit symbol to look up.
  local engine = opts.engine_override
  if not engine then
    engine = (opts.symbol_given or opts.owner) and { kind = "grep" } or M.pick_engine(opts)
  end
  if engine.kind == "none" then
    vim.notify("caller: " .. (engine.reason or "no engine available"), vim.log.levels.WARN)
    return
  end
  if engine.symbol then
    symbol = engine.symbol
  end

  local owner = opts.owner
  if engine.kind == "grep" then
    -- Resolve which same-named function the user actually means before
    -- building the tree, so call sites on unrelated types are filtered out.
    local occs = scan.occurrences(symbol, root, { refresh = opts.refresh })
    if owner == nil and not opts.all then
      owner = M.target_owner(occs, symbol)
    end
  end

  local t = tree.new(symbol, root, owner, engine)
  t:load({ refresh = opts.refresh })
  if t.err then
    vim.notify("caller: " .. t.err, vim.log.levels.ERROR)
    return
  end
  return ui.open(t)
end

--- Same search, straight into the quickfix list.
function M.quickfix(symbol, opts)
  opts = opts or {}
  symbol = symbol or M.symbol_under_cursor()
  if not symbol then
    vim.notify("caller: no symbol under the cursor", vim.log.levels.WARN)
    return
  end
  local root = opts.root or scan.root(vim.api.nvim_buf_get_name(0))
  local g, occs, err = scan.callers(symbol, root, { refresh = opts.refresh })
  if err then
    vim.notify("caller: " .. err, vim.log.levels.ERROR)
    return
  end

  local owner = opts.owner
  if owner == nil and not opts.all then
    owner = M.target_owner(occs, symbol)
  end
  local resolve = require("caller.resolve")

  local items, skipped = {}, 0
  local function add(list, tag)
    for _, o in ipairs(list) do
      if owner and not resolve.owner_matches(o.owner, owner, o.path) then
        skipped = skipped + 1
        goto continue
      end
      table.insert(items, {
        filename = o.path,
        lnum = o.lnum,
        col = o.col,
        text = string.format(
          "%s%s%s  |  %s",
          tag,
          o.caller_class and (o.caller_class .. ".") or "",
          o.caller or "‹module scope›",
          o.line
        ),
      })
      ::continue::
    end
  end
  add(g.calls, "")
  if config.options.show_refs then
    add(g.refs, "[ref] ")
  end

  if #items == 0 then
    vim.notify("caller: nothing calls " .. symbol, vim.log.levels.INFO)
    return
  end
  local title = "callers of " .. (owner and owner:gsub("^class:", ""):gsub("^module:.*/", "") .. "." or "") .. symbol
  vim.fn.setqflist({}, " ", { title = title, items = items })
  vim.cmd("copen")
  if skipped > 0 then
    vim.notify(
      ("caller: hid %d same-name call site%s on other types (:CallerQfAll for all)"):format(
        skipped,
        skipped == 1 and "" or "s"
      ),
      vim.log.levels.INFO
    )
  end
end

return M
