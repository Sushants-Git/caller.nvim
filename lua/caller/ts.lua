-- Treesitter analysis: given a byte position in a source file, work out
--   (a) whether the identifier there is actually a *call*, and
--   (b) which function/method encloses it (i.e. who the caller is).
local M = {}

local LANG_BY_EXT = {
  ts = "typescript",
  mts = "typescript",
  cts = "typescript",
  tsx = "tsx",
  js = "javascript",
  mjs = "javascript",
  cjs = "javascript",
  jsx = "javascript",
}

function M.lang_for(path)
  local ext = path:match("%.([%w]+)$")
  return ext and LANG_BY_EXT[ext:lower()] or nil
end

--- Strip `!`, parens and `as X` down to the underlying expression node.
function M.unwrap(node)
  while node do
    local t = node:type()
    if
      t == "non_null_expression"
      or t == "parenthesized_expression"
      or t == "as_expression"
      or t == "satisfies_expression"
    then
      node = node:named_child(0)
    else
      return node
    end
  end
  return nil
end

-- Function-ish nodes we treat as a possible "caller".
local FUNC_NODES = {
  function_declaration = true,
  function_expression = true,
  generator_function = true,
  generator_function_declaration = true,
  arrow_function = true,
  method_definition = true,
}

local CLASS_NODES = {
  class_declaration = true,
  class = true,
  abstract_class_declaration = true,
}

local function text(node, src)
  if not node then
    return nil
  end
  return vim.treesitter.get_node_text(node, src)
end

local function field1(node, name)
  local got = node:field(name)
  return got and got[1] or nil
end

-- Name of a function node, or nil when it is genuinely anonymous.
local function func_name(node, src)
  local t = node:type()

  if t == "function_declaration" or t == "generator_function_declaration" or t == "method_definition" then
    return text(field1(node, "name"), src)
  end

  -- arrow_function / function_expression: the name lives on the parent binding.
  local named = field1(node, "name")
  if named then
    return text(named, src)
  end

  local p = node:parent()
  while p do
    local pt = p:type()
    if pt == "variable_declarator" then
      return text(field1(p, "name"), src)
    elseif pt == "pair" then
      return text(field1(p, "key"), src)
    elseif pt == "public_field_definition" or pt == "field_definition" or pt == "property_signature" then
      return text(field1(p, "name"), src)
    elseif pt == "assignment_expression" then
      return text(field1(p, "left"), src)
    elseif pt == "call_expression" or pt == "arguments" or pt == "return_statement" then
      -- inline callback with no binding of its own
      return nil
    elseif pt == "parenthesized_expression" or pt == "as_expression" or pt == "satisfies_expression" then
      p = p:parent()
    else
      return nil
    end
  end
  return nil
end

-- Enclosing class name for a node, if any.
local function class_of(node, src)
  local p = node:parent()
  while p do
    if CLASS_NODES[p:type()] then
      local n = field1(p, "name")
      if n then
        return text(n, src)
      end
      -- `const x = class { ... }`
      local gp = p:parent()
      if gp and gp:type() == "variable_declarator" then
        return text(field1(gp, "name"), src)
      end
      return nil
    end
    p = p:parent()
  end
  return nil
end

--- Find the enclosing named function of `node`.
--- Walks up through anonymous callbacks; reports that it did so.
---@return table|nil { name, kind, class, via_callback, srow, scol }
function M.enclosing(node, src)
  local cur = node:parent()
  local via_callback = false

  while cur do
    if FUNC_NODES[cur:type()] then
      local name = func_name(cur, src)
      if name then
        local srow, scol = cur:start()
        return {
          name = name,
          kind = cur:type(),
          class = class_of(cur, src),
          via_callback = via_callback,
          srow = srow,
          scol = scol,
        }
      end
      -- anonymous: keep climbing, but remember we passed through a callback
      via_callback = true
    end
    cur = cur:parent()
  end
  return nil -- top level / module scope
end

--- A derived caller name is not always something we can search for: an
--- assignment like `razorpayWebhook.handler.paymentCaptured = async () => {}`
--- yields a dotted name, and object keys can be quoted. Reduce to the final
--- identifier segment, or nil when there is nothing searchable.
function M.searchable(name)
  if not name then
    return nil
  end
  local n = name:gsub("^[\"']", ""):gsub("[\"']$", "")
  n = n:match("([%w_$]+)$")
  if n and n:match("^[%a_$][%w_$]*$") then
    return n
  end
  return nil
end

-- Type-only positions: interface members, method signatures. Never calls.
local TYPE_PARENTS = {
  property_signature = true,
  method_signature = true,
  index_signature = true,
  construct_signature = true,
}

-- Skip identifiers that are part of import/export plumbing.
local SKIP_PARENTS = {
  import_specifier = true,
  export_specifier = true,
  namespace_import = true,
  import_clause = true,
}

--- Classify what an identifier occurrence *is*.
---@return string kind  "call" | "def" | "import" | "ref"
---@return string|nil receiver  e.g. "this", "userService"
function M.classify(node, src)
  local p = node:parent()
  if not p then
    return "ref", nil
  end
  local pt = p:type()

  if SKIP_PARENTS[pt] then
    return "import", nil
  end

  if TYPE_PARENTS[pt] then
    return "type", nil
  end

  -- Definition sites.
  if pt == "method_definition" or pt == "function_declaration" or pt == "generator_function_declaration" then
    if field1(p, "name") == node then
      return "def", nil
    end
  end
  if pt == "variable_declarator" and field1(p, "name") == node then
    local v = field1(p, "value")
    if v and FUNC_NODES[v:type()] then
      return "def", nil
    end
  end
  if pt == "public_field_definition" or pt == "field_definition" then
    if field1(p, "name") == node then
      return "def", nil
    end
  end

  -- Direct call: foo()
  if pt == "call_expression" and field1(p, "function") == node then
    return "call", nil
  end

  -- The closing half of <Foo>...</Foo> is syntax, not a second call site.
  if pt == "jsx_closing_element" then
    return "syntax", nil
  end

  -- JSX: <Foo /> and <Foo>...</Foo> invoke the component, so they are calls.
  if pt == "jsx_self_closing_element" or pt == "jsx_opening_element" then
    if field1(p, "name") == node or p:named_child(0) == node then
      return "call", nil
    end
  end

  -- Method call: obj.foo() / this.foo() / obj?.foo()
  if pt == "member_expression" and field1(p, "property") == node then
    local gp = p:parent()
    -- unwrap non_null_expression (`obj.foo!()`) and parens
    while gp and (gp:type() == "non_null_expression" or gp:type() == "parenthesized_expression") do
      p, gp = gp, gp:parent()
    end
    if gp and gp:type() == "call_expression" and field1(gp, "function") == p then
      local obj = M.unwrap(field1(p, "object"))
      return "call", obj and text(obj, src) or nil
    end
    -- <Foo.Bar /> is likewise a call on Foo
    if gp and (gp:type() == "jsx_self_closing_element" or gp:type() == "jsx_opening_element") then
      local obj = M.unwrap(field1(p, "object"))
      return "call", obj and text(obj, src) or nil
    end
    return "ref", nil
  end

  return "ref", nil
end

--- Analyse one file for occurrences of `symbol`.
---@param path string
---@param content string
---@param symbol string
---@return table[] occurrences
function M.analyse(path, content, symbol)
  local lang = M.lang_for(path)
  if not lang then
    return {}
  end

  local ok, parser = pcall(vim.treesitter.get_string_parser, content, lang)
  if not ok or not parser then
    return {}
  end
  local ok2, trees = pcall(parser.parse, parser)
  if not ok2 or not trees or not trees[1] then
    return {}
  end
  local root = trees[1]:root()

  local esc = symbol:gsub("\\", "\\\\"):gsub('"', '\\"')
  local function build(node_types)
    local parts = {}
    for _, nt in ipairs(node_types) do
      table.insert(parts, string.format('((%s) @id (#eq? @id "%s"))', nt, esc))
    end
    return table.concat(parts, " ")
  end

  local query
  for _, set in ipairs({
    { "identifier", "property_identifier", "shorthand_property_identifier", "shorthand_property_identifier_pattern" },
    { "identifier", "property_identifier" },
  }) do
    local ok3, q = pcall(vim.treesitter.query.parse, lang, build(set))
    if ok3 then
      query = q
      break
    end
  end
  if not query then
    return {}
  end

  local lines = vim.split(content, "\n", { plain = true })
  local out = {}

  for _, node in query:iter_captures(root, content, 0, -1) do
    local srow, scol = node:start()
    local kind, receiver = M.classify(node, content)
    local encl = M.enclosing(node, content)
    table.insert(out, {
      path = path,
      lnum = srow + 1,
      col = scol + 1,
      kind = kind,
      receiver = receiver,
      caller = encl and encl.name or nil,
      caller_search = encl and M.searchable(encl.name) or nil,
      caller_class = encl and encl.class or nil,
      caller_kind = encl and encl.kind or nil,
      caller_lnum = encl and (encl.srow + 1) or nil,
      via_callback = encl and encl.via_callback or false,
      line = vim.trim(lines[srow + 1] or ""),
    })
  end

  return out
end

return M
