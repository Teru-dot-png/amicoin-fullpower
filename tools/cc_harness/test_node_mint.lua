-- tools/cc_harness/test_node_mint.lua
-- Runs the node's REAL adminMenu code (cut out of node/startup.lua) against a stub
-- ledger and checks the [6] Mint option. Run: lua5.4 tools/cc_harness/test_node_mint.lua
local src = io.open("node/startup.lua"):read("a")
local a = src:find("local ADMIN_LOG = ", 1, true)
local b = src:find("-- ── Main ──", 1, true)
local chunk = src:sub(a, b - 1) .. "\nreturn adminMenu"
local EX = ("e"):rep(128)
local bal, names, logLines, out, input = { [EX] = 5 }, { ["the great ami exchange"] = EX }, {}, {}, {}
local env = setmetatable({
  ledger = {
    lookupName = function(n) return names[n:lower()] end,
    getNameByAddress = function(ad) for n, x in pairs(names) do if x == ad then return n end end end,
    getBalance = function(ad) return bal[ad] or 0 end,
    credit = function(ad, amt) assert(amt > 0 and amt == math.floor(amt)); bal[ad] = (bal[ad] or 0) + amt end,
  },
  fs = { exists = function() return true end, makeDir = function() end,
         open = function() return { write = function(s) logLines[#logLines + 1] = s end, close = function() end } end },
  term = setmetatable({}, { __index = function() return function() end end }),
  colors = setmetatable({}, { __index = function() return 0 end }),
  os = setmetatable({ sleep = function() end, epoch = function() return 1 end }, { __index = os }),
  print = function(...) out[#out + 1] = table.concat({ ... }, " ") end,
  io = { write = function(s) out[#out + 1] = s end },
  read = function() return table.remove(input, 1) or "b" end,
}, { __index = _G })
local adminMenu = assert(load(chunk, "adminMenu", "t", env))()
local function run(lines) input = lines; out = {}; adminMenu("pw"); return table.concat(out, "\n") end
local function check(c, what) assert(c, "FAIL: " .. what); print("  ok  " .. what) end

local o = run({ "wrong" })
check(bal[EX] == 5 and o:find("Wrong password"), "wrong password cannot reach the menu")
o = run({ "pw", "6", "The Great Ami Exchange", "2.5", "YES", "", "b" })
check(bal[EX] == 2500005, "minting 2.5 AMI by name credits 2500000 uAMI")
check(o:find("Minted. New balance: 2500005 uAMI", 1, true), "new balance is shown")
check(#logLines == 1 and logLines[1]:find("MINT to=eeeeeeeeeeeeeeee name=the great ami exchange amount=2500000", 1, true), "mint is written to the admin log")
run({ "pw", "6", "The Great Ami Exchange", "1", "yes", "", "b" })
check(bal[EX] == 2500005, "anything but an exact YES mints nothing")
for _, bad in ipairs({ "0", "-5", "abc", "", "nan", "inf", "1e400" }) do
  run({ "pw", "6", "The Great Ami Exchange", bad, "YES", "", "b" })
  check(bal[EX] == 2500005, "amount '" .. bad .. "' mints nothing")
end
o = run({ "pw", "6", "Nobody", "b" })
check(bal[EX] == 2500005 and o:find("not found"), "unknown name mints nothing")
run({ "pw", "6", EX, "0.000001", "YES", "", "b" })
check(bal[EX] == 2500006, "minting by 128-hex address works (1 uAMI)")
check(#logLines == 2, "only real mints are logged")
print("PASS")
