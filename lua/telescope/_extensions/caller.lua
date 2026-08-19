local ok, telescope = pcall(require, "telescope")
if not ok then
  error("caller.nvim's telescope extension needs telescope.nvim")
end

return telescope.register_extension({
  exports = {
    caller = function(opts)
      require("caller.pick").callers(opts)
    end,
    callers = function(opts)
      require("caller.pick").callers(opts)
    end,
  },
})
