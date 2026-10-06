-- tools/cc_harness/test_wallet_send_invoice.lua
-- Boots the REAL wallet/main.lua on a pocket-sized (26x20) screen with stubbed
-- comms/secret_manager/session and drives the Send and Invoice pages end to end.
--
-- Unlike the other harness scripts this one runs a faithful CC event scheduler
-- (os.pullEvent yields, parallel broadcasts every event to every coroutine,
-- timers fire on a virtual clock) because the bugs it guards against are
-- interleaving ones: the 5s balance loop painting the dashboard over the Send
-- form, and invoices arriving while another screen has the keyboard.
--
-- Run from the repo root:
--   CC_W=26 CC_H=20 lua5.4 tools/cc_harness/test_wallet_send_invoice.lua
local shim = dofile("tools/cc_harness/shim.lua")
assert(shim.W == 26 and shim.H == 20, "run with CC_W=26 CC_H=20")
local VERBOSE = os.getenv("VERBOSE")

----------------------------------------------------------------------
-- keys with real names (the shim's default table maps every key to 0)
----------------------------------------------------------------------
local keys, keyNames = {}, {}
local function defkey(name, code) keys[name] = code; keyNames[code] = name end
for c = 65, 90 do defkey(string.char(c + 32), c) end
for i, n in ipairs({ "zero","one","two","three","four","five","six","seven","eight","nine" }) do
  defkey(n, 47 + i)
end
defkey("enter", 257); defkey("tab", 258); defkey("backspace", 259)
defkey("right", 262); defkey("left", 263); defkey("down", 264); defkey("up", 265)
defkey("leftShift", 340); defkey("leftCtrl", 341); defkey("leftAlt", 342)
defkey("rightShift", 344); defkey("rightCtrl", 345); defkey("rightAlt", 346)
keys.getName = function(c) return keyNames[c] end
_G.keys = keys

----------------------------------------------------------------------
-- virtual clock, timers, event queue (real CC semantics: pullEvent yields)
----------------------------------------------------------------------
local nowMs, nextTimer, timers, queue = 0, 0, {}, {}
os.clock = function() return nowMs / 1000 end
os.epoch = function() return nowMs end
os.startTimer = function(t)
  nextTimer = nextTimer + 1
  timers[nextTimer] = nowMs + math.max(t or 0, 0.05) * 1000
  return nextTimer
end
os.cancelTimer = function(id) timers[id] = nil end
os.queueEvent = function(...) queue[#queue + 1] = table.pack(...) end
os.pullEventRaw = function(filter) return coroutine.yield(filter) end
os.pullEvent = function(filter)
  local e = table.pack(coroutine.yield(filter))
  if e[1] == "terminate" then error("Terminated", 0) end
  return table.unpack(e, 1, e.n)
end
os.sleep = function(t)
  local id = os.startTimer(t or 0)
  repeat local _, p = os.pullEvent("timer") until p == id
end
_G.sleep = os.sleep

local function makeParallel(waitAll)
  return function(...)
    local cos, filters, alive = {}, {}, select("#", ...)
    for i, f in ipairs({ ... }) do cos[i] = coroutine.create(f) end
    local event = table.pack()
    while true do
      for i, co in ipairs(cos) do
        if co and (filters[i] == nil or filters[i] == event[1] or event[1] == "terminate") then
          local ok, f = coroutine.resume(co, table.unpack(event, 1, event.n))
          if not ok then error(debug.traceback(co, tostring(f)), 0) end
          filters[i] = f
          if coroutine.status(co) == "dead" then
            cos[i] = false; alive = alive - 1
            if not waitAll then return end
          end
        end
      end
      if alive == 0 then return end
      event = table.pack(coroutine.yield())
    end
  end
end
_G.parallel = { waitForAll = makeParallel(true), waitForAny = makeParallel(false) }

----------------------------------------------------------------------
-- in-memory fs + JSON (tables round-trip through opaque "{#n}" handles)
----------------------------------------------------------------------
local jsonStore, jsonN = {}, 0
local function toJSON(t) jsonN = jsonN + 1; local id = "{#" .. jsonN .. "}"; jsonStore[id] = t; return id end
textutils.serialiseJSON, textutils.serializeJSON = toJSON, toJSON
textutils.unserialiseJSON = function(s) return jsonStore[s] end
textutils.unserializeJSON = textutils.unserialiseJSON

local ADDR  = ("a1"):rep(64)
local BOB   = ("b0"):rep(64)
local SHOP  = ("5e"):rep(64)
local NODES = { { name = "Main", key = ("1"):rep(32) }, { name = "Backup", key = ("2"):rep(32) } }
local files = { ["/wallet_data/nodes.json"] = toJSON(NODES) }
fs.exists  = function(p) return files[p] ~= nil or p == "/wallet_data" end
fs.makeDir = function() end
fs.open = function(p, mode)
  if mode == "r" then
    if not files[p] then return nil end
    return { readAll = function() return files[p] end, close = function() end }
  end
  return { write = function(s) files[p] = s end, close = function() end }
end

----------------------------------------------------------------------
-- stubbed wallet services
----------------------------------------------------------------------
local transfers, acks = {}, {}
local comms = {}
local function noop() return true end
for _, n in ipairs({ "heartbeat", "heartbeatAll", "register", "registerAll",
                     "gossipDns", "gossipDnsAll", "openShopChannel", "closeShopChannel",
                     "vaultLock" }) do comms[n] = noop end
comms.getBalance = function() os.sleep(0.2); return true, { balance = 12500000, _latency = 7 } end
comms.listVaults = function() os.sleep(0.2); return true, { vaults = {} } end
comms.getStats   = function() return true, { effective_rate = 50, fingerprint = "f00d" } end
comms.lookupAll  = function(_, _, name)
  os.sleep(0.5)
  if name:lower() == "bob" then return true, { address = BOB } end
  return false, nil, "Player '" .. name .. "' not found on any node"
end
comms.failNext = false
comms.transfer = function(_, nodeKey, from, to, amount)
  os.sleep(1)   -- a node round-trip; the UI coroutine is blocked meanwhile
  if comms.failNext then comms.failNext = false; return false, nil, "Insufficient funds" end
  transfers[#transfers + 1] = { nodeKey = nodeKey, from = from, to = to, amount = amount }
  return true, {}
end
comms.sendPaymentAck = function(from, txId) acks[#acks + 1] = txId; return true end

local stubs = {
  comms = comms,
  secret_manager = { load = function() return ("c"):rep(32), ADDR, "alice" end,
                     exists = function() return true end },
  session = { load = function() return { logged_in = true } end, save = noop, clear = noop },
}
local realRequire = require
_G.require = function(name)
  if stubs[name] then return stubs[name] end
  if name == "wallet_ui" then return realRequire("wallet.wallet_ui") end
  return realRequire(name)
end

----------------------------------------------------------------------
-- driver
----------------------------------------------------------------------
local main = coroutine.create(function() dofile("wallet/main.lua") end)
local topFilter, started = nil, false

local function deliver(e)
  if coroutine.status(main) == "dead" then error("wallet exited unexpectedly") end
  if started and topFilter ~= nil and topFilter ~= e[1] and e[1] ~= "terminate" then return end
  started = true
  local ok, f = coroutine.resume(main, table.unpack(e, 1, e.n))
  if not ok then error(debug.traceback(main, "WALLET CRASHED: " .. tostring(f)), 0) end
  topFilter = f
end

-- Run the wallet for `seconds` of virtual time.
local function pump(seconds)
  local deadline, steps = nowMs + seconds * 1000, 0
  while true do
    steps = steps + 1
    assert(steps < 200000, "pump: runaway event loop")
    if #queue > 0 then
      deliver(table.remove(queue, 1))
    else
      local id, due
      for tid, t in pairs(timers) do
        if not due or t < due or (t == due and tid < id) then id, due = tid, t end
      end
      if not id or due > deadline then nowMs = deadline; return end
      nowMs = due; timers[id] = nil
      deliver(table.pack("timer", id))
    end
  end
end

local function inject(...) queue[#queue + 1] = table.pack(...) end
-- Input is spaced out like a human's: the UI runs one input handler at a time
-- and drops events that arrive while a repaint is still yielding.
local function typeText(s)
  for ch in s:gmatch(".") do inject("char", ch); pump(0.2) end
end
local function press(name, wait)
  inject("key", keys[name], false); pump(0.2)
  inject("key_up", keys[name]); pump(wait or 0.3)
end
local function click(x, y, wait)
  inject("mouse_click", 1, x, y); pump(0.2)
  inject("mouse_up", 1, x, y); pump(wait or 0.3)
end
local function invoice(fields)
  local pkt = { type = "INVOICE", to = ADDR, tx_id = "tx" .. (jsonN + 1), shop_addr = SHOP,
                shop_name = "AmiStore", item = "minecraft:diamond", qty = 3,
                total = 1500000, expires = nowMs + 120000 }
  for k, v in pairs(fields or {}) do pkt[k] = v end
  inject("modem_message", "back", 1338, 1338, toJSON(pkt), 0)
  return pkt
end

local function row(y) return shim.screen.text[y] end
local function screenHas(s)
  for y = 1, shim.H do if row(y):find(s, 1, true) then return true end end
  return false
end
local function dump(label)
  if VERBOSE then print("\n== " .. label .. " =="); print(shim.dumpScreen()) end
end
local passed = 0
local function check(cond, what)
  if not cond then
    print("FAIL: " .. what); print(shim.dumpScreen()); os.exit(1)
  end
  passed = passed + 1
  print("  ok  " .. what)
end
local function onDashboard() return screenHas("[S]end") and screenHas("Bal:") end

----------------------------------------------------------------------
print("== boot ==")
deliver(table.pack())
pump(3)
dump("dashboard")
check(onDashboard(), "dashboard is showing after boot")
check(screenHas("25.00000"), "dashboard shows the fetched balance")

print("== send: dashboard must not paint over the form ==")
click(3, 18)
dump("send page")
check(screenHas("Send AMI") and screenHas("To (name or address):"), "Send page opens from [S]end")
check(screenHas("Bal: 25.00000 AMI"), "Send page shows the available balance")
pump(12)   -- two full balance-refresh cycles
check(screenHas("Send AMI") and not onDashboard(), "Send page survives the 5s balance refresh")

print("== send: validation ==")
press("enter"); press("enter"); press("enter"); press("enter")   -- to, amount, unit, node -> Send
press("enter")
check(screenHas("Enter a recipient."), "empty recipient is rejected")
check(#transfers == 0, "nothing sent")
typeText("carol"); press("enter")
typeText("abc"); press("enter"); press("enter"); press("enter"); press("enter", 3)
check(screenHas("Invalid amount."), "non-numeric amount is rejected")
for _ = 1, 3 do press("backspace") end
typeText("2"); press("enter"); press("enter"); press("enter"); press("enter", 3)
dump("unknown name")
check(screenHas("'carol' not") and screenHas("128-hex address."), "unknown name reports the lookup failure")
check(#transfers == 0, "nothing sent for an unknown name")

print("== send: name lookup, confirm, transfer ==")
for _ = 1, 5 do press("backspace") end
typeText("Bob"); press("enter")
press("backspace"); typeText("1.5"); press("enter")
press("enter")                 -- unit stays AMI
press("right"); press("enter") -- node chooser: Main -> Backup
press("enter", 3)              -- Send -> review
dump("confirm")
check(screenHas("Confirm"), "button turns into Confirm after review")
check(screenHas("1.500000 AMI") and screenHas("Backup"), "confirmation shows amount and node")
check(#transfers == 0, "review alone does not transfer")
typeText("")                   -- no-op
press("enter", 3)              -- Confirm
dump("sent")
check(#transfers == 1, "confirm performs exactly one transfer")
check(transfers[1].to == BOB and transfers[1].amount == 1500000
  and transfers[1].nodeKey == NODES[2].key and transfers[1].from == ADDR,
  "transfer has the resolved address, micro amount and chosen node")
check(screenHas("Sent 1.500000 AMI") and screenHas("Done"), "result is shown with a Done button")
press("enter", 3)              -- Done
check(onDashboard(), "Done returns to the dashboard")

print("== send: editing cancels a pending confirmation; uAMI; failure ==")
click(3, 18)
typeText("bob"); press("enter"); typeText("250"); press("enter")
press("right"); press("enter"); press("enter")   -- unit -> uAMI, node stays Main
press("enter", 3)
check(screenHas("250 uAMI") and screenHas("Confirm"), "uAMI amount is reviewed in uAMI")
press("up"); press("up"); press("up")            -- back to the amount field
typeText("0")
check(not screenHas("Confirm") and screenHas("Send"), "editing a field drops back to Send")
press("enter"); press("enter"); press("enter"); press("enter", 3)
check(screenHas("2500 uAMI"), "re-review picks up the edited amount")
comms.failNext = true
press("enter", 3)
dump("failed")
check(screenHas("Failed: Insufficient") and #transfers == 1, "a failed transfer is reported")
check(screenHas("Send AMI") and not screenHas("Done"), "a failed transfer stays on the form")
press("enter", 3); press("enter", 3)
check(#transfers == 2 and transfers[2].amount == 2500 and transfers[2].nodeKey == NODES[1].key,
  "retry sends 2500 uAMI via the first node")
click(26, 1)                                     -- title bar close
check(onDashboard(), "title bar X returns to the dashboard")

print("== invoice: pay ==")
local inv = invoice()
pump(1)
dump("invoice")
check(screenHas("Incoming Invoice") and screenHas("AmiStore") and screenHas("diamond"),
  "invoice page opens over the dashboard")
check(screenHas("1.500000 AMI") and screenHas("1500000 uAMI"), "invoice shows the total in both units")
pump(12)
check(screenHas("Incoming Invoice") and not onDashboard(), "invoice page survives the balance refresh")
inject("char", "y"); pump(3)
dump("invoice paid")
check(#transfers == 3 and transfers[3].to == SHOP and transfers[3].amount == 1500000,
  "[Y] pays the shop the invoice total")
check(acks[1] == inv.tx_id, "payment ack carries the invoice tx id")
check(screenHas("Payment sent!") and screenHas("[B]ack") and not screenHas("[Y] Pay"),
  "paid invoice shows the result with only Back")
inject("char", "y"); pump(3)
check(#transfers == 3, "a second [Y] cannot pay twice")
check(onDashboard(), "dismissing a paid invoice returns to the dashboard")

print("== invoice: decline, Enter, expiry, malformed ==")
invoice(); pump(1)
inject("char", "N"); pump(1)
check(onDashboard() and #transfers == 3, "[N] declines without paying (any case)")
invoice(); pump(1)
press("enter", 2)
check(onDashboard() and #transfers == 3, "Enter on a fresh invoice declines (focus starts on Decline)")
invoice({ expires = nowMs - 1 }); pump(1)
check(onDashboard(), "an already-expired invoice is not shown")
invoice({ total = "lots" }); pump(1)
check(onDashboard(), "a malformed invoice is not shown")
invoice({ to = BOB }); pump(1)
check(onDashboard(), "an invoice for another wallet is not shown")
invoice({ expires = nowMs + 5000 }); pump(1)
check(screenHas("Incoming Invoice"), "short-lived invoice opens")
pump(10)
click(3, 18, 3)
check(screenHas("Invoice expired") and #transfers == 3, "paying after expiry is refused")
inject("char", "b"); pump(1)
check(onDashboard(), "[B] dismisses the expired invoice")
comms.failNext = true
invoice(); pump(1); click(3, 18, 3)
check(screenHas("Failed: Insufficient") and #acks == 1, "failed payment sends no ack")
click(16, 18, 1)
check(onDashboard(), "Back button dismisses a failed invoice")

print("== invoice: waits for the Send form and for raw screens ==")
click(3, 18)
typeText("bob")
invoice(); pump(2)
check(screenHas("Send AMI") and not screenHas("Incoming Invoice"), "invoice does not interrupt the Send form")
typeText("y")
check(#transfers == 3, "typing 'y' in the Send form pays nothing")
click(16, 18, 2)
check(screenHas("Incoming Invoice"), "invoice opens once the Send form is closed")
inject("char", "n"); pump(1)
check(onDashboard(), "declining returns to the dashboard")

click(14, 18)                                    -- [E]xp: raw-terminal screen
check(screenHas("Export Secret Key"), "raw Export screen opens")
invoice(); pump(2)
check(not screenHas("Incoming Invoice"), "invoice waits while a raw screen has the keyboard")
press("x", 2)
check(screenHas("Incoming Invoice"), "invoice opens after the raw screen closes")
inject("char", "y"); pump(3)
check(#transfers == 4, "deferred invoice can still be paid")
inject("char", "b"); pump(1)

click(22, 18, 1)                                 -- [N] Command Center
check(screenHas("Command Center"), "Command Center opens")
invoice(); pump(1)
check(screenHas("Incoming Invoice"), "invoice opens over the Command Center")
inject("char", "n"); pump(1)
check(screenHas("Command Center"), "declining returns to the Command Center")

print("== keyboard shortcuts ==")
typeText("b"); pump(1)
check(onDashboard(), "[B] leaves the Command Center")
typeText("n"); pump(1)
check(screenHas("Command Center"), "[N] opens the Command Center")
typeText("B"); pump(1)
check(onDashboard(), "shortcuts ignore case")
typeText("e"); pump(1)
check(screenHas("Export Secret Key"), "[E] opens Export")
pump(12)
check(screenHas("Export Secret Key") and not onDashboard(), "raw Export screen survives the balance refresh")
press("x", 2)
check(onDashboard(), "any key leaves Export")
typeText("v"); pump(2)
check(screenHas("AmiVault"), "[V] opens the Vault")
pump(12)
check(screenHas("AmiVault") and not onDashboard(), "raw Vault screen survives the balance refresh")
press("b", 2)
check(onDashboard(), "[B] leaves the Vault")
typeText("s"); pump(1)
check(screenHas("Send AMI") and screenHas("Ami-DNS name / 128-hex"),
  "[S] opens Send without typing the 's' into the form")
typeText("sergeluv")
check(screenHas("sergeluv") and screenHas("Send AMI"), "letters typed in the Send form are not shortcuts")
click(16, 18, 2)
check(onDashboard() and #transfers == 4, "Back leaves Send, nothing was sent")

print(string.format("\nPASS: %d checks", passed))
