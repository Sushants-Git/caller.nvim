# caller.nvim

**Who calls this function?** — answered in ~100ms, without a language server.

Put your cursor on a function and get every call site, each attributed to the **function that
contains it**. Then expand any caller to see who calls *it*, and keep walking up until you
reach the route handler, cron job, or CLI entry point that actually sets the whole thing off.

Built on ripgrep + treesitter. No LSP, no tsserver, no index to build, nothing to warm up.

```
callers of getProfile  [UserService]
──────────────────────────────────────────────────────────────────────────────
▾ updateProfile          UserService    via this        services/user.ts:88
▾ getProfileHandler                     via userService controllers/user.ts:42
  ▾ registerRoutes                      via router      routers/user.ts:17
    · ref ‹module scope›                                app.ts:31
```

## Why not just use the LSP?

You often should — see [Alternatives](#alternatives). This exists for the case where you
want the answer *now*:

|  | caller.nvim | LSP call hierarchy |
| --- | --- | --- |
| Cold start | ~100ms | seconds to minutes on a large repo |
| Needs a server | no | yes, warmed up |
| Depth | expandable chain | one level per request |
| Shows the receiver | yes (`via this` vs `via userService`) | no |
| Non-call references | yes (`router.get('/x', handler)`) | no |
| Correctness | resolves bindings, not types | ground truth |

On a 300-file TypeScript API, `tsserver` took ~12s to attach before it could answer at all.
caller.nvim answered the same question in 130ms with identical results.

## Install

<details open>
<summary><b>lazy.nvim</b></summary>

```lua
{
  "Sushants-Git/caller.nvim",
  dependencies = { "nvim-telescope/telescope.nvim" }, -- optional
  cmd = { "Caller", "CallerPick", "CallerQf", "CallerAll", "CallerQfAll" },
  keys = {
    { "<leader>cr", "<cmd>CallerPick<cr>", desc = "Callers (picker)" },
    { "<leader>ct", "<cmd>Caller<cr>",     desc = "Callers (tree)" },
  },
  opts = {},
}
```
</details>

<details>
<summary><b>packer / vim-plug</b></summary>

```lua
use { "Sushants-Git/caller.nvim", config = function() require("caller").setup() end }
```
```vim
Plug 'Sushants-Git/caller.nvim'
" then: lua require('caller').setup()
```
</details>

**Requires** [ripgrep](https://github.com/BurntSushi/ripgrep) and treesitter parsers for the
languages you search:

```vim
:TSInstall typescript tsx javascript
:checkhealth caller
```

Telescope is optional — without it you get the tree view and quickfix output.

## Usage

| Command | |
| --- | --- |
| `:CallerPick` | Telescope picker with a live preview |
| `:Caller` | Tree view — the whole chain at once |
| `:Caller <name>` | Same, for a named symbol |
| `:CallerQf` | Send call sites to the quickfix list |
| `:CallerAll` / `:CallerQfAll` | Skip type resolution, show every same-named call |
| `:Telescope caller` | Same as `:CallerPick` |

Add `!` to any of them to bypass the cache and rescan.

### In the picker

| Key | |
| --- | --- |
| `<CR>` | Jump to the call site |
| `<C-l>` | Drill up — callers of the selected caller |
| `<C-h>` | Back down a level |
| `<C-f>` | Toggle type filtering |
| `<C-y>` | Toggle non-call references |
| `<C-o>` | Switch to the tree view |

### In the tree

| Key | |
| --- | --- |
| `<CR>` / `<Tab>` | Expand/collapse — who calls this caller |
| `o` / `gd` | Jump to the call site |
| `<C-v>` `<C-x>` `<C-t>` | Open in vsplit / split / tab |
| `E` / `W` | Expand all (3 levels) / collapse all |
| `t` / `f` | Toggle type filtering / non-call references |
| `R` | Rescan |
| `?` | Help |
| `q` / `<Esc>` | Close |

## Reading a row

```
▸ updateProfile   UserService   via this   services/user.ts:88   const p = await this.getProfile(id)
  └ caller        └ its class   └ how the  └ location            └ the call site
                                  callee was
                                  reached
```

- **`via this`** vs **`via userService`** distinguishes an internal call from an external one.
- **`ref`** rows are places the identifier is passed but not invoked — most usefully
  `router.get('/x', getProfile)`, i.e. where a handler is wired to a route.
- **`‹module scope›`** means a top-level call, so there is nothing above it.
- **`›callback`** means the call sits in an anonymous callback; the name shown is the nearest
  named function around it.

## Accuracy

Classification runs on the treesitter AST, not on text. An occurrence counts as a call only
if the identifier is the callee of a `call_expression`:

| Source | Classified |
| --- | --- |
| `svc.getProfile(x)` | **call** |
| `svc?.getProfile(x)` / `svc!.getProfile(x)` | **call** |
| `(svc as any).getProfile(x)` | **call** |
| `arr.map(x => svc.getProfile(x))` | **call**, attributed to the enclosing named fn |
| `const fn = svc.getProfile` | ref — assigned, never invoked |
| `svc.getProfile.bind(svc)` | ref — the call here is `.bind` |
| `router.get('/x', getProfile)` | ref — handler registration |
| `import { getProfile } from ...` | import — excluded |
| `interface S { getProfile(): void }` | type — excluded |
| `// getProfile(x)` in a comment | not captured |
| `"getProfile(x)"` in a string | not captured |

```sh
nvim --headless -u NONE -l tests/run.lua    # 74 assertions
```

## Telling same-named functions apart

Two functions often share a name — a `getProfile` **service method** and a `getProfile`
**controller** that calls it. Name matching alone jumbles their call sites together.

So each receiver is resolved to a concrete type by **following the binding across files**:

```
controllers/user.ts:  userService.getProfile(id)
                        │  import userService from '../services/user'
                        ▼  export default userService
                        ▼  export const userService = new UserService()
                      class:UserService          ← matches the target, keep it
```

Followed: `new Foo()`, `x: Foo` annotations, typed class fields (for `this.x.m()`), `this`,
default/named/aliased imports, re-exports, namespace imports, and `index.ts` barrels.
Subclasses match a base-class target through `extends`. Bare calls resolve to the module that
supplies the binding.

The result: cursor on the **service method** gives its real callers with the controller's
route registration filtered out; cursor on the **controller** gives just that registration.
The header names which one was resolved, and `t` (or `<C-f>`) toggles the filter off.

When the cursor gives no hint — `:Caller <name>` typed from an unrelated buffer — and several
definitions share the name, it reports `ambiguous` and shows everything rather than guessing.

Receivers it cannot resolve are marked `unresolved` and **always shown**. It never silently
drops a call site it did not understand.

## Limits

This follows bindings, not types. No control-flow analysis, no generic instantiation, no
interface-implementation matching — a receiver typed only as an interface, or produced by a
factory, comes back `unresolved` rather than wrong. For a rename that must be complete,
`vim.lsp.buf.references()` on a warm server is still the ground truth.

`E` (expand 3 levels) runs a scan per node and takes about a second on a 300-file repo.

Language support is whatever treesitter parses plus the resolver's grammar knowledge, which is
written against **TypeScript and JavaScript**. Other languages will find call sites but the
type filtering will mostly report `unresolved`.

## Config

Defaults shown:

```lua
require("caller").setup({
  root = nil,             -- string | function(path) -> string; default: git root, else cwd
  globs = { "*.ts", "*.tsx", "*.js", "*.jsx", "*.mts", "*.cts" },
  exclude = { "node_modules", "dist", "build", ".next", "coverage", "__generated__", ".git" },
  max_hits = 2000,
  max_auto_depth = 3,     -- how far `E` walks
  filter_by_type = true,  -- hide same-name calls that reach a different function
  show_refs = true,       -- show non-call references
  window = { width = 0.85, height = 0.8, border = "rounded", title = " caller " },
  keys = { ... },         -- see lua/caller/config.lua
})
```

Highlight groups: `CallerHeader` `CallerSymbol` `CallerCount` `CallerFile` `CallerChevron`
`CallerName` `CallerClass` `CallerRecv` `CallerLoc` `CallerSnippet` `CallerNote` `CallerRef`
`CallerHint` — all linked to sensible defaults, override freely.

## Alternatives

The idea is not new; these are all LSP-backed, which is the main difference:

- [litee-calltree.nvim](https://github.com/ldelossa/litee-calltree.nvim) — explorable
  incoming/outgoing call tree, part of the litee framework.
- [telescope-hierarchy.nvim](https://github.com/jmacadie/telescope-hierarchy.nvim) — Telescope
  UI over the LSP call hierarchy, with direction toggling.
- [calltree.nvim](https://github.com/marcomayer/calltree.nvim) — hooks the LSP call-hierarchy
  handlers directly.
- [hierarchy.nvim](https://github.com/Slyces/hierarchy.nvim) — combines LSP references with
  treesitter for context.
- Built in: `vim.lsp.buf.incoming_calls()` / `outgoing_calls()`.

Use those if your language server is fast and you want guaranteed-correct results. Use this
one when you want an answer immediately, on a repo where the server takes a while, or in a
language where call hierarchy isn't implemented.

## Layout

```
lua/caller/config.lua    defaults
lua/caller/ts.lua        treesitter: is this a call, and who encloses it
lua/caller/resolve.lua   follow bindings/imports to type a call's receiver
lua/caller/scan.lua      ripgrep -> file list -> analysis, with caching
lua/caller/tree.lua      the caller tree and its recursive expansion
lua/caller/ui.lua        tree window: rendering and keymaps
lua/caller/pick.lua      telescope picker, chain as a picker stack
lua/caller/health.lua    :checkhealth caller
tests/run.lua            classification + resolver assertions
```

## License

MIT
