if vim.g.loaded_caller then
  return
end
vim.g.loaded_caller = true

vim.api.nvim_create_user_command("Caller", function(cmd)
  require("caller").find(cmd.args ~= "" and cmd.args or nil, { refresh = cmd.bang })
end, {
  nargs = "?",
  bang = true,
  desc = "Show who calls a function (defaults to the symbol under the cursor; ! to rescan)",
})

vim.api.nvim_create_user_command("CallerQf", function(cmd)
  require("caller").quickfix(cmd.args ~= "" and cmd.args or nil, { refresh = cmd.bang })
end, {
  nargs = "?",
  bang = true,
  desc = "Send callers of a function to the quickfix list",
})

vim.api.nvim_create_user_command("CallerPick", function(cmd)
  require("caller.pick").callers({
    symbol = cmd.args ~= "" and cmd.args or nil,
    refresh = cmd.bang,
  })
end, {
  nargs = "?",
  bang = true,
  desc = "Callers in a Telescope picker with a live preview",
})

-- Force the ripgrep+treesitter engine, e.g. when the server is still starting.
vim.api.nvim_create_user_command("CallerGrep", function(cmd)
  require("caller").find(cmd.args ~= "" and cmd.args or nil, { refresh = cmd.bang, engine = "grep" })
end, {
  nargs = "?",
  bang = true,
  desc = "Callers via ripgrep + treesitter, without asking the language server",
})

-- Unfiltered variants: every same-named call site, whatever type it belongs to.
vim.api.nvim_create_user_command("CallerAll", function(cmd)
  require("caller").find(cmd.args ~= "" and cmd.args or nil, { refresh = cmd.bang, all = true })
end, {
  nargs = "?",
  bang = true,
  desc = "Show every same-named call site, without resolving types",
})

vim.api.nvim_create_user_command("CallerQfAll", function(cmd)
  require("caller").quickfix(cmd.args ~= "" and cmd.args or nil, { refresh = cmd.bang, all = true })
end, {
  nargs = "?",
  bang = true,
  desc = "Every same-named call site to the quickfix list, without resolving types",
})
