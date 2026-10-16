-- tools/cc_harness/test_node_admin.lua
-- Runs the node's REAL adminMenu code (cut out of node/startup.lua) against a stub
-- ledger. Checks the password gate and that the menu can no longer create AMI or
-- move it between wallets. Run: lua5.4 tools/cc_harness/test_node_admin.lua
local src = io.open("node/startup.lua"):read("a")
local a = src:find("local ADMIN_LOG = ", 1, true)
local b = src:find("-- ── Main ──", 1, true)
local chunk = src:sub(a, b - 1) .. "\nreturn adminMenu"
local EX = ("e"):rep(128)
local OTHER = ("a"):rep(128)
local bal, names, logLines, out, input = { [EX] = 5, [OTHER] = 7 }, { ["the great ami exchange"] = EX }, {}, {}, {}
local env = setmetatable({
  ledger = {
    lookupName = function(n) return names[n:lower()] end,
    getNameByAddress = function(ad) for n, x in pairs(names) do if x == ad then return n end end end,
    getBalance = function(ad) return bal[ad] or 0 end,
    credit = function(ad, amt) bal[ad] = (bal[ad] or 0) + amt end,
    transfer = function(f, t, n) bal[f] = bal[f] - n; bal[t] = (bal[t] or 0) + n; return true end,
    snapshot = function() return bal end,
    register = function() return true end,
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
local PW = "booboohappend"
local function run(lines) input = lines; out = {}; adminMenu(); return table.concat(out, "\n") end
local function check(c, what) assert(c, "FAIL: " .. what); print("  ok  " .. what) end

local o = run({ "wrong" })
check(o:find("Wrong password") and not o:find("Balance inquiry"), "wrong password cannot reach the menu")
o = run({ "pw", "b" })
check(o:find("Wrong password"), "node setup password cannot reach the menu")
o = run({ PW, "1", "The Great Ami Exchange", "", "b" })
check(o:find("Balance: 5 uAMI", 1, true), "master password opens the menu; balance inquiry works")
check(not o:find("Mint") and not o:find("Force transfer") and not o:find("Consolidation"),
  "menu no longer lists mint, force transfer or consolidation link")
local before = bal[EX] + bal[OTHER]
for _, script in ipairs({
  { PW, "2", OTHER, EX, "m", "YES", "", "b" },
  { PW, "6", "The Great Ami Exchange", "100", "YES", "", "b" },
  { PW, "7", "G", "", "b" },
}) do
  run(script)
end
check(bal[EX] == 5 and bal[OTHER] == 7 and bal[EX] + bal[OTHER] == before,
  "old option keys 2, 6 and 7 change no balances")
print("PASS")
