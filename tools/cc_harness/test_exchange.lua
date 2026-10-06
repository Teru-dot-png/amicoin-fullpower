-- tools/cc_harness/test_exchange.lua
-- Boots the REAL /ami/exchange/startup.lua against a fake world: a node ledger
-- behind the modem (real XTEA on the wire), a command block that implements
-- /coins and the `execute if entity` presence checks, and scripted players.
-- Drives buy, sell, the admin safety test and the abuse cases.
--
-- Run from the repo root:
--   lua5.4 tools/cc_harness/test_exchange.lua
local shim = dofile("tools/cc_harness/shim.lua")
local VERBOSE = os.getenv("VERBOSE")

----------------------------------------------------------------------
-- Lua 5.4 stand-ins for CC globals the exchange uses
----------------------------------------------------------------------
local function int(n) return math.tointeger(n) or math.floor(n) end
_G.bit32 = { bxor = function(a, b) return (int(a) ~ int(b)) & 0xFFFFFFFF end }

local keys, keyNames = {}, {}
for c = 65, 90 do keys[string.char(c + 32)] = c; keyNames[c] = string.char(c + 32) end
keys.enter = 257; keys.grave = 96
keys.getName = function(c) return keyNames[c] end
_G.keys = keys

local realDofile = dofile
_G.dofile = function(p) return realDofile((p:gsub("^/", ""))) end

----------------------------------------------------------------------
-- virtual clock, timers, event queue (real CC semantics: pullEvent yields)
----------------------------------------------------------------------
local nowMs, nextTimer, timers, queue = 1000000, 0, {}, {}
os.clock = function() return nowMs / 1000 end
os.epoch = function() return nowMs end
os.startTimer = function(t)
  nextTimer = nextTimer + 1
  timers[nextTimer] = nowMs + math.max(t or 0, 0.05) * 1000
  return nextTimer
end
os.cancelTimer = function(id) timers[id] = nil end
os.queueEvent = function(...) queue[#queue + 1] = table.pack(...) end
os.pullEventRaw = function(filter)
  while true do
    local e = table.pack(coroutine.yield(filter))
    if filter == nil or e[1] == filter or e[1] == "terminate" then
      return table.unpack(e, 1, e.n)
    end
  end
end
os.pullEvent = function(filter)
  local e = table.pack(os.pullEventRaw(filter))
  if e[1] == "terminate" then error("Terminated", 0) end
  return table.unpack(e, 1, e.n)
end
os.sleep = function(t)
  local id = os.startTimer(t or 0)
  repeat local ev, p = os.pullEventRaw("timer") until ev == "timer" and p == id
end
_G.sleep = os.sleep
local rebooted = false
os.reboot = function() rebooted = true; error("REBOOT", 0) end

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
-- in-memory fs, settings, JSON (tables round-trip through "{#n}" handles)
----------------------------------------------------------------------
local jsonStore, jsonN = {}, 0
local function toJSON(t) jsonN = jsonN + 1; local id = "{#" .. jsonN .. "}"; jsonStore[id] = t; return id end
textutils.serialiseJSON, textutils.serializeJSON = toJSON, toJSON
textutils.unserialiseJSON = function(s) return jsonStore[s] end
textutils.unserializeJSON = textutils.unserialiseJSON

local files = {}
fs.exists  = function(p) return files[p] ~= nil or p:match("^/ami") ~= nil and not p:match("%.") end
fs.makeDir = function() end
fs.open = function(p, mode)
  if mode == "r" then
    if not files[p] then return nil end
    local lines, i = {}, 0
    for l in (files[p]):gmatch("([^\n]*)\n") do lines[#lines + 1] = l end
    return { readAll = function() return files[p] end,
             readLine = function() i = i + 1; return lines[i] end,
             close = function() end }
  end
  if mode == "w" then files[p] = "" end
  return { write = function(s) files[p] = (files[p] or "") .. s end, close = function() end }
end
_G.settings = { set = function() end, save = function() end }
_G.shell = { run = function() end }

----------------------------------------------------------------------
-- terminal: everything printed since the last clear lands in `screenText`
----------------------------------------------------------------------
local screenText = ""
term.clear = function() screenText = "" end
_G.print = function(...) screenText = screenText .. table.concat({ ... }, " ") .. "\n" end
io.write = function(s) screenText = screenText .. s end
local function readLine()
  local _, text = os.pullEvent("line")
  screenText = screenText .. text .. "\n"
  return text
end
io.read = readLine
_G.read = readLine

----------------------------------------------------------------------
-- fake world: node ledger behind the modem, command block, players
----------------------------------------------------------------------
local xtea    = dofile("/shared/xtea.lua")
local NODEKEY = ("7"):rep(32)
local ledger  = { balances = {}, names = {}, online = true, failTransfers = false }
local invoices, commandsRun = {}, {}
local EXCHANGE                         -- exchange address, learnt from its first packet

local modem = { open = function() end, close = function() end }
modem.transmit = function(ch, replyCh, msg)
  if ch == 1338 then
    local pkt = jsonStore[msg]
    if pkt and pkt.type == "INVOICE" then invoices[#invoices + 1] = pkt end
    return
  end
  if ch ~= 1337 or not ledger.online then return end
  local key, cipher = msg:match("^(%x+)|(.+)$")
  local pkt = jsonStore[xtea.decrypt(cipher, key)]
  assert(pkt, "node could not read the exchange's packet")
  EXCHANGE = EXCHANGE or pkt.from
  local reply
  if pkt.cmd == "BALANCE" then
    reply = { ok = true, balance = ledger.balances[pkt.from] or 0 }
  elseif pkt.cmd == "LOOKUP" then
    local addr = ledger.names[pkt.name:lower()]
    reply = addr and { ok = true, address = addr } or { ok = false, err = "not found" }
  elseif pkt.cmd == "REGISTER" then
    ledger.names[pkt.name:lower()] = pkt.from
    return
  elseif pkt.cmd == "TRANSFER" then
    local bal = ledger.balances[pkt.from] or 0
    if ledger.failTransfers then
      reply = { ok = false, err = "Node refused" }
    elseif bal < pkt.amount then
      reply = { ok = false, err = "Insufficient funds" }
    else
      ledger.balances[pkt.from] = bal - pkt.amount
      ledger.balances[pkt.to] = (ledger.balances[pkt.to] or 0) + pkt.amount
      reply = { ok = true }
    end
  end
  os.queueEvent("modem_message", "back", replyCh, 1337, xtea.encrypt(toJSON(reply), NODEKEY), 0)
end

-- players: coins + distance from the command block (nil = offline)
local players = {}
local world = { clampRemove = false, addBroken = false }
local function near(name, r) return players[name] and players[name].dist and players[name].dist <= r end
local function coinCommand(cmd)
  local who, n = cmd:match("^coins add ([%w_]+) (%d+)$")
  if who then
    if world.addBroken or not players[who] then return false end
    players[who].coins = players[who].coins + tonumber(n); return true
  end
  who, n = cmd:match("^coins remove ([%w_]+) (%d+)$")
  if who then
    n = tonumber(n)
    if not players[who] then return false end
    if players[who].coins < n then
      if world.clampRemove then players[who].coins = 0; return true end
      return false
    end
    players[who].coins = players[who].coins - n; return true
  end
  error("command block got an unexpected command: " .. cmd)
end
local cmdBlock = { cmd = "" }
cmdBlock.setCommand = function(c) cmdBlock.cmd = c end
cmdBlock.runCommand = function()
  local cmd = cmdBlock.cmd
  commandsRun[#commandsRun + 1] = cmd
  local name, r, rest = cmd:match("^execute if entity @a%[name=([%w_]+),distance=%.%.(%d+)%](.*)$")
  if not name then return coinCommand(cmd) end
  if not near(name, tonumber(r)) then return false, "Command failed" end
  local other, r2, rest2 = rest:match("^ unless entity @a%[name=!([%w_]+),distance=%.%.(%d+)%](.*)$")
  if other then
    assert(other == name, "others-selector must exclude the same player")
    for n in pairs(players) do
      if n ~= name and near(n, tonumber(r2)) then return false, "Command failed" end
    end
    rest = rest2
  end
  if rest == "" then return true end
  local run = rest:match("^ run (.+)$")
  assert(run, "unparsed command tail: " .. rest)
  if coinCommand(run) then return true end
  return false, "Command failed"
end

local attached = { back = { "modem", modem }, left = { "command", cmdBlock } }
peripheral.isPresent = function(side) return attached[side] ~= nil end
peripheral.getType   = function(side) return attached[side] and attached[side][1] end
peripheral.wrap      = function(side) return attached[side] and attached[side][2] end
peripheral.find      = function(kind)
  for _, p in pairs(attached) do if p[1] == kind then return p[2] end end
end

local realRequire = require
_G.require = function(name)
  if name == "exchange_api" or name == "exchange_ui" then
    return realRequire("ami.exchange." .. name)
  end
  return realRequire(name)
end

----------------------------------------------------------------------
-- driver
----------------------------------------------------------------------
local main = coroutine.create(function() realDofile("ami/exchange/startup.lua") end)
local topFilter, started = nil, false
local function deliver(e)
  if coroutine.status(main) == "dead" then error("exchange exited unexpectedly") end
  if started and topFilter ~= nil and topFilter ~= e[1] and e[1] ~= "terminate" then return end
  started = true
  local ok, f = coroutine.resume(main, table.unpack(e, 1, e.n))
  if not ok then error(debug.traceback(main, "EXCHANGE CRASHED: " .. tostring(f)), 0) end
  topFilter = f
end
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
local function char(c, wait) queue[#queue + 1] = table.pack("char", c); pump(wait or 0.5) end
local function line(text, wait) queue[#queue + 1] = table.pack("line", text); pump(wait or 2) end
local function key(name, wait)
  queue[#queue + 1] = table.pack("key", keys[name], false)
  queue[#queue + 1] = table.pack("char", name)
  pump(wait or 1)
end
local function has(s) return screenText:find(s, 1, true) ~= nil end
local passed = 0
local function check(cond, what)
  if not cond then print = nil; io.stdout:write("FAIL: " .. what .. "\n--- screen ---\n" .. screenText .. "\n"); os.exit(1) end
  passed = passed + 1
  io.stdout:write("  ok  " .. what .. "\n")
end
local function section(s) io.stdout:write("== " .. s .. " ==\n") end
local function dump(label) if VERBOSE then io.stdout:write("\n-- " .. label .. " --\n" .. screenText .. "\n") end end
local function ranCommand(pattern)
  for _, c in ipairs(commandsRun) do if c:find(pattern) then return true end end
  return false
end

local FELIX, AMIE, MALLORY = ("f1"):rep(64), ("a3"):rep(64), ("66"):rep(64)
players.Felix = { coins = 50,  dist = 2 }
players.Amie  = { coins = 900, dist = nil }      -- offline
ledger.names.felix = FELIX; ledger.names.amie = AMIE
ledger.balances[FELIX] = 1000000                 -- 1 AMI

-- A wallet paying the open invoice, then acknowledging it.
local function walletPays(inv, from)
  ledger.balances[from] = ledger.balances[from] - inv.total
  ledger.balances[inv.shop_addr] = (ledger.balances[inv.shop_addr] or 0) + inv.total
  queue[#queue + 1] = table.pack("modem_message", "back", 1338, 1338,
    toJSON({ type = "PAYMENT_ACK", tx_id = inv.tx_id, from = from }), 0)
end

----------------------------------------------------------------------
section("first boot")
deliver(table.pack())
pump(1)
check(has("Set Admin Password"), "first boot asks for an admin password")
line("hunter2"); line("hunter2"); pump(5)
dump("menu")
check(has("The Great Ami Exchange") and has("1 coin = 400 uAMI"), "menu shows the name and the 400 uAMI rate")
check(has("EXCHANGE CLOSED") and has("No node configured"), "closed until a node is configured")
char("b"); char("s")
check(has("EXCHANGE CLOSED") and #commandsRun == 0, "[B]/[S] do nothing while closed")

section("admin: password, node, safety test")
char("`"); line("wrong", 0.5)
check(has("Access denied"), "wrong admin password is refused")
pump(2)
char("`"); line("hunter2")
check(has("Admin") and has("Safety test: NOT passed"), "admin panel opens with the right password")
char("n"); char("a"); line("Main"); char("1"); line(NODEKEY); pump(2)
check(has("[1] Main"), "node added")
char("b"); pump(1)
char("b"); pump(1)
check(has("EXCHANGE CLOSED") and has("Safety test not passed yet"), "still closed until the safety test passes")

-- a server whose /coins remove clamps instead of failing must NOT pass
world.clampRemove = true
char("`"); line("hunter2"); char("t"); line("Felix"); line("50", 5)
dump("safety test (clamping server)")
check(has("[FAIL]") and has("must FAIL") and has("stays closed"), "safety test fails when remove does not fail on too few coins")
check(players.Felix.coins == 51, "coins taken by the failed test were put back (51 = clamped to 0, then +51)")
players.Felix.coins = 50
world.clampRemove = false
key("x"); char("t"); line("Felix"); line("50", 5)
dump("safety test")
check(has("Passed. The exchange is open.") and not has("[FAIL]"), "safety test passes on a strict server")
check(players.Felix.coins == 50, "safety test leaves the admin's coins unchanged")
key("x"); char("b"); pump(1)
check(has("[B]  Buy coins") and has("[S]  Sell coins"), "exchange is open")
ledger.balances[EXCHANGE] = 100000               -- 0.1 AMI reserve
check(ledger.names["the great ami exchange"] == EXCHANGE, "exchange registered its name on the node")

section("buy coins (AMI -> coins)")
commandsRun = {}
char("b"); line("Felix"); line("25", 3)
dump("buy: waiting")
check(#invoices == 1 and invoices[1].to == FELIX and invoices[1].total == 10000 and invoices[1].qty == 25,
  "invoice for 25 coins = 10000 uAMI goes to Felix's wallet")
check(has("Accept it on your wallet pad"), "terminal waits for the wallet")
pump(10)
check(players.Felix.coins == 50, "no coins before payment")
walletPays(invoices[1], FELIX); pump(5)
dump("buy: done")
check(players.Felix.coins == 75, "25 coins added after payment")
check(ledger.balances[EXCHANGE] == 110000 and ledger.balances[FELIX] == 990000, "AMI moved to the exchange")
check(has("25 coins added to Felix"), "terminal confirms the purchase")
key("x")

section("buy: forged ack, lost ack, cancel, failed coin command")
char("b"); line("Felix"); line("10", 3)
queue[#queue + 1] = table.pack("modem_message", "back", 1338, 1338,
  toJSON({ type = "PAYMENT_ACK", tx_id = invoices[2].tx_id, from = MALLORY }), 0)
pump(8)
check(players.Felix.coins == 75, "a forged PAYMENT_ACK without payment gives no coins")
-- pays, but the ACK never arrives: the poll must still find the payment
ledger.balances[FELIX] = ledger.balances[FELIX] - invoices[2].total
ledger.balances[EXCHANGE] = ledger.balances[EXCHANGE] + invoices[2].total
pump(8)
check(players.Felix.coins == 85 and has("10 coins added"), "payment is found on the ledger even if the ACK is lost")
key("x")
char("b"); line("Felix"); line("5", 3)
key("c", 4)
check(has("Cancelled -- nothing was charged") and players.Felix.coins == 85, "[C] cancels an unpaid invoice")
key("x")
world.addBroken = true
char("b"); line("Felix"); line("5", 3)
local before = ledger.balances[FELIX]
walletPays(invoices[#invoices], FELIX); pump(6)
check(has("your AMI was refunded") and ledger.balances[FELIX] == before and players.Felix.coins == 85,
  "if /coins add fails after payment, the AMI is refunded")
world.addBroken = false
key("x")

section("buy: bad input never reaches a command")
commandsRun = {}
for _, evil in ipairs({ "Felix 999", "@a", "Felix] run op Mallory", "Fe;lix", "a b", ("x"):rep(17) }) do
  char("b"); line(evil, 2)
  check(has("not a Minecraft name") and #commandsRun == 0, "name '" .. evil .. "' is refused and runs no command")
  key("x")
end
char("b"); line("Amie", 3)
check(has("not standing at the exchange") and #invoices == 4, "an offline/absent player cannot be invoiced")
key("x")
char("b"); line("Nobody", 3)
check(has("not found"), "a name with no wallet is refused")
key("x")
char("b"); line("Felix"); line("0")
check(has("whole number"), "0 coins is refused")
key("x")
char("b"); line("Felix"); line("2.5")
check(has("whole number"), "fractional coins are refused")
key("x")
char("b"); line("Felix"); line("10001")
check(has("whole number") and #invoices == 4, "more than the max trade is refused")
key("x")

section("sell coins (coins -> AMI)")
local exBefore, feBefore = ledger.balances[EXCHANGE], ledger.balances[FELIX]
char("s"); line("Felix"); line("20", 2)
dump("sell: confirm")
check(has("You get  : 8000 uAMI") and has("Paid to wallet: f1f1..f1f1"), "sell shows the payout and the wallet address")
check(players.Felix.coins == 85, "nothing is taken before confirming")
char("y", 5)
dump("sell: done")
check(players.Felix.coins == 65, "20 coins taken")
check(ledger.balances[FELIX] == feBefore + 8000 and ledger.balances[EXCHANGE] == exBefore - 8000, "8000 uAMI paid out")
check(has("AMI sent to your wallet"), "terminal confirms the sale")
key("x")
char("s"); line("Felix"); line("20", 2); char("n", 2)
check(players.Felix.coins == 65, "[N] at the confirmation takes nothing")

section("sell: abuse cases")
char("s"); line("Felix"); line("200", 2); char("y", 5)
check(has("Coins not taken") and players.Felix.coins == 65 and ledger.balances[FELIX] == feBefore + 8000,
  "selling more coins than you own pays nothing")
key("x")
-- Mallory hijacks Amie's Ami-DNS name, then tries to sell Amie's coins to herself
ledger.names.amie = MALLORY
players.Mallory = { coins = 0, dist = 2 }
players.Felix.dist = nil
players.Amie.dist = 40                            -- online, but not at the exchange
char("s"); line("Amie", 3)
check(has("ALONE") and players.Amie.coins == 900, "cannot sell the coins of a player who is not at the exchange")
key("x")
players.Amie.dist = 3                             -- Amie stands there too
char("s"); line("Amie", 3)
check(has("ALONE") and players.Amie.coins == 900 and (ledger.balances[MALLORY] or 0) == 0,
  "cannot sell someone's coins while anyone else is in range (name hijack)")
key("x")
players.Mallory.dist = nil; players.Amie.dist = nil; players.Felix.dist = 2
ledger.names.amie = AMIE
-- someone walks up between the check and the confirmation
char("s"); line("Felix"); line("5", 2)
players.Mallory.dist = 4
char("y", 5)
check(has("Coins not taken") and players.Felix.coins == 65, "the take itself re-checks that the seller is alone")
players.Mallory.dist = nil
key("x")
-- reserve too small
char("s"); line("Felix"); line("65", 2)
ledger.balances[EXCHANGE] = 1000
char("y", 5)
check(has("reserve too low") and players.Felix.coins == 65, "a sale the reserve cannot cover takes no coins")
key("x")
ledger.balances[EXCHANGE] = 100000
-- node refuses the payout after the coins were taken
ledger.failTransfers = true
char("s"); line("Felix"); line("10", 2); char("y", 6)
check(has("your coins were returned") and players.Felix.coins == 65 and ledger.balances[EXCHANGE] == 100000,
  "if the payout fails the coins are returned")
ledger.failTransfers = false
key("x")

section("lock-down")
check(files["/startup.lua"] and files["/startup.lua"]:find("/ami/exchange/startup", 1, true), "autostart file is written")
queue[#queue + 1] = table.pack("terminate"); pump(1)
check(coroutine.status(main) ~= "dead" and has("Buy coins"), "Ctrl+T does not drop to a shell")
char("q")
check(coroutine.status(main) ~= "dead", "there is no public quit key")
for _, c in ipairs(commandsRun) do
  assert(c:match("^execute if entity @a%[name=[%w_]+,distance=%.%.%d+%]") or c:match("^coins add [%w_]+ %d+$"),
    "unexpected command reached the command block: " .. c)
end
check(true, "only presence checks and well-formed /coins commands ever ran (" .. #commandsRun .. " commands)")
check(not rebooted, "no crash/reboot during the run")

io.stdout:write(string.format("\nPASS: %d checks\n", passed))
