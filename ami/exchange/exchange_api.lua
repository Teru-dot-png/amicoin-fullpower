-- /ami/exchange/exchange_api.lua
-- The Great Ami Exchange v1.0 — Intelligence Layer
-- Swaps FTB quest coins (the /coins command) for AmiCoin and back.
--
-- Trimmed from /ami/shop/shop_api.lua: the key, mesh, node-manager and invoice
-- code is the same; listings, AE2, the vending tray and the printer are gone,
-- and a command block does the coin side.
--
-- Peripherals:
--   TOP  : Advanced Monitor (optional status board, exchange_ui.lua owns it)
--   BACK : Modem (wired/wireless) — XTEA mesh comms (any side is found)
--   any  : Command block — runs /coins. Needs `command_block_enabled = true`
--          in the CC:Tweaked server config and command blocks enabled on the
--          server. A Command Computer works too (no command block needed).
--
-- Trust model (read before changing the coin commands):
--   * Ami-DNS names are NOT proof of identity: any wallet can register any
--     name. So coins are only ever taken from a player who is standing at the
--     exchange, alone, and the payout address is shown for them to check.
--   * The computer cannot read a player's coin balance, and a command block
--     reports "success" even when /coins remove refuses for lack of coins. So
--     each /coins command's result is stored in a scoreboard and checked (see
--     coinsChanged). The admin safety test proves that works on this server;
--     trading stays closed until it passes.

local xtea = dofile("/shared/xtea.lua")

local api = {}

-- ── Constants ─────────────────────────────────────────────────────────────────
local SHOP_CHANNEL  = 1338        -- AmiStore buyer↔shop channel (invoices)
local MESH_CHANNEL  = 1337        -- Main AmiCoin mesh
local REPLY_BASE    = 3000        -- Reply channel pool (3000-3999)
local MESH_TIMEOUT  = 10          -- seconds waiting for a mesh reply
local INVOICE_TTL   = 120000      -- 2 minutes (ms)

local BASE_DIR      = "/ami/exchange"
local DATA_DIR      = "/ami/exchange/data"
local CONFIG_FILE   = "/ami/exchange/config.json"
local LOG_FILE      = "/ami/exchange/exchange.log"

-- ── Peripheral handles ────────────────────────────────────────────────────────
local p_monitor = nil
local p_modem   = nil
local p_command = nil   -- command block peripheral

-- ── Runtime state ─────────────────────────────────────────────────────────────
local shopKey       = nil   -- 32-hex secret key (volatile, never sent over wire)
local shopAddress   = nil   -- 128-hex public address
local shopBalance   = 0     -- last witnessed balance in µAMI (the reserve)
local _cfgCache     = nil   -- config cache; invalidated on saveConfig

-- ── Low-level helpers ─────────────────────────────────────────────────────────
local function ensureDir(d)
    if not fs.exists(d) then fs.makeDir(d) end
end

-- Structured logger: log("ERROR", "trade", "message")
-- Severity: INFO, WARN, ERROR. Appends to LOG_FILE only — the terminal is a
-- public screen, so nothing is printed over it.
local function log(severity, module, msg)
    ensureDir(BASE_DIR)
    local ts   = tostring(os.epoch("utc"))
    local line = string.format("[%s] [%s] [%s] %s", ts, module, severity, msg)
    local f = fs.open(LOG_FILE, "a")
    f.write(line .. "\n")
    f.close()
end
api.log = log

local function fnv1a(s)
    local hash = 2166136261
    for i = 1, #s do
        hash = bit32.bxor(hash, string.byte(s, i))
        hash = (hash * 16777619) % 4294967296
    end
    return string.format("%08x", hash)
end

-- Address derivation (mirrors wallet/secret_manager.lua exactly).
local function deriveAddress(keyHex)
    local state = {}
    for i = 1, #keyHex do state[i] = string.byte(keyHex, i) end
    local ex = {}
    for i = 1, 64 do
        local a = state[((i - 1) % #state) + 1]
        local b = state[(i       % #state) + 1]
        local c = state[((i + 7) % #state) + 1]
        ex[i] = (a * 31 + b * 17 + c * 7 + i * 13) % 256
    end
    for i = 1, 64 do
        ex[i] = bit32.bxor(ex[i], ex[(i % 64) + 1]) % 256
    end
    local addr = ""
    for _, b in ipairs(ex) do addr = addr .. string.format("%02x", b) end
    return addr
end

-- ── Exchange key (persisted, hardware-seeded) ─────────────────────────────────
local function loadOrCreateShopKey()
    ensureDir(DATA_DIR)
    local kf = DATA_DIR .. "/shop_key.txt"
    local af = DATA_DIR .. "/shop_addr.txt"
    if fs.exists(kf) then
        local fk = fs.open(kf, "r"); local k = fk.readAll():gsub("%s", ""); fk.close()
        local fa = fs.open(af, "r"); local a = fa.readAll():gsub("%s", ""); fa.close()
        return k, a
    end
    math.randomseed(os.epoch("utc") + os.getComputerID() * 9973)
    local key = ""
    for _ = 1, 32 do key = key .. string.format("%x", math.random(0, 15)) end
    local addr = deriveAddress(key)
    local fk = fs.open(kf, "w"); fk.write(key);  fk.close()
    local fa = fs.open(af, "w"); fa.write(addr); fa.close()
    return key, addr
end

-- ── Config ────────────────────────────────────────────────────────────────────
local DEFAULT_CFG = {
    nodes           = {},
    shop_name       = "The Great Ami Exchange",  -- display name + DNS label
    admin_pass      = "",           -- FNV-1a hash of operator-chosen admin password
    node_setup_pass = "",           -- FNV-1a hash of node setup password (for fetchNodeKey)
    rate            = 400,          -- uAMI per coin, both directions
    max_coins       = 10000,        -- largest single trade, in coins
    radius          = 8,            -- blocks around the command block that count
                                    -- as "standing at the exchange"
    cmd_add         = "coins add %s %d",     -- %s = player name, %d = coins
    cmd_remove      = "coins remove %s %d",
    verified        = false,        -- set by the admin safety test
}

function api.loadConfig()
    if _cfgCache then return _cfgCache end
    local t
    if fs.exists(CONFIG_FILE) then
        local f = fs.open(CONFIG_FILE, "r"); local raw = f.readAll(); f.close()
        t = textutils.unserialiseJSON(raw)
    end
    if type(t) ~= "table" then t = {} end
    for k, v in pairs(DEFAULT_CFG) do
        if t[k] == nil then
            t[k] = (type(v) == "table") and {} or v
        end
    end
    _cfgCache = t
    return _cfgCache
end

function api.saveConfig(cfg)
    _cfgCache = cfg   -- update cache immediately
    ensureDir(BASE_DIR)
    local f = fs.open(CONFIG_FILE, "w"); f.write(textutils.serialiseJSON(cfg)); f.close()
end

-- Hash and persist an admin password.  Empty string clears it.
function api.setAdminPass(plaintext)
    local cfg = api.loadConfig()
    if plaintext == "" then
        cfg.admin_pass = ""
    else
        cfg.admin_pass = fnv1a(plaintext)
    end
    api.saveConfig(cfg)
end

-- Returns true if the supplied plaintext matches the stored hash.
function api.checkAdminPass(plaintext)
    local cfg = api.loadConfig()
    if (cfg.admin_pass or "") == "" then return false end
    return fnv1a(plaintext) == cfg.admin_pass
end

-- Returns true when a password has been configured.
function api.hasAdminPass()
    local cfg = api.loadConfig()
    return (cfg.admin_pass or "") ~= ""
end

-- Hash and persist the node setup password (used with fetchNodeKey).
-- Empty string clears it.
function api.setNodePass(plaintext)
    local cfg = api.loadConfig()
    cfg.node_setup_pass = (plaintext == "") and "" or fnv1a(plaintext)
    api.saveConfig(cfg)
end

-- Returns true when a node setup password has been saved.
function api.hasNodePass()
    local cfg = api.loadConfig()
    return (cfg.node_setup_pass or "") ~= ""
end

-- ── Mesh communications ────────────────────────────────────────────────────────
-- Sends an encrypted packet to a node on the main mesh and optionally waits
-- for a reply.  Wire format mirrors node/startup.lua: senderKey|cipher.
--
-- Unlike the shop's copy this is serialised (one request in flight at a time)
-- and only accepts a reply on its own reply channel: the exchange moves money
-- on the answer, so a balance reply must never be mistaken for a transfer one.
local meshBusy = false

local function meshSend(nodeKey, packet, expectReply)
    if not p_modem then return false, nil, "No modem attached" end
    while meshBusy do os.sleep(0.05) end
    meshBusy = true

    if nodeKey and #nodeKey >= 8 then
        packet.targetKey = nodeKey:sub(1, 8)
    end
    local plain   = textutils.serialiseJSON(packet)
    local cipher  = xtea.encrypt(plain, shopKey)
    local wire    = shopKey .. "|" .. cipher
    local replyCh = REPLY_BASE + math.random(0, 999)
    p_modem.open(MESH_CHANNEL)
    p_modem.open(replyCh)
    p_modem.transmit(MESH_CHANNEL, replyCh, wire)
    if not expectReply then
        p_modem.close(replyCh)
        meshBusy = false
        return true, nil, nil
    end
    local timer = os.startTimer(MESH_TIMEOUT)
    local rok, rdata, rerr = false, nil, "Timeout"
    while true do
        local ev, p1, p2, _, p4 = os.pullEvent()
        if ev == "modem_message" and p2 == replyCh and type(p4) == "string" then
            local ok2, plain2 = pcall(xtea.decrypt, p4, nodeKey)
            if ok2 then
                local d = textutils.unserialiseJSON(plain2)
                if type(d) == "table" then
                    os.cancelTimer(timer)
                    rok = d.ok ~= false; rdata = d; rerr = d.err
                    break
                end
            end
        elseif ev == "timer" and p1 == timer then
            break
        end
    end
    p_modem.close(replyCh)
    meshBusy = false
    return rok, rdata, rerr
end

-- Ask the nodes for the exchange's balance right now.
-- Returns the balance, or nil if no node answered (never a cached value).
local function freshBalance()
    local cfg = api.loadConfig()
    for _, node in ipairs(cfg.nodes) do
        local ok, data = meshSend(node.key,
            {cmd = "BALANCE", from = shopAddress, nonce = os.epoch("utc")}, true)
        if ok and data and data.balance then
            shopBalance = data.balance
            return data.balance
        end
    end
    return nil
end

-- Query the exchange's balance from the first reachable witness node.
function api.witnessBalance()
    return freshBalance() or shopBalance   -- cached fallback
end

-- Register the exchange address on all witness nodes so it appears in lookups.
function api.registerShop()
    local cfg = api.loadConfig()
    for _, node in ipairs(cfg.nodes) do
        -- Fire-and-forget: registration needs no reply and must not block boot.
        meshSend(node.key, {cmd = "REGISTER", from = shopAddress, name = cfg.shop_name}, false)
    end
end

-- Resolve a player name to an address via the first reachable witness node.
-- Returns address string on success, nil on failure.
function api.lookupName(playerName)
    local cfg = api.loadConfig()
    for _, node in ipairs(cfg.nodes) do
        local ok, data = meshSend(node.key,
            {cmd = "LOOKUP", from = shopAddress, name = playerName,
             nonce = os.epoch("utc")}, true)
        if ok and data and data.address and #data.address == 128 then
            return data.address
        end
    end
    return nil
end

-- Send µAMI from the exchange to an address. Returns ok, errMsg.
local function transfer(toAddr, amount)
    local cfg   = api.loadConfig()
    local wNode = cfg.nodes[1]
    if not wNode then return false, "No witness node configured" end
    local ok, _, merr = meshSend(wNode.key, {
        cmd    = "TRANSFER",
        from   = shopAddress,
        to     = toAddr,
        amount = amount,
        nonce  = os.epoch("utc"),
    }, true)
    return ok, merr
end

-- ── Node manager ──────────────────────────────────────────────────────────────

-- Derives a 32-hex XTEA key from a plain-text setup password.
-- Algorithm MUST stay identical to wallet/comms.lua and node/startup.lua.
local function keyFromPassword(password)
    local bytes = {}
    for i = 1, #password do bytes[i] = string.byte(password, i) end
    if #bytes == 0 then bytes = {0} end
    local out = {}
    for i = 1, 16 do
        local a = bytes[((i - 1) % #bytes) + 1]
        local b = bytes[(i       % #bytes) + 1]
        local c = bytes[((i + 3) % #bytes) + 1]
        out[i] = bit32.bxor(a * 31 + b * 17 + c * 7 + i * 13, i * 97) % 256
    end
    for i = 1, 16 do
        out[i] = bit32.bxor(out[i], out[(i % 16) + 1]) % 256
    end
    local hex = ""
    for _, b in ipairs(out) do hex = hex .. string.format("%02x", b) end
    return hex
end

-- Send a GETKEY request using a setup password.
-- The outgoing packet is encrypted with shopKey (standard).
-- The reply from the node is encrypted with keyFromPassword(password),
-- so we can decrypt it without already knowing the node key.
-- Returns: ok (bool), nodeKey (32-hex string or nil), errMsg (string or nil)
function api.fetchNodeKey(password)
    if not p_modem then return false, nil, "No modem attached" end
    local pkt    = { cmd="GETKEY", from=shopAddress, password=password, nonce=os.epoch("utc") }
    local plain  = textutils.serialiseJSON(pkt)
    local cipher = xtea.encrypt(plain, shopKey)
    local wire   = shopKey .. "|" .. cipher

    local replyCh = REPLY_BASE + math.random(0, 999)
    p_modem.open(MESH_CHANNEL)
    p_modem.open(replyCh)
    p_modem.transmit(MESH_CHANNEL, replyCh, wire)

    local pwdKey = keyFromPassword(password)
    local timer  = os.startTimer(MESH_TIMEOUT)
    local rok, rkey, rerr = false, nil, "Timeout - no node responded"

    while true do
        local ev, p1, _, _, p4 = os.pullEvent()
        if ev == "modem_message" and type(p4) == "string" then
            local ok2, plain2 = pcall(xtea.decrypt, p4, pwdKey)
            if ok2 then
                local d = textutils.unserialiseJSON(plain2)
                if type(d) == "table" then
                    if d.ok and type(d.key) == "string" then
                        os.cancelTimer(timer)
                        rok = true; rkey = d.key; rerr = nil
                        break
                    elseif d.err then
                        os.cancelTimer(timer)
                        rerr = d.err
                        break
                    end
                end
            end
        elseif ev == "timer" and p1 == timer then
            break
        end
    end

    p_modem.close(replyCh)
    return rok, rkey, rerr
end

function api.addNode(name, key)
    if not name or not key or #key ~= 32 then return false, "Key must be 32 hex chars" end
    local cfg = api.loadConfig()
    for _, n in ipairs(cfg.nodes) do
        if n.key == key then return false, "Node already exists" end
    end
    cfg.nodes[#cfg.nodes + 1] = {name = name, key = key}
    api.saveConfig(cfg)
    return true, nil
end

function api.removeNode(idx)
    local cfg = api.loadConfig()
    if not cfg.nodes[idx] then return false, "Index out of range" end
    table.remove(cfg.nodes, idx)
    api.saveConfig(cfg)
    return true, nil
end

-- ── Coin commands (command block) ─────────────────────────────────────────────

-- A Minecraft account name: the ONLY text from the keyboard that ever reaches
-- a command. Anything else (spaces, @, quotes...) could inject a command that
-- runs with operator rights, so it is refused here, before any command is built.
function api.validName(name)
    return type(name) == "string" and #name >= 1 and #name <= 16
        and name:match("^[A-Za-z0-9_]+$") ~= nil
end

-- Whole coins, 1..max_coins. Returns the integer or nil.
function api.parseCoins(text)
    local n = tonumber(text)
    if not n or n ~= math.floor(n) or n < 1 then return nil end
    if n > api.loadConfig().max_coins then return nil end
    return math.floor(n)
end

function api.hasCommands()
    return p_command ~= nil or (type(commands) == "table" and commands.exec ~= nil)
end

-- Run one server command. Returns true only if the game reports success.
local function runCommand(cmd)
    if type(commands) == "table" and commands.exec then   -- Command Computer
        local ok, res = pcall(commands.exec, cmd)
        return ok and res == true
    end
    if not p_command then return false end
    local ok, res = pcall(function()
        p_command.setCommand(cmd)
        return p_command.runCommand()
    end)
    return ok and res == true
end

-- Selector for the named player standing within `radius` of the command block.
local function selHere(name)
    return string.format("@a[name=%s,distance=..%d]", name, api.loadConfig().radius)
end

-- Selector for anybody ELSE standing there.
local function selOthers(name)
    return string.format("@a[name=!%s,distance=..%d]", name, api.loadConfig().radius)
end

-- Is the named player online and standing at the exchange?
function api.playerPresent(name)
    if not api.validName(name) then return false end
    return runCommand("execute if entity " .. selHere(name))
end

-- Is the named player at the exchange with nobody else in range?
function api.playerAlone(name)
    if not api.validName(name) then return false end
    return runCommand("execute if entity " .. selHere(name)
        .. " unless entity " .. selOthers(name))
end

-- A command block only reports whether a command ran without an error, and
-- `/coins remove` does NOT error when the player has too few coins: it prints
-- "insufficient funds", changes nothing and still counts as a success. What
-- tells the two apart is the command's result value (the number of players it
-- actually changed), so every /coins command is run through
-- `execute store result score` and the score is checked afterwards.
local SCORE_OBJ = "amiex"

-- Run a /coins command. `guard` is an optional "if entity ... " prefix.
-- Returns true only if the command really changed the player's balance.
local function coinsChanged(guard, coinCmd)
    local holder = "#ex" .. os.getComputerID()
    runCommand("scoreboard objectives add " .. SCORE_OBJ .. " dummy")   -- errors if it exists: fine
    -- Start from 0 so a skipped command cannot leave an old 1 behind.
    if not runCommand(string.format("scoreboard players set %s %s 0", holder, SCORE_OBJ)) then
        return false
    end
    runCommand(string.format("execute %sstore result score %s %s run %s",
        guard or "", holder, SCORE_OBJ, coinCmd))
    return runCommand(string.format("execute if score %s %s matches 1", holder, SCORE_OBJ))
end

-- Give coins to a player. Returns true if the coins were really added.
local function giveCoins(name, coins)
    if not api.validName(name) then return false end
    return coinsChanged(nil, string.format(api.loadConfig().cmd_add, name, coins))
end

-- Take coins from a player. The presence check and the removal are ONE
-- command, so the player cannot be swapped between the check and the take.
-- Returns true only if the coins were really removed: false if they are not
-- alone at the exchange or hold fewer coins than asked.
local function takeCoins(name, coins)
    if not api.validName(name) then return false end
    return coinsChanged("if entity " .. selHere(name)
        .. " unless entity " .. selOthers(name) .. " ",
        string.format(api.loadConfig().cmd_remove, name, coins))
end

-- ── Admin safety test ─────────────────────────────────────────────────────────
-- Proves the three things trading depends on, using the admin's own coins:
--   1. adding a coin is seen as a change       (else paid buys would be
--                                               refunded although coins came)
--   2. removing a coin is seen as a change
--   3. removing more than the player holds is seen as NO change (else selling
--      coins you do not have would still pay out AMI)
-- balance = the coins the admin holds right now (from /coins get).
-- Returns ok (bool), report (array of {text, ok}).
function api.safetyTest(name, balance)
    local report = {}
    local function step(text, ok) report[#report + 1] = {text = text, ok = ok}; return ok end
    local cfg = api.loadConfig()
    cfg.verified = false
    api.saveConfig(cfg)

    if not api.hasCommands() then
        step("No command block attached", false); return false, report
    end
    if not step("Find " .. name .. " alone at the exchange", api.playerAlone(name)) then
        return false, report
    end
    if not step("Adding 1 coin is detected", giveCoins(name, 1)) then
        return false, report
    end
    if not step("Removing 1 coin is detected", takeCoins(name, 1)) then
        return false, report
    end
    local over = balance + 1
    if takeCoins(name, over) then
        -- The coins really were removed, so the player held more than they
        -- typed. Put them back; this is a wrong number, not a broken server.
        giveCoins(name, over)
        step(string.format("Removing %d coins must be refused (you said you hold %d)",
            over, balance), false)
        log("WARN", "safety", "remove of balance+1 went through for " .. name
            .. " -- balance was entered too low")
        return false, report
    end
    step(string.format("Removing %d coins is refused (you hold %d)", over, balance), true)

    cfg.verified = true
    api.saveConfig(cfg)
    log("INFO", "safety", "safety test passed by " .. name)
    return true, report
end

-- Is the exchange able to trade? Returns ok, reason.
function api.isOpen()
    local cfg = api.loadConfig()
    if not p_modem           then return false, "No modem attached" end
    if not api.hasCommands() then return false, "No command block attached" end
    if #cfg.nodes == 0       then return false, "No node configured" end
    if not cfg.verified      then return false, "Safety test not passed yet" end
    return true, nil
end

-- ── Buy coins: player pays AMI through a wallet invoice ───────────────────────
-- Same INVOICE / PAYMENT_ACK flow as AmiStore: the packets are plaintext JSON
-- on SHOP_CHANNEL, and payment is confirmed by witnessing the balance.

local pendingInvoice = nil      -- at most one active invoice at a time

-- Broadcast an invoice for `coins` coins to the buyer's wallet.
-- Returns txId (string) or nil, errMsg.
function api.sendInvoice(buyerAddr, buyerName, coins)
    if not p_modem then return nil, "No modem attached" end
    if pendingInvoice then return nil, "Another purchase is in progress" end
    local snapshot = freshBalance()
    if not snapshot then return nil, "Nodes are not answering" end
    local cfg    = api.loadConfig()
    local total  = coins * cfg.rate
    local txId   = fnv1a(buyerAddr .. "coins"
                         .. tostring(coins) .. tostring(os.epoch("utc")))
    local packet = textutils.serialiseJSON({
        type      = "INVOICE",
        to        = buyerAddr,
        tx_id     = txId,
        shop_addr = shopAddress,
        shop_name = cfg.shop_name,
        item      = "FTB coins",
        qty       = coins,
        price     = cfg.rate,
        total     = total,
        expires   = os.epoch("utc") + INVOICE_TTL,
    })
    p_modem.transmit(SHOP_CHANNEL, SHOP_CHANNEL, packet)
    pendingInvoice = {
        txId        = txId,
        buyerAddr   = buyerAddr,
        buyerName   = buyerName,
        coins       = coins,
        total       = total,
        expires     = os.epoch("utc") + INVOICE_TTL,
        balSnapshot = snapshot,   -- balance before invoice; used to detect payment
    }
    log("INFO", "buy", string.format("Invoice %s -> %s  %d coins for %d uAMI",
        txId:sub(1, 8), buyerName, coins, total))
    return txId, nil
end

-- Cancel the active pending invoice; broadcasts INVOICE_CANCEL.
function api.cancelInvoice()
    if not pendingInvoice then return end
    if p_modem then
        local pkt = textutils.serialiseJSON({
            type  = "INVOICE_CANCEL",
            tx_id = pendingInvoice.txId,
        })
        p_modem.transmit(SHOP_CHANNEL, SHOP_CHANNEL, pkt)
    end
    log("INFO", "buy", "Cancelled invoice " .. pendingInvoice.txId:sub(1, 8))
    pendingInvoice = nil
end

-- Returns the current pending invoice table, or nil.
function api.getPendingInvoice()
    return pendingInvoice
end

-- Check whether the active invoice has been paid and, if so, hand out the
-- coins. Call it when a PAYMENT_ACK arrives and on a timer: the ACK is only a
-- hint (it is plaintext and can be forged or lost), the ledger is the proof.
-- If the coin command fails the AMI is sent back.
-- Returns state, message:
--   "waiting" — not paid yet, invoice still open
--   "done"    — paid and coins handed out
--   "failed"  — paid but no coins (message says whether the AMI was refunded)
function api.settleInvoice(txId)
    local inv = pendingInvoice
    if not inv or inv.txId ~= txId then
        return "failed", "No matching pending invoice"
    end
    local newBal = freshBalance()
    -- freshBalance yields: make sure nobody settled or cancelled it meanwhile.
    if pendingInvoice ~= inv then return "failed", "No matching pending invoice" end
    if not newBal or newBal < inv.balSnapshot + inv.total then
        return "waiting", "Payment not confirmed yet"
    end
    pendingInvoice = nil

    if giveCoins(inv.buyerName, inv.coins) then
        log("INFO", "buy", string.format("OK: %s paid %d uAMI for %d coins [%s]",
            inv.buyerName, inv.total, inv.coins, txId))
        return "done", string.format("%d coins added to %s", inv.coins, inv.buyerName)
    end
    local rok, rerr = transfer(inv.buyerAddr, inv.total)
    if rok then
        log("ERROR", "buy", string.format("coins add failed for %s; refunded %d uAMI [%s]",
            inv.buyerName, inv.total, txId))
        return "failed", "Coin command failed -- your AMI was refunded"
    end
    log("ERROR", "buy", string.format(
        "OWED: %s (%s) paid %d uAMI, got no coins, refund failed: %s [%s]",
        inv.buyerName, inv.buyerAddr, inv.total, tostring(rerr), txId))
    return "failed", "Coin command AND refund failed -- tell an admin"
end

-- Parse a plaintext JSON broadcast from SHOP_CHANNEL (not XTEA-encrypted).
-- Returns an action table, or nil.
--   {type="PAYMENT_ACK",  tx_id=..., from=...}
function api.processShopBroadcast(wire)
    if type(wire) ~= "string" or wire:sub(1, 1) ~= "{" then return nil end
    local ok, pkt = pcall(textutils.unserialiseJSON, wire)
    if not ok or type(pkt) ~= "table" then return nil end
    if pkt.type == "PAYMENT_ACK" and type(pkt.tx_id) == "string" then
        return { type = "PAYMENT_ACK", tx_id = pkt.tx_id, from = pkt.from }
    end
    -- INVOICE and INVOICE_CANCEL are self-broadcasts; ignore them.
    return nil
end

-- ── Sell coins: take coins with the command block, pay AMI out ────────────────
-- sellerAddr must already be resolved (and shown to the player) by the caller.
-- Returns ok (bool), message (string).
function api.sellCoins(sellerName, sellerAddr, coins)
    if not api.validName(sellerName) then return false, "Invalid player name" end
    if pendingInvoice then return false, "A purchase is in progress -- try again shortly" end
    local payout = coins * api.loadConfig().rate

    local before = freshBalance()
    if not before then return false, "Nodes are not answering" end
    if before < payout then
        return false, string.format("Exchange reserve too low (%.4f AMI left)", before / 1000000)
    end

    if not takeCoins(sellerName, coins) then
        return false, "Coins not taken: you need " .. coins
            .. " coins and must be alone at the exchange"
    end

    local ok, terr = transfer(sellerAddr, payout)
    if not ok then
        -- A timeout does not mean the AMI stayed here. Trust the ledger.
        local after = freshBalance()
        if after and after <= before - payout then
            ok = true
        elseif after then
            -- AMI definitely not sent: hand the coins back.
            if giveCoins(sellerName, coins) then
                log("WARN", "sell", string.format("transfer failed (%s); returned %d coins to %s",
                    tostring(terr), coins, sellerName))
                return false, "Payout failed -- your coins were returned"
            end
            log("ERROR", "sell", string.format(
                "OWED: took %d coins from %s (%s), payout failed (%s), coin return failed",
                coins, sellerName, sellerAddr, tostring(terr)))
            return false, "Payout AND coin return failed -- tell an admin"
        else
            log("ERROR", "sell", string.format(
                "DISPUTE: took %d coins from %s (%s); payout of %d uAMI unconfirmed (%s)",
                coins, sellerName, sellerAddr, payout, tostring(terr)))
            return false, "Payout could not be confirmed -- tell an admin"
        end
    end
    shopBalance = before - payout
    log("INFO", "sell", string.format("OK: %s sold %d coins for %d uAMI -> %s...",
        sellerName, coins, payout, sellerAddr:sub(1, 8)))
    return true, string.format("%.6f AMI sent to your wallet", payout / 1000000)
end

-- ── Accessors ─────────────────────────────────────────────────────────────────
function api.getMonitor()   return p_monitor  end
-- api.getShopKey() intentionally omitted — the secret key must not be exported.
function api.getShopAddr()  return shopAddress end
function api.getModem()     return p_modem    end
function api.getShopBal()   return shopBalance end
function api.getLogFile()   return LOG_FILE   end

-- ── Init ──────────────────────────────────────────────────────────────────────
function api.init()
    math.randomseed(os.epoch("utc") + os.getComputerID())
    ensureDir(DATA_DIR)
    shopKey, shopAddress = loadOrCreateShopKey()

    p_monitor = peripheral.isPresent("top") and peripheral.getType("top") == "monitor"
        and peripheral.wrap("top") or nil
    p_modem   = peripheral.isPresent("back") and peripheral.getType("back") == "modem"
        and peripheral.wrap("back") or peripheral.find("modem")
    p_command = peripheral.find("command")

    if p_modem then
        p_modem.open(SHOP_CHANNEL)
        p_modem.open(MESH_CHANNEL)
    end
    return shopAddress
end

return api
