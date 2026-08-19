-- Asserts that classification is AST-based, not textual.
-- Run: nvim --headless -u NONE -l tests/run.lua
local here = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.rtp:prepend(here)
local ts = require("caller.ts")

local path = here .. "/tests/fixtures/probe.ts"
local content = assert(io.open(path)):read("*a")
local got = {}
for _, o in ipairs(ts.analyse(path, content, "getProfile")) do
  got[o.lnum] = o
end

-- line -> { kind, caller, receiver }  (nil kind = must not be captured at all)
local expect = {
  [1] = { kind = "import" },                                  -- import specifier
  [2] = { kind = "import" },                                  -- type import
  [4] = { kind = nil },                                       -- line comment
  [5] = { kind = nil },                                       -- jsdoc block
  [6] = { kind = nil },                                       -- string literal
  [7] = { kind = nil },                                       -- template string
  [10] = { kind = "type" },                                   -- interface member
  [12] = { kind = "type" },                                   -- method signature
  [15] = { kind = "def" },                                    -- definition
  [16] = { kind = "call", receiver = "this.inner", caller = "getProfile" },
  [20] = { kind = "ref" },                                    -- shorthand property
  [23] = { kind = "call", receiver = "svc", caller = "realCaller" },
  [24] = { kind = "call", receiver = "svc", caller = "realCaller" },   -- ?.
  [25] = { kind = "call", receiver = "svc", caller = "realCaller" },   -- !. unwrapped
  [26] = { kind = "call", caller = "realCaller" },                     -- (x as any).
  [27] = { kind = "ref", caller = "realCaller" },             -- destructured, not called
  [28] = { kind = "call", caller = "realCaller" },            -- bare call
  [29] = { kind = "ref", caller = "realCaller" },             -- assigned, not called
  [30] = { kind = "call", receiver = "svc", caller = "realCaller" },   -- inside callback
  [31] = { kind = "ref", caller = "realCaller" },             -- .bind(), not invoked
  [35] = { kind = "call", receiver = "svc", caller = "arrowCaller" },
  [38] = { kind = "ref" },                                    -- route handler registration
}

local fail, pass = 0, 0
local function check(cond, msg)
  if cond then
    pass = pass + 1
  else
    fail = fail + 1
    print("  FAIL: " .. msg)
  end
end

for lnum, want in pairs(expect) do
  local o = got[lnum]
  if want.kind == nil then
    check(o == nil, ("line %d should not be captured, got %s"):format(lnum, o and o.kind or "nil"))
  else
    check(o ~= nil, ("line %d expected %s, captured nothing"):format(lnum, want.kind))
    if o then
      check(o.kind == want.kind, ("line %d kind: want %s got %s"):format(lnum, want.kind, o.kind))
      if want.caller then
        check(o.caller == want.caller, ("line %d caller: want %s got %s"):format(lnum, want.caller, tostring(o.caller)))
      end
      if want.receiver then
        check(
          o.receiver == want.receiver,
          ("line %d receiver: want %s got %s"):format(lnum, want.receiver, tostring(o.receiver))
        )
      end
    end
  end
end

-- searchable(): derived names that cannot be searched must report nil
local cases = {
  { "plain", "plain" },
  { "razorpayWebhook.handler.paymentCaptured", "paymentCaptured" },
  { '"quoted"', "quoted" },
  { "obj['a-b']", nil },
  { "123", nil },
}
for _, c in ipairs(cases) do
  local got2 = ts.searchable(c[1])
  check(got2 == c[2], ("searchable(%q): want %s got %s"):format(c[1], tostring(c[2]), tostring(got2)))
end

-- ---------------------------------------------------------------- resolver
local resolve = require("caller.resolve")

local fixdir = here .. "/tests/fixtures"
local cpath = fixdir .. "/consumer.ts"
local cocc = {}
for _, o in ipairs(ts.analyse(cpath, assert(io.open(cpath)):read("*a"), "getThing")) do
  o.owner = (o.receiver and o.receiver ~= "") and resolve.owner_of_receiver(cpath, o.receiver, o.caller_class)
    or resolve.resolve_binding(cpath, "getThing")
  cocc[o.lnum] = o
end

local owners = {
  [13] = "class:Alpha",              -- default import -> export default alpha -> new Alpha()
  [14] = "class:Beta",               -- named import -> new Beta()
  [15] = "module:" .. fixdir .. "/free_fn.ts",
  [16] = "class:Alpha",              -- this.a, typed class field
  [17] = "class:Sub",                -- subclass instance
}
for lnum, want in pairs(owners) do
  local o = cocc[lnum]
  check(o ~= nil, ("resolver: line %d not captured"):format(lnum))
  if o then
    check(o.owner == want, ("resolver line %d: want %s got %s"):format(lnum, want, tostring(o.owner)))
  end
end

check(resolve.owner_matches("class:Sub", "class:Beta", cpath), "resolver: Sub should match Beta through extends")
check(not resolve.owner_matches("class:Alpha", "class:Beta", cpath), "resolver: Alpha must not match Beta")

print(("\n%d passed, %d failed"):format(pass, fail))
os.exit(fail == 0 and 0 or 1)
