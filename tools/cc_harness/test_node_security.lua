-- tools/cc_harness/test_node_security.lua
-- Runs the node's REAL packet handler (cut out of node/startup.lua) and the REAL
-- upgrade engine against an in-memory ledger and filesystem. Checks that:
--   * money-moving commands only work with the key that owns the address,
--   * consolidation receipts are sealed, single-use and bound to one target,
--   * heat and the AMIdecode boost actually change the mining payout.
-- Run from the repo root:  lua5.4 tools/cc_harness/test_node_security.lua
dofile("tools/cc_harness/shim.lua")   -- textutils, colors, ...
local function int(n) return math.tointeger(n) or math.floor(n) end
_G.bit32 = { bxor = function(a, b) return (int(a) ~ int(b)) & 0xFFFFFFFF end }
local xtea = dofile("shared/xtea.lua")
-- JSON stand-in (as in test_exchange.lua): tables round-trip through "{#n}" handles.
local jsonStore, jsonN = {}, 0
textutils.serialiseJSON = function(t) jsonN = jsonN + 1; local id = "{#" .. jsonN .. "}"; jsonStore[id] = t; return id end
textutils.unserialiseJSON = function(s) return jsonStore[s] end
local json = textutils

local function check(c, what) assert(c, "FAIL: " .. what); print("  ok  " .. what) end

-- in-memory fs
local function newFs()
  local files = {}
  local fs = {}
  function fs.exists(p) return files[p] ~= nil or p == "/data" end
  function fs.makeDir() end
  function fs.delete(p) files[p] = nil end
  function fs.move(a, b) files[b] = files[a]; files[a] = nil end
  function fs.open(p, mode)
    if mode == "r" then
      if not files[p] then return nil end
      return { readAll = function() return files[p] end, close = function() end }
    end
    if mode == "w" then files[p] = "" end
    files[p] = files[p] or ""
    return {
      write = function(s) files[p] = files[p] .. s end,
      writeLine = function(s) files[p] = files[p] .. s .. "\n" end,
      close = function() end,
    }
  end
  return fs, files
end

----------------------------------------------------------------------
-- Part 1: packet handler
----------------------------------------------------------------------
local src = io.open("node/startup.lua"):read("a")
local a = src:find("-- ── CONSOLIDATE_IN receipt log", 1, true)
local b = src:find("-- ── Self-update", 1, true)
local chunk = src:sub(a, b - 1) .. [[
return { handle = handlePacket, deriveAddress = deriveAddress,
         saveMeshSecret = saveMeshSecret, meshId = meshId }]]

local function newNode(nodeKey)
  local fs = newFs()
  local bal, names, beats, log = {}, {}, {}, {}
  local ledger = {
    getBalance = function(ad) return bal[ad] or 0 end,
    credit = function(ad, n) assert(n > 0 and n == math.floor(n)); bal[ad] = (bal[ad] or 0) + n end,
    drain = function(ad, n)
      local d = math.min(bal[ad] or 0, n)
      if d <= 0 then return 0, "No balance" end
      bal[ad] = bal[ad] - d; return d
    end,
    transfer = function(f, t, n)
      if (bal[f] or 0) < n then return false, "Insufficient funds" end
      bal[f] = bal[f] - n; bal[t] = (bal[t] or 0) + n; return true
    end,
    register = function() return true end,
    registerName = function(n, ad) names[n:lower()] = ad end,
    lookupName = function(n) return names[n:lower()] end,
    getNameByAddress = function() return nil end,
    snapshot = function() return bal end,
  }
  local upgrades = setmetatable({
    getCollisionDelay = function() return 0 end,
    getState = function() return {} end,
    getEffectiveRate = function(r) return r end,
    getActiveTheme = function() return nil end,
  }, { __index = function() return function() return 0 end end })
  local miner = {
    heartbeat = function(ad) beats[ad] = true end,
    getActive = function() return {} end,
    getCurrentRate = function() return 150 end,
    getTotalTicks = function() return 0 end,
    getLagFactor = function() return 1 end,
  }
  local env = setmetatable({
    fs = fs, xtea = xtea, ledger = ledger, upgrades = upgrades, miner = miner,
    MESH_CHANNEL = 1337, NODE_VERSION = "test", nodeFingerprint = "fp",
    print = function(...) log[#log + 1] = table.concat({ ... }, " ") end,
    os = setmetatable({ sleep = function() end }, { __index = os }),
  }, { __index = _G })
  local api = assert(load(chunk, "node", "t", env))()
  local node = { key = nodeKey, bal = bal, beats = beats, log = log, api = api }
  function node.send(senderKey, pkt)
    local reply
    local router = { transmit = function(_, _, msg) reply = msg end }
    api.handle(nodeKey, "pw", router, senderKey,
      xtea.encrypt(json.serialiseJSON(pkt), senderKey), 9000)
    return reply and json.unserialiseJSON(xtea.decrypt(reply, nodeKey))
  end
  return node
end

local A = newNode("aaaaaaaa111111112222222233333333")
local B = newNode("bbbbbbbb111111112222222233333333")
local C = newNode("cccccccc111111112222222233333333")   -- someone else's node
local ALICE = "0123456789abcdef0123456789abcdef"
local MAL   = "fedcba9876543210fedcba9876543210"
local alice, mal = A.api.deriveAddress(ALICE), A.api.deriveAddress(MAL)
A.bal[alice] = 1000000

print("ownership")
local r = A.send(ALICE, { cmd = "TRANSFER", from = alice, to = mal, amount = 100 })
check(r.ok and A.bal[alice] == 999900 and A.bal[mal] == 100, "owner can transfer")
r = A.send(MAL, { cmd = "TRANSFER", from = alice, to = mal, amount = 500000 })
check(not r.ok and A.bal[alice] == 999900, "another key cannot spend from that address")
r = A.send(MAL, { cmd = "REGISTER", from = alice, name = "Alice" })
check(not r.ok, "another key cannot register a name for that address")
A.send(MAL, { cmd = "HEARTBEAT", from = alice })
check(not A.beats[alice], "another key's heartbeat is ignored")
A.send(ALICE, { cmd = "HEARTBEAT", from = alice })
check(A.beats[alice], "owner's heartbeat counts")
r = A.send(MAL, { cmd = "BALANCE", from = alice })
check(r.ok and r.balance == 999900, "read-only BALANCE of another address still works")
r = A.send(MAL, { cmd = "CONSOLIDATE_IN", from = alice, amount = 5, receipt = "x" })
check(not r.ok, "another key cannot consolidate into that address")

print("consolidation off by default")
r = A.send(ALICE, { cmd = "CONSOLIDATE_OUT", from = alice, amount = 1000, target = "bbbbbbbb" })
check(not r.ok and A.bal[alice] == 999900, "no secret: drain refused, nothing taken")
r = A.send(ALICE, { cmd = "STATS", from = alice })
check(r.consolidate_id == nil, "STATS shows consolidation off")

local SECRET = "00112233445566778899aabbccddeeff"
A.api.saveMeshSecret(SECRET); B.api.saveMeshSecret(SECRET)
C.api.saveMeshSecret("ffeeddccbbaa99887766554433221100")
local idA = A.send(ALICE, { cmd = "STATS", from = alice }).consolidate_id
local idB = B.send(ALICE, { cmd = "STATS", from = alice }).consolidate_id
local idC = C.send(ALICE, { cmd = "STATS", from = alice }).consolidate_id
check(idA and idA == idB and idA ~= idC and not idA:find(SECRET, 1, true),
  "linked nodes share a link ID that does not reveal the secret")

print("consolidation")
r = A.send(ALICE, { cmd = "CONSOLIDATE_OUT", from = alice, amount = 1000 })
check(not r.ok and A.bal[alice] == 999900, "old wallet without target: refused before draining")
r = A.send(ALICE, { cmd = "CONSOLIDATE_OUT", from = alice, amount = 1000, target = "aaaaaaaa" })
check(not r.ok and A.bal[alice] == 999900, "cannot target the source node itself")
r = A.send(ALICE, { cmd = "CONSOLIDATE_OUT", from = alice, amount = 250000, target = "bbbbbbbb" })
check(r.ok and r.amount == 250000 and A.bal[alice] == 749900, "drain on A")
local receipt = r.receipt
r = B.send(ALICE, { cmd = "CONSOLIDATE_IN", from = alice, amount = 99999999, receipt = receipt })
check(r.ok and B.bal[alice] == 250000, "B credits the receipt amount, not the claimed amount")
r = B.send(ALICE, { cmd = "CONSOLIDATE_IN", from = alice, amount = 250000, receipt = receipt })
check(not r.ok and B.bal[alice] == 250000, "receipt cannot be redeemed twice")
r = A.send(ALICE, { cmd = "CONSOLIDATE_IN", from = alice, amount = 250000, receipt = receipt })
check(not r.ok and A.bal[alice] == 749900, "receipt cannot be redeemed on another node")
local forged = receipt:gsub(":250000:", ":9250000:")
r = B.send(ALICE, { cmd = "CONSOLIDATE_IN", from = alice, amount = 9250000, receipt = forged })
check(not r.ok and B.bal[alice] == 250000, "edited amount fails the signature")
B.bal[mal] = 0
r = B.send(MAL, { cmd = "CONSOLIDATE_IN", from = mal, amount = 250000, receipt = receipt })
check(not r.ok and B.bal[mal] == 0, "another wallet cannot use someone else's receipt")
r = B.send(ALICE, { cmd = "CONSOLIDATE_IN", from = alice, amount = 5000000, receipt = "made-up" })
check(not r.ok, "invented receipt rejected")
C.bal[mal] = 5000000
r = C.send(MAL, { cmd = "CONSOLIDATE_OUT", from = mal, amount = 5000000, target = "bbbbbbbb" })
r = B.send(MAL, { cmd = "CONSOLIDATE_IN", from = mal, amount = 5000000, receipt = r.receipt })
check(not r.ok and B.bal[mal] == 0, "receipt from an unlinked node rejected")

----------------------------------------------------------------------
-- Part 2: payout multiplier (real node/upgrades.lua)
----------------------------------------------------------------------
print("payout")
local now = 1000000
local function loadUpgrades(levels, amd)
  local fs, files = newFs()
  files["/data/upgrades.json"] = json.serialiseJSON({ levels = levels })
  if amd then files["/data/amidecode.json"] = json.serialiseJSON(amd) end
  local env = setmetatable({
    fs = fs, require = function(m) return m == "xtea" and xtea or {} end,
    print = function() end,
    os = setmetatable({ epoch = function() return now * 1000 end,
                        getComputerID = function() return 1 end }, { __index = os }),
  }, { __index = _G })
  return assert(loadfile("node/upgrades.lua", "t", env))()
end
local up = loadUpgrades({ miner_boost = 4, air_cooler = 1, liquid_cooling = 1 })
check(up.getEffectiveRate(150) == 209, "OC4 at 114C, LiquidCool 1: 150 -> 209 (22.5% heat penalty)")
up = loadUpgrades({ miner_boost = 4, air_cooler = 2 })
check(up.getEffectiveRate(150) == 270, "OC4 with AirCooler 2 (86C): full 270")
up = loadUpgrades({ miner_boost = 10 })
check(up.getEffectiveRate(150) == 0 and up.getPayoutMultiplier() == 0, "OC10 with no cooling (310C): mining halted")
up = loadUpgrades({ miner_boost = 4, air_cooler = 2, amidecode = 1 },
  { boost_mult = 1.5, boost_end = now + 600, cooldown_end = 0 })
check(up.getEffectiveRate(150) == 405, "active AMIdecode x1.5 boost applies: 270 -> 405")
up = loadUpgrades({ miner_boost = 4, air_cooler = 2, amidecode = 1 },
  { boost_mult = 1.5, boost_end = now - 1, cooldown_end = 0 })
check(up.getEffectiveRate(150) == 270, "expired AMIdecode boost no longer applies")
print("PASS")
