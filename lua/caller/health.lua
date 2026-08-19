local M = {}

local start = vim.health.start or vim.health.report_start
local ok = vim.health.ok or vim.health.report_ok
local warn = vim.health.warn or vim.health.report_warn
local err = vim.health.error or vim.health.report_error
local info = vim.health.info or vim.health.report_info

function M.check()
  start("caller.nvim")

  if vim.fn.executable("rg") == 1 then
    local out = vim.system({ "rg", "--version" }, { text = true }):wait()
    ok("ripgrep: " .. vim.split(out.stdout or "rg", "\n")[1])
  else
    err("ripgrep not found on PATH", {
      "caller.nvim uses `rg` to find candidate files.",
      "Install it: https://github.com/BurntSushi/ripgrep#installation",
    })
  end

  start("caller.nvim: treesitter parsers")
  local wanted = { "typescript", "tsx", "javascript" }
  local missing = {}
  for _, lang in ipairs(wanted) do
    if pcall(vim.treesitter.language.add, lang) then
      ok(lang)
    else
      table.insert(missing, lang)
    end
  end
  if #missing > 0 then
    warn("missing parsers: " .. table.concat(missing, ", "), {
      ":TSInstall " .. table.concat(missing, " "),
      "Files in those languages will be skipped.",
    })
  end

  start("caller.nvim: optional")
  if pcall(require, "telescope") then
    ok("telescope.nvim found - :CallerPick and :Telescope caller available")
  else
    info("telescope.nvim not found - tree view and quickfix still work")
  end

  start("caller.nvim: config")
  local config = require("caller.config")
  info("filter_by_type: " .. tostring(config.options.filter_by_type))
  info("show_refs:      " .. tostring(config.options.show_refs))
  info("globs:          " .. table.concat(config.options.globs, " "))
end

return M
