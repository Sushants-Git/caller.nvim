-- Finding candidate files with ripgrep, then handing them to the treesitter analyser.
local config = require("caller.config")
local ts = require("caller.ts")
local resolve = require("caller.resolve")

local M = {}

local cache = {} -- [root .. "\0" .. symbol] = occurrences

function M.clear_cache()
  cache = {}
  resolve.clear_cache()
end

--- Which type or module does this occurrence belong to?
---   class:Foo    - a method on class Foo
---   module:/abs  - a free function living in that module
---   nil          - we could not tell
local function owner_of(occ, symbol)
  if occ.kind == "def" then
    return occ.caller_class and ("class:" .. occ.caller_class) or ("module:" .. occ.path)
  end

  if occ.receiver and occ.receiver ~= "" then
    return resolve.owner_of_receiver(occ.path, occ.receiver, occ.caller_class)
  end

  -- No receiver: a bare `symbol(...)` or a bare reference. Follow the binding
  -- to whichever module supplies it, else it is defined right here.
  local ok, owner = pcall(resolve.resolve_binding, occ.path, symbol)
  if ok and owner then
    return owner
  end
  return "module:" .. occ.path
end

--- Project root: explicit config, else git root of `path`, else cwd.
function M.root(path)
  local opt = config.options.root
  if type(opt) == "function" then
    return vim.fn.fnamemodify(opt(path), ":p"):gsub("/$", "")
  elseif type(opt) == "string" then
    return vim.fn.fnamemodify(opt, ":p"):gsub("/$", "")
  end

  local dir = path and path ~= "" and vim.fn.fnamemodify(path, ":h") or vim.fn.getcwd()
  local res = vim.system({ "git", "-C", dir, "rev-parse", "--show-toplevel" }, { text = true }):wait()
  if res.code == 0 then
    local root = vim.trim(res.stdout or "")
    if root ~= "" then
      return root
    end
  end
  return vim.fn.getcwd()
end

local function rg_args(symbol, root)
  local args = { "rg", "--files-with-matches", "--word-regexp", "--fixed-strings", "--no-messages" }
  for _, g in ipairs(config.options.globs) do
    table.insert(args, "--glob")
    table.insert(args, g)
  end
  for _, d in ipairs(config.options.exclude) do
    table.insert(args, "--glob")
    table.insert(args, "!**/" .. d .. "/**")
  end
  table.insert(args, "--")
  table.insert(args, symbol)
  table.insert(args, root)
  return args
end

--- All occurrences of `symbol` under `root`, classified and attributed.
---@param symbol string
---@param root string
---@param opts? { refresh?: boolean }
---@return table[] occurrences, string|nil err
function M.occurrences(symbol, root, opts)
  opts = opts or {}
  local key = root .. "\0" .. symbol
  if not opts.refresh and cache[key] then
    return cache[key], nil
  end

  if vim.fn.executable("rg") ~= 1 then
    return {}, "caller.nvim needs ripgrep (`rg`) on your PATH"
  end

  local res = vim.system(rg_args(symbol, root), { text = true }):wait()
  -- rg exits 1 when there are no matches; that is not an error for us.
  if res.code ~= 0 and res.code ~= 1 then
    return {}, "ripgrep failed: " .. vim.trim(res.stderr or "unknown error")
  end

  local files = {}
  for line in (res.stdout or ""):gmatch("[^\n]+") do
    table.insert(files, line)
  end

  local out = {}
  for _, file in ipairs(files) do
    local fd = io.open(file, "r")
    if fd then
      local content = fd:read("*a")
      fd:close()
      for _, occ in ipairs(ts.analyse(file, content, symbol)) do
        occ.rel = file:sub(#root + 2)
        occ.owner = owner_of(occ, symbol)
        table.insert(out, occ)
        if #out >= config.options.max_hits then
          break
        end
      end
    end
    if #out >= config.options.max_hits then
      break
    end
  end

  table.sort(out, function(a, b)
    if a.rel ~= b.rel then
      return a.rel < b.rel
    end
    return a.lnum < b.lnum
  end)

  cache[key] = out
  return out, nil
end

--- Just the call sites (and optionally non-call references) of `symbol`,
--- with the definition sites filtered out.
function M.callers(symbol, root, opts)
  local occs, err = M.occurrences(symbol, root, opts)
  if err then
    return nil, nil, err
  end

  local calls, refs, defs = {}, {}, {}
  for _, o in ipairs(occs) do
    if o.kind == "call" then
      table.insert(calls, o)
    elseif o.kind == "def" then
      table.insert(defs, o)
    elseif o.kind == "ref" then
      table.insert(refs, o)
    end
  end
  return { calls = calls, refs = refs, defs = defs }, occs, nil
end

return M
