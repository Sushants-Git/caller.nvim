local M = {}

---@class caller.Config
M.defaults = {
  -- Which engine finds the call sites:
  --   "auto"  use the language server when one is attached and capable,
  --           otherwise fall back to ripgrep + treesitter
  --   "lsp"   language server only (most correct, any language, needs a server)
  --   "grep"  ripgrep + treesitter only (instant, no server, TS/JS)
  engine = "auto",

  -- How long to wait on a single LSP request, in ms.
  lsp_timeout = 10000,

  -- Root to search. A function, or a string path.
  -- Default: git root of the current file, falling back to cwd.
  root = nil,

  -- File globs handed to ripgrep.
  globs = { "*.ts", "*.tsx", "*.js", "*.jsx", "*.mts", "*.cts" },

  -- Directories never scanned.
  exclude = { "node_modules", "dist", "build", ".next", "coverage", "__generated__", ".git" },

  -- Max ripgrep hits to analyse for a single symbol.
  max_hits = 2000,

  -- How deep `expand all` (E) walks the caller tree.
  max_auto_depth = 3,

  window = {
    width = 0.85,
    height = 0.8,
    border = "rounded",
    title = " caller ",
  },

  keys = {
    expand = { "<CR>", "<Tab>" },   -- toggle: who calls this caller?
    jump = { "o", "gd" },           -- jump to the call site
    split = "<C-x>",
    vsplit = "<C-v>",
    tab = "<C-t>",
    expand_all = "E",
    collapse_all = "W",
    refresh = "R",
    toggle_refs = "f",              -- show/hide non-call references
    toggle_filter = "t",            -- show/hide same-name calls on other types
    close = { "q", "<Esc>" },
    help = "?",
  },

  -- Resolve each call site's receiver to a type, and hide call sites that
  -- reach a different function of the same name. Toggle in the window with `t`.
  filter_by_type = true,

  -- Show identifier references that are not direct calls
  -- (e.g. `router.get('/x', getProfile)` — handler registration).
  show_refs = true,
}

M.options = vim.deepcopy(M.defaults)

function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
  return M.options
end

return M
