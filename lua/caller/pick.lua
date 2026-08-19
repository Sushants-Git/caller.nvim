-- Telescope front-end: the same analysis, in a picker with a live preview.
-- The tree's recursion becomes a stack of pickers - <C-l> drills into the
-- callers of whatever is selected, <C-h> pops back.
local config = require("caller.config")
local scan = require("caller.scan")
local tree = require("caller.tree")

local M = {}

local function telescope()
  local ok, t = pcall(require, "telescope")
  if not ok then
    return nil
  end
  return t
end

--- One display row per call site.
local function make_entry_maker(root)
  local entry_display = require("telescope.pickers.entry_display")
  local displayer = entry_display.create({
    separator = "  ",
    items = {
      { width = 34 },
      { width = 28 },
      { width = 26 },
      { remaining = true },
    },
  })

  return function(occ)
    local name = occ.caller or "‹module scope›"
    if occ.kind == "ref" then
      name = "ref " .. name
    end
    local loc = occ.rel .. ":" .. occ.lnum

    return {
      value = occ,
      occ = occ,
      filename = occ.path,
      lnum = occ.lnum,
      col = occ.col,
      ordinal = table.concat({
        occ.caller or "",
        occ.caller_class or "",
        occ.receiver or "",
        occ.rel,
        occ.line,
      }, " "),
      display = function()
        return displayer({
          { name, occ.kind == "ref" and "Comment" or "Function" },
          { occ.caller_class or "", "Type" },
          { occ.receiver and ("via " .. occ.receiver) or "", "Identifier" },
          { loc, "LineNr" },
        })
      end,
    }
  end
end

local function title_for(symbol, owner, stack)
  local parts = {}
  for _, s in ipairs(stack) do
    table.insert(parts, s.symbol)
  end
  table.insert(parts, symbol)
  local chain = table.concat(parts, " ← ")

  local suffix = ""
  if type(owner) == "string" then
    local cls = owner:match("^class:(.+)$")
    suffix = cls and ("  [" .. cls .. "]") or "  [module]"
  elseif owner == nil then
    suffix = "  [all owners]"
  end
  return "callers of " .. chain .. suffix
end

--- The tree spec that answers "who calls the function this node sits in?".
local function next_spec(t, node)
  if t.engine.kind == "lsp" then
    return {
      symbol = node.occ.caller or t.symbol,
      engine = {
        kind = "lsp",
        client = t.engine.client,
        method = t.engine.method,
        item = node.occ.item,
        ref_pos = node.occ.ref_pos,
      },
    }
  end
  return {
    symbol = node.occ.caller_search,
    owner = tree.owner_of_node(node.occ),
    engine = { kind = "grep" },
  }
end

--- Open a picker of everything that calls `symbol`.
---@param opts? { symbol?, root?, owner?, all?, refresh?, stack?, filter?, engine? }
function M.callers(opts)
  opts = opts or {}
  if not telescope() then
    vim.notify("caller: telescope.nvim is not installed", vim.log.levels.WARN)
    return
  end

  local pickers = require("telescope.pickers")
  local finders = require("telescope.finders")
  local conf = require("telescope.config").values
  local actions = require("telescope.actions")
  local action_state = require("telescope.actions.state")

  local caller = require("caller")
  local root = opts.root or scan.root(vim.api.nvim_buf_get_name(0))
  if opts.refresh then
    scan.clear_cache()
    require("caller.lsp").clear_cache()
  end

  -- Engine first: with a language server we ask it directly and skip both the
  -- ripgrep search and the owner resolution entirely.
  local engine = opts.engine
  if not engine then
    engine = opts.symbol and { kind = "grep" } or caller.pick_engine(opts)
    if engine.kind == "none" then
      vim.notify("caller: " .. (engine.reason or "no engine available"), vim.log.levels.WARN)
      return
    end
  end

  local symbol = opts.symbol or engine.symbol or caller.symbol_under_cursor()
  if not symbol then
    vim.notify("caller: no identifier under the cursor", vim.log.levels.WARN)
    return
  end

  local owner = opts.owner
  if engine.kind == "grep" and owner == nil and not opts.all then
    owner = caller.target_owner(scan.occurrences(symbol, root, { refresh = opts.refresh }), symbol)
  end

  local t = tree.new(symbol, root, owner, engine)
  t:load({ refresh = opts.refresh })
  if t.err then
    vim.notify("caller: " .. t.err, vim.log.levels.ERROR)
    return
  end
  if opts.filter ~= nil then
    t.filter = opts.filter
  end

  local entries, hidden = {}, 0
  for _, n in ipairs(t.nodes) do
    if t:visible(n) then
      table.insert(entries, n.occ)
    else
      hidden = hidden + 1
    end
  end

  if #entries == 0 then
    vim.notify(
      ("caller: nothing calls %s%s"):format(symbol, hidden > 0 and (" (" .. hidden .. " hidden by type filter)") or ""),
      vim.log.levels.INFO
    )
    return
  end

  local stack = opts.stack or {}
  local title
  if engine.kind == "lsp" then
    title = title_for(symbol, false, stack) .. "  [" .. (engine.client and engine.client.name or "lsp") .. "]"
  else
    title = title_for(symbol, t.filter and owner or nil, stack)
  end
  if hidden > 0 then
    title = title .. ("  (%d hidden)"):format(hidden)
  end

  local by_occ = {}
  for _, n in ipairs(t.nodes) do
    by_occ[n.occ] = n
  end

  local function reopen(bufnr, override)
    actions.close(bufnr)
    vim.schedule(function()
      M.callers(vim.tbl_extend("force", {
        symbol = symbol,
        root = root,
        owner = owner,
        all = opts.all,
        stack = stack,
        filter = t.filter,
        engine = engine,
      }, override))
    end)
  end

  pickers
    .new(opts, {
      prompt_title = title,
      finder = finders.new_table({
        results = entries,
        entry_maker = make_entry_maker(root),
      }),
      sorter = conf.generic_sorter(opts),
      previewer = conf.grep_previewer(opts),
      attach_mappings = function(bufnr, map)
        -- <C-l>: who calls the selected caller? (push a level)
        map({ "i", "n" }, "<C-l>", function()
          local sel = action_state.get_selected_entry()
          local node = sel and by_occ[sel.occ]
          if not node then
            return
          end
          local spec = next_spec(t, node)
          if not spec.symbol and not (spec.engine.item or spec.engine.ref_pos) then
            vim.notify("caller: nothing above this call site", vim.log.levels.INFO)
            return
          end
          local next_stack = vim.deepcopy(stack)
          table.insert(next_stack, { symbol = symbol, owner = owner, root = root, engine = engine })
          actions.close(bufnr)
          vim.schedule(function()
            M.callers({
              symbol = spec.symbol,
              root = root,
              owner = spec.owner,
              engine = spec.engine,
              stack = next_stack,
            })
          end)
        end)

        -- <C-h>: back down a level
        map({ "i", "n" }, "<C-h>", function()
          if #stack == 0 then
            vim.notify("caller: already at the top of the chain", vim.log.levels.INFO)
            return
          end
          local prev = stack[#stack]
          local next_stack = vim.deepcopy(stack)
          table.remove(next_stack)
          actions.close(bufnr)
          vim.schedule(function()
            M.callers({
              symbol = prev.symbol,
              root = prev.root,
              owner = prev.owner,
              engine = prev.engine,
              stack = next_stack,
            })
          end)
        end)

        map({ "i", "n" }, "<C-f>", function()
          if engine.kind == "lsp" then
            vim.notify("caller: the language server already resolved these exactly", vim.log.levels.INFO)
            return
          end
          reopen(bufnr, { filter = not t.filter })
        end)

        map({ "i", "n" }, "<C-y>", function()
          config.options.show_refs = not config.options.show_refs
          reopen(bufnr, {})
        end)

        map({ "i", "n" }, "<C-o>", function()
          actions.close(bufnr)
          vim.schedule(function()
            require("caller").find(symbol, { root = root, owner = owner, engine_override = engine })
          end)
        end)

        return true
      end,
    })
    :find()
end

return M
