-- Lightweight type resolution: work out what a call's receiver actually *is*,
-- so `userService.getProfile()` can be told apart from
-- an unrelated `getProfile()` that merely shares the name.
--
-- This follows the binding, not the type checker: `const x = new Foo()`,
-- `x: Foo`, and imports (default, named, barrel `index.ts`) are chased across
-- files until a class declaration is reached. No tsserver, no project index.
local ts = require("caller.ts")

local M = {}

local file_cache = {}     -- [path] = bindings table
local read_cache = {}     -- [path] = content | false
local tsconfig_cache = {} -- [dir]  = { baseUrl, paths } | false

function M.clear_cache()
  file_cache = {}
  read_cache = {}
  tsconfig_cache = {}
end

local function read(path)
  if read_cache[path] ~= nil then
    return read_cache[path] or nil
  end
  local fd = io.open(path, "r")
  if not fd then
    read_cache[path] = false
    return nil
  end
  local content = fd:read("*a")
  fd:close()
  read_cache[path] = content
  return content
end

--- Strip comments and trailing commas so tsconfig.json (which is JSONC)
--- can go through a strict JSON decoder.
local function strip_jsonc(s)
  local out, i, n = {}, 1, #s
  local in_str, esc = false, false
  while i <= n do
    local c = s:sub(i, i)
    if in_str then
      out[#out + 1] = c
      if esc then
        esc = false
      elseif c == "\\" then
        esc = true
      elseif c == '"' then
        in_str = false
      end
      i = i + 1
    elseif c == '"' then
      in_str = true
      out[#out + 1] = c
      i = i + 1
    elseif c == "/" and s:sub(i + 1, i + 1) == "/" then
      while i <= n and s:sub(i, i) ~= "\n" do
        i = i + 1
      end
    elseif c == "/" and s:sub(i + 1, i + 1) == "*" then
      i = i + 2
      while i <= n and not (s:sub(i, i) == "*" and s:sub(i + 1, i + 1) == "/") do
        i = i + 1
      end
      i = i + 2
    else
      out[#out + 1] = c
      i = i + 1
    end
  end
  return (table.concat(out):gsub(",(%s*[%]}])", "%1"))
end

--- Nearest tsconfig/jsconfig above `path`, reduced to what module
--- resolution needs: an absolute baseUrl and the paths aliases.
function M.tsconfig_for(path)
  local dir = vim.fn.fnamemodify(path, ":h")
  if tsconfig_cache[dir] ~= nil then
    return tsconfig_cache[dir] or nil
  end

  local found = vim.fs.find({ "tsconfig.json", "jsconfig.json" }, { upward = true, path = dir, type = "file" })[1]
  if not found then
    tsconfig_cache[dir] = false
    return nil
  end

  local content = read(found)
  local ok, decoded = pcall(vim.json.decode, strip_jsonc(content or ""))
  if not ok or type(decoded) ~= "table" then
    tsconfig_cache[dir] = false
    return nil
  end

  local co = decoded.compilerOptions or {}
  local cfg_dir = vim.fn.fnamemodify(found, ":h")
  local conf = {
    baseUrl = co.baseUrl and vim.fs.normalize(cfg_dir .. "/" .. co.baseUrl) or nil,
    paths = co.paths,
  }
  if not conf.baseUrl and conf.paths then
    conf.baseUrl = cfg_dir
  end
  tsconfig_cache[dir] = conf
  return conf
end

local function text(node, src)
  return node and vim.treesitter.get_node_text(node, src) or nil
end

local function field1(node, name)
  local got = node and node:field(name)
  return got and got[1] or nil
end

--- `: Foo` / `: Foo<Bar>` / `: Foo | undefined` -> "Foo"
local function type_name(annotation, src)
  if not annotation then
    return nil
  end
  local function dig(n)
    local t = n:type()
    if t == "type_identifier" then
      return text(n, src)
    end
    if t == "generic_type" then
      return dig(field1(n, "name") or n:named_child(0))
    end
    if t == "nested_type_identifier" then
      local last = n:named_child(n:named_child_count() - 1)
      return text(last, src)
    end
    for i = 0, n:named_child_count() - 1 do
      local got = dig(n:named_child(i))
      if got then
        return got
      end
    end
    return nil
  end
  return dig(annotation)
end

--- `new Foo()` -> "Foo";  `new pkg.Foo()` -> "Foo"
local function new_class(value, src)
  if not value or value:type() ~= "new_expression" then
    return nil
  end
  local ctor = field1(value, "constructor")
  if not ctor then
    return nil
  end
  if ctor:type() == "member_expression" then
    return text(field1(ctor, "property"), src)
  end
  return text(ctor, src)
end

M.unwrap = ts.unwrap

--- Collect every binding we can cheaply learn from one file.
---@return table { vars, fields, classes, default_export, exports }
function M.bindings(path)
  if file_cache[path] then
    return file_cache[path]
  end

  local b = {
    vars = {},          -- name -> { class = "Foo" } | { module = "./x", imported = "default"|"name" }
    fields = {},        -- ClassName -> { field -> "Type" }
    classes = {},       -- ClassName -> { extends = "Base" }
    default_export = nil, -- local name, or { class = "Foo" }
    exports = {},       -- exported name -> true
  }
  file_cache[path] = b

  local content = read(path)
  local lang = content and ts.lang_for(path)
  if not lang then
    return b
  end
  local ok, parser = pcall(vim.treesitter.get_string_parser, content, lang)
  if not ok then
    return b
  end
  local ok2, trees = pcall(parser.parse, parser)
  if not ok2 or not trees or not trees[1] then
    return b
  end

  local src = content

  local function record_declarator(node, class_ctx)
    local name = text(field1(node, "name"), src)
    if not name then
      return
    end
    local value = M.unwrap(field1(node, "value"))
    local cls = new_class(value, src) or type_name(field1(node, "type"), src)
    if cls then
      b.vars[name] = { class = cls }
    elseif value and value:type() == "identifier" then
      b.vars[name] = { alias = text(value, src) }
    end
    if class_ctx then
      b.fields[class_ctx] = b.fields[class_ctx] or {}
    end
  end

  local function walk(node, class_ctx)
    local t = node:type()

    if t == "class_declaration" or t == "abstract_class_declaration" or t == "class" then
      local cname = text(field1(node, "name"), src)
      if cname then
        b.classes[cname] = b.classes[cname] or {}
        -- class_heritage -> extends_clause -> identifier | member_expression
        -- (an implements_clause may sit alongside it; ignore that one)
        for i = 0, node:named_child_count() - 1 do
          local ch = node:named_child(i)
          if ch:type() == "class_heritage" then
            for j = 0, ch:named_child_count() - 1 do
              local clause = ch:named_child(j)
              if clause:type() == "extends_clause" then
                local base = clause:named_child(0)
                if base then
                  if base:type() == "member_expression" then
                    b.classes[cname].extends = text(field1(base, "property"), src)
                  else
                    b.classes[cname].extends = type_name(base, src) or text(base, src)
                  end
                end
              end
            end
          end
        end
        class_ctx = cname
      end
    elseif t == "public_field_definition" or t == "field_definition" then
      if class_ctx then
        local fname = text(field1(node, "name"), src)
        local ftype = type_name(field1(node, "type"), src) or new_class(M.unwrap(field1(node, "value")), src)
        if fname and ftype then
          b.fields[class_ctx] = b.fields[class_ctx] or {}
          b.fields[class_ctx][fname] = ftype
        end
      end
    elseif t == "variable_declarator" then
      record_declarator(node, class_ctx)
    elseif t == "import_statement" then
      local source = text(field1(node, "source"), src)
      if source then
        source = source:sub(2, -2) -- strip quotes
        for i = 0, node:named_child_count() - 1 do
          local ch = node:named_child(i)
          if ch:type() == "import_clause" then
            for j = 0, ch:named_child_count() - 1 do
              local c = ch:named_child(j)
              local ct = c:type()
              if ct == "identifier" then
                b.vars[text(c, src)] = { module = source, imported = "default" }
              elseif ct == "named_imports" then
                for k = 0, c:named_child_count() - 1 do
                  local spec = c:named_child(k)
                  if spec:type() == "import_specifier" then
                    local orig = text(field1(spec, "name"), src)
                    local alias = text(field1(spec, "alias"), src) or orig
                    if alias then
                      b.vars[alias] = { module = source, imported = orig }
                    end
                  end
                end
              elseif ct == "namespace_import" then
                local nsname = text(c:named_child(0) or c, src)
                if nsname then
                  b.vars[nsname] = { module = source, imported = "*" }
                end
              end
            end
          end
        end
      end
    elseif t == "export_statement" then
      -- `export default foo;` / `export default new Foo();`
      local value = M.unwrap(field1(node, "value"))
      if value then
        if value:type() == "identifier" then
          b.default_export = text(value, src)
        else
          local cls = new_class(value, src)
          if cls then
            b.default_export = { class = cls }
          end
        end
      end
      -- `export { a, b }`
      for i = 0, node:named_child_count() - 1 do
        local ch = node:named_child(i)
        if ch:type() == "export_clause" then
          for j = 0, ch:named_child_count() - 1 do
            local spec = ch:named_child(j)
            if spec:type() == "export_specifier" then
              local orig = text(field1(spec, "name"), src)
              local alias = text(field1(spec, "alias"), src) or orig
              if alias then
                b.exports[alias] = orig
              end
            end
          end
        end
      end
    end

    for i = 0, node:named_child_count() - 1 do
      walk(node:named_child(i), class_ctx)
    end
  end

  walk(trees[1]:root(), nil)
  return b
end

local EXTS = { ".ts", ".tsx", ".d.ts", ".js", ".jsx", ".mts", ".cts" }

--- base -> base.ts / base.tsx / ... / base/index.ts / ...
local function candidates(base)
  base = base:gsub("%.js$", "") -- ESM-style ./x.js -> ./x
  if vim.fn.filereadable(base) == 1 and base:match("%.[jt]sx?$") then
    return base
  end
  for _, ext in ipairs(EXTS) do
    local p = base .. ext
    if vim.fn.filereadable(p) == 1 then
      return p
    end
  end
  for _, ext in ipairs(EXTS) do
    local p = base .. "/index" .. ext
    if vim.fn.filereadable(p) == 1 then
      return p
    end
  end
  return nil
end

--- Resolve an import specifier to a file on disk.
--- Handles relative paths, plus tsconfig `paths` aliases and `baseUrl`
--- (so `import x from 'components/Foo'` works). Bare specifiers that match
--- nothing are external packages, which we deliberately do not chase.
function M.resolve_module(from_path, spec)
  if not spec or spec == "" then
    return nil
  end

  if spec:match("^%.") then
    local dir = vim.fn.fnamemodify(from_path, ":h")
    return candidates(vim.fs.normalize(dir .. "/" .. spec))
  end

  local tc = M.tsconfig_for(from_path)
  if not tc then
    return nil
  end

  -- tsconfig `paths` aliases, e.g. "@components/*": ["client/components/*"]
  if tc.paths and tc.baseUrl then
    for pattern, targets in pairs(tc.paths) do
      if type(targets) == "table" then
        local prefix = pattern:match("^(.*)%*$")
        local rest
        if prefix then
          rest = spec:match("^" .. vim.pesc(prefix) .. "(.*)$")
        elseif pattern == spec then
          rest = ""
        end
        if rest then
          for _, t in ipairs(targets) do
            local target = prefix and t:gsub("%*", function()
              return rest
            end) or t
            local got = candidates(vim.fs.normalize(tc.baseUrl .. "/" .. target))
            if got then
              return got
            end
          end
        end
      end
    end
  end

  -- plain baseUrl resolution
  if tc.baseUrl then
    return candidates(vim.fs.normalize(tc.baseUrl .. "/" .. spec))
  end
  return nil
end

--- What is `name`, as bound in `path`?
---@return string|nil owner  "class:Foo" or "module:/abs/path"
function M.resolve_binding(path, name, seen)
  seen = seen or {}
  local key = path .. "\0" .. name
  if seen[key] or vim.tbl_count(seen) > 32 then
    return nil
  end
  seen[key] = true

  local b = M.bindings(path)

  -- Declared right here as a class instance.
  local v = b.vars[name]
  if v then
    if v.class then
      return "class:" .. v.class
    end
    if v.alias then
      return M.resolve_binding(path, v.alias, seen)
    end
    if v.module then
      local target = M.resolve_module(path, v.module)
      if not target then
        return nil -- external package
      end
      if v.imported == "*" then
        return "module:" .. target
      end
      local tb = M.bindings(target)
      if v.imported == "default" then
        local d = tb.default_export
        if type(d) == "table" and d.class then
          return "class:" .. d.class
        end
        if type(d) == "string" then
          return M.resolve_binding(target, d, seen) or ("module:" .. target)
        end
        return "module:" .. target
      end
      -- named import; follow a re-export if there is one
      local orig = tb.exports[v.imported] or v.imported
      local got = M.resolve_binding(target, orig, seen)
      return got or ("module:" .. target)
    end
  end

  -- A class declared in this very file.
  if b.classes[name] then
    return "class:" .. name
  end

  return nil
end

--- Owner of a call's receiver.
---@param path string          file containing the call
---@param receiver string|nil  receiver expression, already unwrapped ("this", "this.inner", "svc", nil)
---@param enclosing_class string|nil
---@return string|nil owner
function M.owner_of_receiver(path, receiver, enclosing_class)
  -- Bare call: `getProfile(x)` - it belongs to whatever module supplies it.
  if receiver == nil or receiver == "" then
    return nil
  end

  if receiver == "this" then
    return enclosing_class and ("class:" .. enclosing_class) or nil
  end

  -- `this.field.method()`
  local field = receiver:match("^this%.([%w_$]+)$")
  if field then
    if not enclosing_class then
      return nil
    end
    local b = M.bindings(path)
    local ftype = b.fields[enclosing_class] and b.fields[enclosing_class][field]
    return ftype and ("class:" .. ftype) or nil
  end

  -- A plain identifier receiver.
  if receiver:match("^[%a_$][%w_$]*$") then
    return M.resolve_binding(path, receiver)
  end

  return nil
end

--- Does `owner` satisfy `target`, allowing for subclassing?
function M.owner_matches(owner, target, path)
  if not owner or not target then
    return false
  end
  if owner == target then
    return true
  end
  local ocls = owner:match("^class:(.+)$")
  local tcls = target:match("^class:(.+)$")
  if not ocls or not tcls or not path then
    return false
  end
  -- walk the extends chain of the receiver's class
  local b = M.bindings(path)
  local cur, hops = ocls, 0
  while cur and hops < 8 do
    local info = b.classes[cur]
    if not info or not info.extends then
      return false
    end
    if info.extends == tcls then
      return true
    end
    cur, hops = info.extends, hops + 1
  end
  return false
end

return M
