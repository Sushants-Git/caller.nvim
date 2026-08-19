-- Telescope front-end: the same analysis, in a picker with a live preview.
-- The tree's recursion becomes a stack of pickers - <C-l> drills into the
-- callers of whatever is selected, <C-h> pops back.
local config = require("caller.config")
local scan = require("caller.scan")
local tree = require("caller.tree")
local resolve = require("caller.resolve")

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
  if owner then
    local cls = owner:match("^class:(.+)$")
    suffix = cls and ("  [" .. cls .. "]") or "  [module]"
  elseif owner == nil then
    suffix = "  [all owners]"
  end
  return "callers of " .. chain .. suffix
end

--- Open a picker of everything that calls `symbol`.
---@param opts? { symbol?, root?, owner?, all?, refresh?, stack?, filter? }
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
  local symbol = opts.symbol or caller.symbol_under_cursor()
  if not symbol or not symbol:match("^[%a_$][%w_$]*$") then
    vim.notify("caller: no identifier under the cursor", vim.log.levels.WARN)
    return
  end

  local root = opts.root or scan.root(vim.api.nvim_buf_get_name(0))
  if opts.refresh then
    scan.clear_cache()
  end

  local occs, err = scan.occurrences(symbol, root, { refresh = opts.refresh })
  if err then
    vim.notify("caller: " .. err, vim.log.levels.ERROR)
    return
  end

  local owner = opts.owner
  if owner == nil and not opts.all then
    owner = caller.target_owner(occs, symbol)
  end

  local filter = opts.filter
  if filter == nil then
    filter = config.options.filter_by_type and owner ~= nil
  end

  local stack = opts.stack or {}

  -- Collect the rows this picker will show.
  local function rows(with_filter)
    local out, hidden = {}, 0
    for _, o in ipairs(occs) do
      local keep = o.kind == "call" or (o.kind == "ref" and config.options.show_refs)
      if keep then
        if with_filter and owner and not resolve.owner_matches(o.owner, owner, o.path) then
          hidden = hidden + 1
        else
          table.insert(out, o)
        end
      end
    end
    return out, hidden
  end

  local entries, hidden = rows(filter)
  if #entries == 0 then
    vim.notify(
      ("caller: nothing calls %s%s"):format(symbol, hidden > 0 and (" (" .. hidden .. " hidden by type filter)") or ""),
      vim.log.levels.INFO
    )
    return
  end

  local title = title_for(symbol, filter and owner or nil, stack)
  if hidden > 0 then
    title = title .. ("  (%d hidden)"):format(hidden)
  end

  -- Reopen this picker with one option changed.
  local function reopen(bufnr, override)
    actions.close(bufnr)
    vim.schedule(function()
      M.callers(vim.tbl_extend("force", {
        symbol = symbol,
        root = root,
        owner = owner,
        all = opts.all,
        stack = stack,
        filter = filter,
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
          if not sel or not sel.occ then
            return
          end
          local next_symbol = sel.occ.caller_search
          if not next_symbol then
            vim.notify("caller: nothing above this call site", vim.log.levels.INFO)
            return
          end
          local next_stack = vim.deepcopy(stack)
          table.insert(next_stack, { symbol = symbol, owner = owner, root = root })
          actions.close(bufnr)
          vim.schedule(function()
            M.callers({
              symbol = next_symbol,
              root = root,
              owner = tree.owner_of_node(sel.occ),
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
            M.callers({ symbol = prev.symbol, root = prev.root, owner = prev.owner, stack = next_stack })
          end)
        end)

        -- <C-f>: toggle the type filter
        map({ "i", "n" }, "<C-f>", function()
          reopen(bufnr, { filter = not filter })
        end)

        -- <C-y>: toggle non-call references
        map({ "i", "n" }, "<C-y>", function()
          config.options.show_refs = not config.options.show_refs
          reopen(bufnr, {})
        end)

        -- <C-o>: hand off to the tree view, which shows the whole chain at once
        map({ "i", "n" }, "<C-o>", function()
          actions.close(bufnr)
          vim.schedule(function()
            require("caller").find(symbol, { root = root, owner = owner })
          end)
        end)

        return true
      end,
    })
    :find()
end

return M
