-- /ami/shop/shop_api.lua
-- AmiStore v1.1 — Intelligence Layer
-- Handles peripheral init, listings engine, AE2 logistics, XTEA handshake,
-- and the full WTS/WTB transaction pipeline.
--
-- Peripheral Side Map (hardcoded per spec):
--   TOP    : Advanced Monitor  (3x3) — UI surface (shop_ui.lua owns this)
--   LEFT   : Printer                 — Physical receipt output
--   RIGHT  : me_bridge (AE2)         — Digital storage I/O
--   BOTTOM : Inventory (chest/barrel)— Physical vending tray
--   BACK   : Modem (wired/wireless)  — XTEA mesh comms
--   FRONT  : (user interaction zone, no peripheral)

local xtea = dofile("/shared/xtea.lua")

local api = {}

-- ── Constants ─────────────────────────────────────────────────────────────────
local SHOP_CHANNEL  = 1338        -- Dedicated AmiStore buyer↔shop channel
local MESH_CHANNEL  = 1337        -- Main AmiCoin mesh
local REPLY_BASE    = 3000        -- Reply channel pool (3000-3999)
local MESH_TIMEOUT  = 10          -- seconds waiting for a mesh reply
local ORDER_TTL     = 60000       -- ms a pending order is held before expiry

local DATA_DIR      = "/ami/shop/data"
local LISTINGS_FILE = "/ami/shop/listings.json"
local CONFIG_FILE   = "/ami/shop/config.json"
local LOG_FILE      = "/ami/shop/errors.log"

-- ── Peripheral handles ────────────────────────────────────────────────────────
local p_monitor = nil
local p_printer  = nil
local p_me       = nil   -- me_bridge (AE2)
local p_tray     = nil   -- inventory peripheral (vending tray)
local p_modem    = nil

-- ── Runtime state ─────────────────────────────────────────────────────────────
local shopKey       = nil   -- 32-hex secret key (volatile, never sent over wire)
local shopAddress   = nil   -- 128-hex public address
local shopBalance   = 0     -- last witnessed balance in µAMI
local listings      = {}    -- array loaded from listings.json
local pendingOrders = {}    -- tx_id → {item, qty, price, buyer, expires, type}
local _cfgCache     = nil   -- config cache; invalidated on saveConfig

-- ── Low-level helpers ─────────────────────────────────────────────────────────
local function ensureDir(d)
    if not fs.exists(d) then fs.makeDir(d) end
end

-- Structured logger: log("ERROR", "shop_api", "message")
-- Severity: DEBUG, INFO, WARN, ERROR
-- Always appends to LOG_FILE; WARN/ERROR also print to terminal.
local function log(severity, module, msg)
    ensureDir(DATA_DIR)
    local ts    = tostring(os.epoch("utc"))
    local line  = string.format("[%s] [%s] [%s] %s", ts, module, severity, msg)
    local f = fs.open(LOG_FILE, "a")
    f.write(line .. "\n")
    f.close()
    if severity == "WARN" or severity == "ERROR" then
        term.setTextColor(severity == "ERROR" and colors.red or colors.yellow)
        print(line)
        term.setTextColor(colors.white)
    end
end

local function fnv1a(s)
    local hash = 2166136261
    for i = 1, #s do
        hash = bit32.bxor(hash, string.byte(s, i))
        hash = (hash * 16777619) % 4294967296
    end
    return string.format("%08x", hash)
end

local function newUID()
    -- Combine epoch + computerID + math.random for a unique-enough ID
    return fnv1a(tostring(os.epoch("utc")) .. tostring(os.getComputerID())
                 .. tostring(math.random(0, 2147483647)))
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

-- ── Shop key (persisted, hardware-seeded) ─────────────────────────────────────
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

-- ── Hardware-bound session token (admin gate) ─────────────────────────────────
local function loadOrCreateSessionUUID()
    ensureDir(DATA_DIR)
    local uf = DATA_DIR .. "/session_uuid.txt"
    if fs.exists(uf) then
        local f = fs.open(uf, "r"); local u = f.readAll():gsub("%s", ""); f.close()
        return u
    end
    local u = newUID() .. newUID()
    local f = fs.open(uf, "w"); f.write(u); f.close()
    return u
end

-- Returns the hardware-bound session token (computerID ⊕ UUID hash).
function api.getSessionToken()
    local u = loadOrCreateSessionUUID()
    return fnv1a(tostring(os.getComputerID()) .. u)
end

-- ── Config ────────────────────────────────────────────────────────────────────
local DEFAULT_CFG = {
    nodes          = {},
    shop_name      = "AmiStore",   -- display name + DNS registration label
    sweep_pct      = 5,
    sweep_to       = "",           -- player name to sweep to (resolved via DNS)
    vault_addr     = "",           -- 128-hex address (overrides sweep_to if set)
    vault_node_key = "",           -- 32-hex key of the node hosting the vault
    admin_pass     = "",           -- FNV-1a hash of operator-chosen admin password
    node_setup_pass = "",          -- FNV-1a hash of node setup password (for fetchNodeKey)
}

function api.loadConfig()
    if _cfgCache then return _cfgCache end
    if not fs.exists(CONFIG_FILE) then _cfgCache = DEFAULT_CFG; return DEFAULT_CFG end
    local f = fs.open(CONFIG_FILE, "r"); local raw = f.readAll(); f.close()
    local t = textutils.unserialiseJSON(raw)
    _cfgCache = (type(t) == "table") and t or DEFAULT_CFG
    return _cfgCache
end

function api.saveConfig(cfg)
    _cfgCache = cfg   -- update cache immediately
    local f = fs.open(CONFIG_FILE, "w"); f.write(textutils.serialiseJSON(cfg)); f.close()
end

-- Invalidate the config cache (call if config.json is edited externally).
function api.reloadConfig()
    _cfgCache = nil
    return api.loadConfig()
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

-- ── Listings ──────────────────────────────────────────────────────────────────
function api.loadListings()
    if not fs.exists(LISTINGS_FILE) then listings = {}; return listings end
    local f = fs.open(LISTINGS_FILE, "r"); local raw = f.readAll(); f.close()
    local t = textutils.unserialiseJSON(raw)
    listings = (type(t) == "table" and type(t.listings) == "table") and t.listings or {}
    return listings
end

function api.saveListings(lst)
    listings = lst
    local f = fs.open(LISTINGS_FILE, "w")
    f.write(textutils.serialiseJSON({listings = lst}))
    f.close()
end

function api.getListings() return listings end

-- ── AE2 (me_bridge) helpers ────────────────────────────────────────────────────
-- Reads amount from an item detail table; handles both Advanced Peripherals
-- ('amount') and other bridge mods that use 'count'.
local function itemAmt(t)
    if type(t) ~= "table" then return 0 end
    return (t.amount or t.count or 0)
end

-- Returns how many of itemName the ME network currently holds.
local function meGetStock(itemName)
    if not p_me then return 0 end
    -- Primary path: getItem() — Advanced Peripherals / CC:AE2
    if type(p_me.getItem) == "function" then
        local ok, item = pcall(p_me.getItem, {name = itemName})
        if ok then
            return itemAmt(item)
        else
            log("WARN", "meGetStock", "getItem failed: " .. tostring(item))
        end
    end
    -- Fallback: scan listItems() for mods that expose it instead of getItem
    if type(p_me.listItems) == "function" then
        local ok2, items = pcall(p_me.listItems)
        if ok2 and type(items) == "table" then
            for _, it in ipairs(items) do
                if it.name == itemName then return itemAmt(it) end
            end
            return 0
        else
            log("WARN", "meGetStock", "listItems failed: " .. tostring(items))
        end
    end
    return 0
end

-- Export qty of itemName from AE2 to the bottom tray.
-- Returns transferred count (may be less than qty if stock is short).
local function meExport(itemName, qty)
    if not p_me then return false, "No me_bridge on RIGHT" end
    local ok, result = pcall(p_me.exportItem, {name = itemName, count = qty}, "bottom")
    if not ok then
        log("ERROR", "meExport", tostring(result))
        return false, tostring(result)
    end
    local transferred = type(result) == "number" and result or qty
    if transferred < qty then
        log("WARN", "meExport",
            string.format("requested %d of %s but only %d transferred", qty, itemName, transferred))
    end
    return true, transferred
end

-- Import the contents of the bottom tray matching itemName into AE2.
local function meImport(itemName)
    if not p_me then return false, "No me_bridge on RIGHT" end
    local ok, result = pcall(p_me.importItem, {name = itemName}, "bottom")
    if not ok then
        log("ERROR", "meImport", tostring(result))
        return false, tostring(result)
    end
    return true, type(result) == "number" and result or 0
end

-- Count how many of itemName are in the physical tray.
local function trayCount(itemName)
    if not p_tray then return 0 end
    local ok, list = pcall(p_tray.list)
    if not ok or not list then return 0 end
    local n = 0
    for _, stack in pairs(list) do
        if stack.name == itemName then n = n + stack.count end
    end
    return n
end

-- ── Inventory sync (called every 30 s by startup.lua) ─────────────────────────
-- Refreshes _stock and _liquid fields on each listing so the UI shows
-- live availability without reloading listings.json.
-- AE2 calls are batched: one meGetStock() per unique WTS item, not per render.
function api.syncInventory()
    shopBalance = api.witnessBalance()
    -- Cache AE2 results for this sync pass to avoid duplicate getItem() calls.
    local stockCache = {}
    for _, l in ipairs(listings) do
        if l.type == "WTS" then
            if stockCache[l.item] == nil then
                stockCache[l.item] = meGetStock(l.item)
            end
            l._stock     = stockCache[l.item]
            l._available = l._stock > 0
        elseif l.type == "WTB" then
            l._liquid    = shopBalance
            l._available = shopBalance >= l.price
        end
    end
end

-- Prune expired entries from pendingOrders to prevent unbounded growth.
-- Call from startup.lua's sync loop.
function api.prunePendingOrders()
    local now = os.epoch("utc")
    for id, order in pairs(pendingOrders) do
        if now > order.expires then
            pendingOrders[id] = nil
        end
    end
end

-- ── Mesh communications ────────────────────────────────────────────────────────
-- Sends an encrypted packet to a node on the main mesh and optionally waits
-- for a reply.  Wire format mirrors node/startup.lua: senderKey|cipher.
local function meshSend(nodeKey, packet, expectReply)
    if not p_modem then return false, nil, "No modem on BACK" end
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
        return true, nil, nil
    end
    local timer = os.startTimer(MESH_TIMEOUT)
    local rok, rdata, rerr = false, nil, "Timeout"
    while true do
        local ev, p1, _, _, p4 = os.pullEvent()
        if ev == "modem_message" and type(p4) == "string" then
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
    return rok, rdata, rerr
end

-- Query the shop's balance from the first reachable witness node.
function api.witnessBalance()
    local cfg = api.loadConfig()
    for _, node in ipairs(cfg.nodes) do
        local ok, data = meshSend(node.key,
            {cmd = "BALANCE", from = shopAddress, nonce = os.epoch("utc")}, true)
        if ok and data and data.balance then return data.balance end
    end
    return shopBalance   -- cached fallback
end

-- Register the shop address on all witness nodes so it appears in lookups.
function api.registerShop()
    local cfg = api.loadConfig()
    local name = (cfg.shop_name and #cfg.shop_name > 0) and cfg.shop_name or "AmiStore"
    for _, node in ipairs(cfg.nodes) do
        -- Fire-and-forget: registration needs no reply and must not block boot.
        meshSend(node.key, {cmd = "REGISTER", from = shopAddress, name = name}, false)
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
    if not p_modem then return false, nil, "No modem on BACK" end
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

-- Sweep sweep_pct% of a profit amount to the configured vault / player.
-- sweep_to (player name) takes precedence over vault_addr if DNS resolves.
local function sweepVault(profitMicro)
    local cfg = api.loadConfig()
    local amt = math.floor(profitMicro * (cfg.sweep_pct or 5) / 100)
    if amt < 1 then return end

    -- Resolve target address: sweep_to name first, then vault_addr fallback.
    local targetAddr = ""
    local targetNode = cfg.vault_node_key or ""

    if cfg.sweep_to and #cfg.sweep_to > 0 then
        local resolved = api.lookupName(cfg.sweep_to)
        if resolved then
            targetAddr = resolved
            -- Use the first node that resolved it (any node key will do for TRANSFER).
            if #targetNode < 32 and #cfg.nodes > 0 then
                targetNode = cfg.nodes[1].key
            end
        else
            log("WARN", "sweep", "DNS lookup failed for sweep_to='" .. cfg.sweep_to .. "' — sweep skipped")
            return
        end
    elseif cfg.vault_addr and #cfg.vault_addr >= 128 then
        targetAddr = cfg.vault_addr
    end

    if #targetAddr < 128 or #targetNode < 32 then return end

    meshSend(targetNode, {
        cmd    = "TRANSFER",
        from   = shopAddress,
        to     = targetAddr,
        amount = amt,
        nonce  = os.epoch("utc"),
    }, true)
end

-- ── Printer helpers ────────────────────────────────────────────────────────────
-- ASCII Ami-Head watermark for the bottom of receipts.
local AMI_HEAD = {
    "   .---.   ",
    "  (  o  )  ",
    "   `---'   ",
}

-- printReceipt fires-and-forgets: logs printer errors but never aborts the flow.
function api.printReceipt(txId, txType, itemName, qty, totalMicro, partyAddr)
    if not p_printer then
        log("WARN", "printer", "Printer offline — skipping receipt for tx " .. (txId or "?"))
        return
    end
    local ok, err = pcall(function()
        local started = p_printer.newPage()
        if not started then
            error("newPage() returned false (out of paper or ink?)")
        end
        p_printer.setPageTitle("AmiStore Receipt")
        local function wline(y, text)
            p_printer.setCursorPos(1, y); p_printer.write(text)
        end
        wline(1,  "--- AMICOIN OFFICIAL RECEIPT ---")
        wline(2,  "TX:   " .. (txId or "?"))
        wline(3,  "Type: " .. (txType or "?"))
        wline(4,  "Item: " .. (itemName or "?") .. "  x" .. (qty or 0))
        wline(5,  string.format("Amt:  %d uAMI  (%.4f AMI)", totalMicro, totalMicro / 1000000))
        wline(6,  "Party:" .. ((partyAddr or "?"):sub(1, 26)) .. "...")
        wline(7,  "--------------------------------")
        for i, line in ipairs(AMI_HEAD) do
            wline(7 + i, line)
        end
        p_printer.endPage()
    end)
    if not ok then
        log("ERROR", "printer",
            "Receipt failed for tx " .. (txId or "?") .. ": " .. tostring(err))
    end
end

-- ── Transaction pipeline ───────────────────────────────────────────────────────

-- WTS: Shop sells to buyer.  Called after witnessing payment arrival.
-- Returns ok (bool), errMsg (string or nil).
local function executeWTS(txId, listing, qty, buyerAddr)
    local totalPrice = listing.price * qty
    -- Witness: shop balance should have increased by totalPrice.
    local newBal = api.witnessBalance()
    if newBal < shopBalance + totalPrice then
        local msg = string.format(
            "Payment unconfirmed for tx %s (witnessed %d, need +%d)",
            txId, newBal, totalPrice)
        log("WARN", "pipeline", msg)
        return false, string.format("Payment unconfirmed (got %d, need +%d)", newBal, totalPrice)
    end
    shopBalance = newBal
    -- Vend from AE2 → tray.
    local ok, err = meExport(listing.item, qty)
    if not ok then
        log("ERROR", "ae2", "WTS export failed [" .. txId .. "]: " .. (err or "?"))
        return false, "AE2 export failed: " .. (err or "?")
    end
    log("INFO", "pipeline", string.format("WTS ok: %d x %s for %d uAMI [%s]",
        qty, listing.item, totalPrice, txId))
    sweepVault(totalPrice)
    api.printReceipt(txId, "WTS", listing.item, qty, totalPrice, buyerAddr)
    collectgarbage("collect")
    return true, nil
end

-- WTB: Shop buys from seller.  Item must already be in the tray.
local function executeWTB(txId, listing, qty, sellerAddr)
    local totalPrice = listing.price * qty
    -- Verify item is in tray.
    if trayCount(listing.item) < qty then
        return false, "Item not found in tray (place it in the BOTTOM inventory)"
    end
    -- Transfer µAMI to seller via mesh (uses cached config).
    local cfg   = api.loadConfig()
    local wNode = cfg.nodes[1]
    if not wNode then
        log("ERROR", "pipeline", "WTB aborted — no witness node in config [" .. txId .. "]")
        return false, "No witness node configured"
    end
    local ok, _, merr = meshSend(wNode.key, {
        cmd    = "TRANSFER",
        from   = shopAddress,
        to     = sellerAddr,
        amount = totalPrice,
        nonce  = os.epoch("utc"),
    }, true)
    if not ok then
        log("ERROR", "pipeline",
            "WTB transfer failed [" .. txId .. "]: " .. (merr or "?"))
        return false, "Transfer failed: " .. (merr or "?")
    end
    -- Import item into AE2 and log any failure (non-fatal — money already sent).
    local imp_ok, imp_err = meImport(listing.item)
    if not imp_ok then
        log("WARN", "ae2",
            "WTB AE2 import failed [" .. txId .. "]: " .. (imp_err or "?"))
    end
    log("INFO", "pipeline", string.format("WTB ok: %d x %s for %d uAMI [%s]",
        qty, listing.item, totalPrice, txId))
    sweepVault(totalPrice)
    api.printReceipt(txId, "WTB", listing.item, qty, totalPrice, sellerAddr)
    collectgarbage("collect")
    return true, nil
end

-- ── Incoming packet dispatch ───────────────────────────────────────────────────
-- Wire format: senderKeyHex|cipherhex  (identical to node/startup.lua)
-- replyCh: the modem reply channel from the modem_message event.
--
-- Returns an action table for startup.lua to act on, or nil.
-- Action types:
--   {type="QUOTE",   tx_id, item, qty, price, shop_addr}
--   {type="CONFIRM", tx_id, listing, order, preview=true}
--   {type="SELL",    tx_id, ok, err}
--   nil for fire-and-forget or parse failures
function api.processWire(wire, replyCh)
    if type(wire) ~= "string" then return nil end
    local sep = wire:find("|")
    if not sep then return nil end
    local senderKey = wire:sub(1, sep - 1)
    local cipher    = wire:sub(sep + 1)
    if #senderKey ~= 32 then return nil end
    local ok, plain = pcall(xtea.decrypt, cipher, senderKey)
    if not ok then return nil end
    local pkt = textutils.unserialiseJSON(plain)
    if type(pkt) ~= "table" then return nil end

    -- Reply helper: encrypts with shop key and sends back on replyCh.
    local function reply(tbl)
        if not p_modem or not replyCh then return end
        local enc = xtea.encrypt(textutils.serialiseJSON(tbl), shopKey)
        p_modem.transmit(replyCh, SHOP_CHANNEL, enc)
    end

    local cmd    = pkt.cmd
    local sender = pkt.from or ""

    -- ── SHOP_QUOTE: buyer asks for a price on a WTS item ─────────────────────
    if cmd == "SHOP_QUOTE" then
        local item = pkt.item or ""
        local qty  = math.max(1, math.floor(pkt.qty or 1))
        for _, l in ipairs(listings) do
            if l.item == item and l.type == "WTS" and (l._stock or 0) >= qty then
                local txId  = fnv1a(sender .. item .. tostring(qty)
                                    .. tostring(pkt.nonce or os.epoch("utc")))
                pendingOrders[txId] = {
                    item    = item,
                    qty     = qty,
                    price   = l.price,
                    listing = l,
                    buyer   = sender,
                    expires = os.epoch("utc") + ORDER_TTL,
                    type    = "WTS",
                }
                reply({ok = true, tx_id = txId,
                       price = l.price * qty, shop_addr = shopAddress})
                return {type = "QUOTE", tx_id = txId, item = item,
                        qty = qty, price = l.price * qty}
            end
        end
        reply({ok = false, err = "Item not listed or out of stock"})
        return nil

    -- ── SHOP_CONFIRM: buyer confirms they paid; show preview then vend ────────
    elseif cmd == "SHOP_CONFIRM" then
        local txId = pkt.tx_id
        local order = pendingOrders[txId]
        if not order or os.epoch("utc") > order.expires then
            reply({ok = false, err = "Order expired or not found"})
            return nil
        end
        -- Return action to startup.lua so it can show receipt preview first.
        return {
            type    = "CONFIRM",
            tx_id   = txId,
            order   = order,
            listing = order.listing,
            reply   = reply,   -- closure: startup.lua calls it after preview
            preview = true,
        }

    -- ── SHOP_SELL: seller wants to sell an item to the shop (WTB) ────────────
    elseif cmd == "SHOP_SELL" then
        local item = pkt.item or ""
        local qty  = math.max(1, math.floor(pkt.qty or 1))
        for _, l in ipairs(listings) do
            if l.item == item and l.type == "WTB" then
                local totalPrice = l.price * qty
                if (l._liquid or 0) < totalPrice then
                    reply({ok = false, err = "Shop has insufficient liquidity"})
                    return nil
                end
                local txId = fnv1a(sender .. item .. tostring(qty)
                                   .. tostring(pkt.nonce or os.epoch("utc")))
                local success, merr = executeWTB(txId, l, qty, sender)
                reply({ok = success, err = merr, tx_id = txId})
                return {type = "SELL", tx_id = txId, ok = success, err = merr}
            end
        end
        reply({ok = false, err = "Item not in WTB listings"})
        return nil

    -- ── SHOP_PING: discovery / health check ──────────────────────────────────
    elseif cmd == "SHOP_PING" then
        reply({ok = true, name = "AmiStore", addr = shopAddress, version = "1.1"})
        return nil
    end

    return nil
end

-- Called by startup.lua after showing the receipt preview on the monitor.
-- Executes the vend and sends the final reply to the buyer.
function api.executeConfirm(action)
    local order = action.order
    pendingOrders[action.tx_id] = nil   -- consume regardless
    local success, err = executeWTS(action.tx_id, action.listing, order.qty, order.buyer)
    if action.reply then
        action.reply({ok = success, err = err, tx_id = action.tx_id})
    end
    return success, err
end

-- ── Walk-up terminal buy (local handshake, no buyer pad needed) ───────────────
-- Drives the WTS pipeline on behalf of a walk-up player.
-- buyerAddr: 128-hex address the player typed in (or resolved from their name).
-- listing:   a WTS listing table.
-- qty:       integer quantity the player wants to buy.
--
-- Step 1  — records a pending order internally (same as SHOP_QUOTE).
-- Step 2  — waits for the operator to confirm payment arrived ([Y]/[N] prompt).
-- Step 3  — calls executeWTS to vend.
-- Returns ok (bool), txId or nil, errMsg or nil.
function api.localBuy(buyerAddr, listing, qty)
    if listing.type ~= "WTS" then return false, nil, "Not a WTS listing" end
    if (listing._stock or 0) < qty then return false, nil, "Out of stock" end

    local totalPrice = listing.price * qty
    local txId = fnv1a(buyerAddr .. listing.item
                       .. tostring(qty) .. tostring(os.epoch("utc")))
    pendingOrders[txId] = {
        item    = listing.item,
        qty     = qty,
        price   = listing.price,
        listing = listing,
        buyer   = buyerAddr,
        expires = os.epoch("utc") + ORDER_TTL,
        type    = "WTS",
    }
    return true, txId, totalPrice
end

-- Completes a walk-up buy after the operator confirms payment was sent.
function api.localBuyConfirm(txId)
    local order = pendingOrders[txId]
    if not order or os.epoch("utc") > order.expires then
        return false, "Order expired or not found"
    end
    pendingOrders[txId] = nil
    return executeWTS(txId, order.listing, order.qty, order.buyer)
end

-- Walk-up sell (WTB listing): records a pending order.
-- The seller places the item in the BOTTOM tray first, then operator confirms.
-- Returns ok (bool), txId or nil, totalPrice or nil.
function api.localSell(sellerAddr, listing, qty)
    if listing.type ~= "WTB" then return false, nil, "Not a WTB listing" end
    local totalPrice = listing.price * qty
    local txId = fnv1a(sellerAddr .. listing.item
                       .. tostring(qty) .. tostring(os.epoch("utc")))
    pendingOrders[txId] = {
        item    = listing.item,
        qty     = qty,
        price   = listing.price,
        listing = listing,
        seller  = sellerAddr,
        expires = os.epoch("utc") + ORDER_TTL,
        type    = "WTB",
    }
    return true, txId, totalPrice
end

-- Completes a walk-up sell after the operator confirms the item is in the tray.
function api.localSellConfirm(txId)
    local order = pendingOrders[txId]
    if not order or os.epoch("utc") > order.expires then
        return false, "Order expired or not found"
    end
    pendingOrders[txId] = nil
    return executeWTB(txId, order.listing, order.qty, order.seller)
end

-- ── Automated Invoice Push System ─────────────────────────────────────────────
-- Touch-to-buy flow: monitor touch → invoice broadcast → wallet pop-up →
-- player accepts → ledger confirms → item exported.  No operator Y/N prompt.
--
-- The INVOICE packet is plaintext JSON (not XTEA) because the shop does not
-- know the buyer's secret key.  Fields are all public data.
-- The PAYMENT_ACK from the wallet is also plaintext JSON.

local INVOICE_TTL    = 120000   -- 2 minutes (ms)
local pendingInvoice = nil      -- at most one active invoice at a time

-- Broadcast an invoice to a buyer's wallet.
-- Returns txId (string) or nil, errMsg.
function api.sendInvoice(buyerAddr, buyerName, listing, qty)
    if not p_modem then return nil, "No modem on BACK" end
    local total  = listing.price * qty
    local txId   = fnv1a(buyerAddr .. listing.item
                         .. tostring(qty) .. tostring(os.epoch("utc")))
    local cfg    = api.loadConfig()
    local packet = textutils.serialiseJSON({
        type      = "INVOICE",
        to        = buyerAddr,
        tx_id     = txId,
        shop_addr = shopAddress,
        shop_name = cfg.shop_name or "AmiStore",
        item      = listing.item,
        qty       = qty,
        price     = listing.price,
        total     = total,
        expires   = os.epoch("utc") + INVOICE_TTL,
    })
    p_modem.transmit(SHOP_CHANNEL, SHOP_CHANNEL, packet)
    pendingInvoice = {
        txId        = txId,
        buyerAddr   = buyerAddr,
        buyerName   = buyerName or buyerAddr:sub(1, 8),
        listing     = listing,
        item        = listing.item,
        qty         = qty,
        price       = listing.price,
        total       = total,
        expires     = os.epoch("utc") + INVOICE_TTL,
        balSnapshot = shopBalance,   -- balance before invoice; used to detect payment
    }
    log("INFO", "invoice", string.format("Invoice %s -> %s  %d x %s @ %d uAMI",
        txId:sub(1, 8), buyerName or buyerAddr:sub(1, 8), qty, listing.item, listing.price))
    return txId, nil
end

-- Cancel the active pending invoice; broadcasts INVOICE_CANCEL so the wallet
-- pop-up clears.
function api.cancelInvoice()
    if not pendingInvoice then return end
    if p_modem then
        local pkt = textutils.serialiseJSON({
            type  = "INVOICE_CANCEL",
            tx_id = pendingInvoice.txId,
        })
        p_modem.transmit(SHOP_CHANNEL, SHOP_CHANNEL, pkt)
    end
    log("INFO", "invoice", "Cancelled invoice " .. pendingInvoice.txId:sub(1, 8))
    pendingInvoice = nil
end

-- Returns the current pending invoice table, or nil.
function api.getPendingInvoice()
    if not pendingInvoice then return nil end
    if os.epoch("utc") > pendingInvoice.expires then
        pendingInvoice = nil
    end
    return pendingInvoice
end

-- Called by networkLoop when PAYMENT_ACK arrives for the active invoice.
-- Performs a ledger balance witness; only exports item if payment confirmed.
-- Returns ok (bool), errMsg (string or nil).
function api.executeInvoice(txId)
    local inv = pendingInvoice
    if not inv or inv.txId ~= txId then
        return false, "No matching pending invoice"
    end
    if os.epoch("utc") > inv.expires then
        pendingInvoice = nil
        return false, "Invoice expired"
    end
    -- Brief pause to let the node propagate the balance update.
    os.sleep(0.8)
    local newBal = api.witnessBalance()
    if newBal < inv.balSnapshot + inv.total then
        log("WARN", "invoice", string.format(
            "Balance check fail for %s: snapshot=%d new=%d required_gain=%d",
            txId:sub(1, 8), inv.balSnapshot, newBal, inv.total))
        return false, string.format(
            "Payment not confirmed (+%d received, need +%d)",
            newBal - inv.balSnapshot, inv.total)
    end
    pendingInvoice = nil
    shopBalance    = newBal
    return executeWTS(txId, inv.listing, inv.qty, inv.buyerAddr)
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

-- Prune expired invoice (call from syncLoop alongside prunePendingOrders).
function api.pruneInvoices()
    if pendingInvoice and os.epoch("utc") > pendingInvoice.expires then
        log("INFO", "invoice", "Expired: " .. pendingInvoice.txId:sub(1, 8))
        pendingInvoice = nil
    end
end

-- ── Accessors ─────────────────────────────────────────────────────────────────
function api.getMonitor()   return p_monitor  end
-- api.getShopKey() intentionally omitted — the secret key must not be exported.
function api.getShopAddr()  return shopAddress end
function api.getModem()     return p_modem    end
function api.getShopBal()   return shopBalance end

-- ── Init ──────────────────────────────────────────────────────────────────────
function api.init()
    math.randomseed(os.epoch("utc") + os.getComputerID())
    ensureDir(DATA_DIR)
    shopKey, shopAddress = loadOrCreateShopKey()

    -- Wrap peripherals by hardcoded side.
    p_monitor = peripheral.isPresent("top")    and peripheral.wrap("top")    or nil
    p_printer = peripheral.isPresent("left")   and peripheral.wrap("left")   or nil
    p_me      = peripheral.isPresent("right")  and peripheral.wrap("right")  or nil
    p_tray    = peripheral.isPresent("bottom") and peripheral.wrap("bottom") or nil
    p_modem   = peripheral.isPresent("back")   and peripheral.wrap("back")   or nil

    if p_modem then
        p_modem.open(SHOP_CHANNEL)
        p_modem.open(MESH_CHANNEL)
    end

    api.loadListings()
    -- Note: registerShop() and syncInventory() are called from startup.lua
    -- AFTER parallel coroutines start, to avoid blocking the boot sequence.
    return shopAddress
end

return api
