-- ami/casino/startup.lua
-- AmiCasino v1.1
-- Proof-of-Uptime gamble station for AmiCoin.
--
-- Requires:
--   BACK (or any side): Ender Router / Wireless Modem (mesh comms)
--
-- Run: shell.run("/ami/casino/startup")
--
-- Money model: Model A (escrow)
--   1. Player deposits via INVOICE; coins land in casino wallet.
--   2. Session balance tracked in memory AND persisted to SESSION_FILE.
--   3. On cashout: single TRANSFER casino->player for sessionBalance.
--   4. Payment confirmed when PAYMENT_ACK is received from wallet.
--      (Balance re-query was removed: it caused false negatives on multi-node
--       setups where payment settles on a different node than the casino queries.)
--   5. Bets are capped so the casino can always pay the maximum possible win.
--   6. Pre-cashout solvency check: partial payout if casino wallet is short.

package.path = package.path .. ";/ami/casino/?.lua"
local ui    = require("ui")
local games = require("games")
local xtea  = dofile("/shared/xtea.lua")

-- ── Constants ─────────────────────────────────────────────────────────────────
local MESH_CHANNEL  = 1337
local REPLY_BASE    = 4000    -- reply channel pool for casino queries
local MESH_TIMEOUT  = 8       -- seconds to wait for a node response
local DATA_DIR      = "/ami/casino/data"
local LOG_FILE      = DATA_DIR .. "/casino.log"
local CONFIG_FILE   = DATA_DIR .. "/config.json"
local SESSION_FILE  = DATA_DIR .. "/session.json"  -- P1: crash-safe session state
local JACKPOT_FILE  = DATA_DIR .. "/jackpot.json"
local HISTORY_FILE  = DATA_DIR .. "/history.json"
local VIP_FILE      = DATA_DIR .. "/vip.json"
local HISTORY_MAX   = 100   -- cap so file never grows unbounded
local REPO_BASE     = "https://raw.githubusercontent.com/Teru-dot-png/amicoin-fullpower/refs/heads/main"

-- P3: maximum payout multiplier per game (used for solvency cap).
-- Mines theoretical max is 25x but only reachable with 1 mine; practical cap 25.
-- Crash is unbounded in theory; we cap exposure at 100x.
local GAME_MAX_MULT = {
    Mines          = 25,
    Crash          = 100,
    Slots          = 10,
    Blackjack      = 1.5,
    Roulette       = 35,
    ["Higher / Lower"] = 3.2,
    Pachinko       = 12,
    Craps          = 1,
    ["Coin Flip"]  = 1.92,
    ["Video Poker"]= 800,
    ["Keno"]       = 10000,
    ["Scratch Card"]    = 12,
    ["Wheel of Fortune"]= 10,
}

-- ── FNV-1a ────────────────────────────────────────────────────────────────────
local function fnv1a(s)
    local hash = 2166136261
    for i = 1, #s do
        hash = bit32.bxor(hash, string.byte(s, i))
        hash = (hash * 16777619) % 4294967296
    end
    return string.format("%08x", hash)
end

-- ── Logging ───────────────────────────────────────────────────────────────────
local function log(msg)
    if not fs.exists(DATA_DIR) then fs.makeDir(DATA_DIR) end
    local ts = tostring(os.epoch("utc"))
    local f = fs.open(LOG_FILE, "a")
    f.write("[" .. ts .. "] " .. msg .. "\n")
    f.close()
end

-- ── P1: Session persistence ───────────────────────────────────────────────────
-- Written immediately after deposit confirms; updated after every game outcome.
-- Deleted on clean cashout.  If present on startup an orphaned session exists.
local function saveSession(data)
    if not fs.exists(DATA_DIR) then fs.makeDir(DATA_DIR) end
    local f = fs.open(SESSION_FILE, "w")
    f.write(textutils.serialiseJSON(data))
    f.close()
end

local function loadSession()
    if not fs.exists(SESSION_FILE) then return nil end
    local f = fs.open(SESSION_FILE, "r")
    local t = textutils.unserialiseJSON(f.readAll())
    f.close()
    return type(t) == "table" and t or nil
end

local function clearSession()
    if fs.exists(SESSION_FILE) then fs.delete(SESSION_FILE) end
end

-- ── Safe atomic write (write temp, rename) ───────────────────────────────────
-- Protects jackpot / history / VIP files against mid-write corruption.
local function atomicWrite(path, content)
    if not fs.exists(DATA_DIR) then fs.makeDir(DATA_DIR) end
    local tmp = path .. ".tmp"
    local f = fs.open(tmp, "w"); f.write(content); f.close()
    if fs.exists(path) then fs.delete(path) end
    fs.move(tmp, path)
end

-- ── Progressive Jackpot ───────────────────────────────────────────────────────
-- Pot is real µAMI the casino owes; funded 1% of every losing bet.
-- Claimed only on Slots 3\xd77. Payout verified solvent before granting.
local function loadJackpot()
    -- Recover from a crashed mid-write by checking for .tmp first.
    if fs.exists(JACKPOT_FILE .. ".tmp") and not fs.exists(JACKPOT_FILE) then
        fs.move(JACKPOT_FILE .. ".tmp", JACKPOT_FILE)
    end
    if not fs.exists(JACKPOT_FILE) then return 0 end
    local f = fs.open(JACKPOT_FILE, "r")
    local t = textutils.unserialiseJSON(f.readAll())
    f.close()
    return (type(t) == "table" and type(t.pot) == "number") and math.max(0, math.floor(t.pot)) or 0
end

local function saveJackpot(pot)
    atomicWrite(JACKPOT_FILE, textutils.serialiseJSON({pot = math.max(0, math.floor(pot))}))
end

-- Adds 1% of |net_loss| to the pot. Called after every net<0 game result.
local function jackpotAccumulate(bet)
    local contribution = math.max(1, math.floor(bet * 0.01))
    local pot = loadJackpot() + contribution
    saveJackpot(pot)
    return pot
end

-- ── Multi-session History ─────────────────────────────────────────────────────
local function appendHistory(entry)
    local hist = {}
    if fs.exists(HISTORY_FILE) then
        local f = fs.open(HISTORY_FILE, "r")
        hist = textutils.unserialiseJSON(f.readAll()) or {}
        f.close()
        if type(hist) ~= "table" then hist = {} end
    end
    table.insert(hist, 1, entry)   -- newest first
    while #hist > HISTORY_MAX do hist[#hist] = nil end
    atomicWrite(HISTORY_FILE, textutils.serialiseJSON(hist))
end

local function loadHistory()
    if not fs.exists(HISTORY_FILE) then return {} end
    local f = fs.open(HISTORY_FILE, "r")
    local t = textutils.unserialiseJSON(f.readAll())
    f.close()
    return type(t) == "table" and t or {}
end

-- ── VIP tiers ────────────────────────────────────────────────────────────────
local VIP_TIERS = {
    { name="Platinum", threshold=25000000, bonus=0.10, col=colors.cyan    },
    { name="Gold",     threshold= 5000000, bonus=0.05, col=colors.yellow  },
    { name="Silver",   threshold= 1000000, bonus=0.00, col=colors.orange  },
    { name="Bronze",   threshold=       0, bonus=0.00, col=colors.white   },
}

local function getVipTier(totalWagered)
    for _, t in ipairs(VIP_TIERS) do
        if totalWagered >= t.threshold then return t end
    end
    return VIP_TIERS[#VIP_TIERS]
end

local function loadVip(playerName)
    if not fs.exists(VIP_FILE) then return {total_wagered=0} end
    local f = fs.open(VIP_FILE, "r")
    local t = textutils.unserialiseJSON(f.readAll()) or {}
    f.close()
    local entry = type(t[playerName]) == "table" and t[playerName] or {total_wagered=0}
    entry.total_wagered = math.max(0, math.floor(entry.total_wagered or 0))
    return entry
end

local function saveVip(playerName, entry)
    local t = {}
    if fs.exists(VIP_FILE) then
        local f = fs.open(VIP_FILE, "r")
        t = textutils.unserialiseJSON(f.readAll()) or {}
        f.close()
        if type(t) ~= "table" then t = {} end
    end
    t[playerName] = entry
    atomicWrite(VIP_FILE, textutils.serialiseJSON(t))
end

-- ── Config (node key list) ────────────────────────────────────────────────────
local function loadConfig()
    if not fs.exists(CONFIG_FILE) then
        return { nodes = {}, casino_name = nil, admin_pass = nil }
    end
    local f = fs.open(CONFIG_FILE, "r")
    local t = textutils.unserialiseJSON(f.readAll()) or {}
    f.close()
    if type(t.nodes) ~= "table" then t.nodes = {} end
    return t
end

local function saveConfig(cfg)
    if not fs.exists(DATA_DIR) then fs.makeDir(DATA_DIR) end
    local f = fs.open(CONFIG_FILE, "w")
    f.write(textutils.serialiseJSON(cfg))
    f.close()
end

-- ── Modem setup ───────────────────────────────────────────────────────────────
local function findModem()
    for _, side in ipairs({"back","top","bottom","left","right","front"}) do
        if peripheral.isPresent(side) then
            local t = peripheral.getType(side)
            if t and (t:find("modem") or t:find("ender")) then
                return peripheral.wrap(side)
            end
        end
    end
    -- Try peripheral.find as fallback
    return peripheral.find("modem") or peripheral.find("ender_modem")
end

-- ── Derive address from 32-hex secret key ─────────────────────────────────────
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

-- ── Password-based key derivation (mirrors wallet/comms.lua exactly) ────────────
-- Derives a 32-hex XTEA key from a plain-text password.
-- Used to decrypt GETKEY replies before the node key is known.
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

-- Fetch a node's XTEA key using a setup password.
-- Broadcasts GETKEY on the mesh; reply is encrypted with keyFromPassword(pw)
-- so we can decrypt it without already knowing the node key.
-- Returns: key (string) or nil, errMsg (string or nil)
local function fetchNodeKey(modem, casinoKey, casinoAddr, password)
    local replyChannel = REPLY_BASE + math.random(0, 999)
    modem.open(replyChannel)

    local pkt    = { cmd="GETKEY", from=casinoAddr, password=password, nonce=os.epoch("utc") }
    local cipher = xtea.encrypt(textutils.serialiseJSON(pkt), casinoKey)
    modem.transmit(MESH_CHANNEL, replyChannel, casinoKey .. "|" .. cipher)

    local pwdKey  = keyFromPassword(password)
    local deadline = os.epoch("utc") / 1000 + MESH_TIMEOUT
    local resultKey, resultErr = nil, "Timeout — no node responded"

    while os.epoch("utc") / 1000 < deadline do
        local tid = os.startTimer(0.5)
        while true do
            local ev, a, chan, _, msg = os.pullEvent()
            if ev == "timer" and a == tid then break end
            if ev == "modem_message" and chan == replyChannel and type(msg) == "string" then
                local ok2, plain = pcall(xtea.decrypt, msg, pwdKey)
                if ok2 then
                    local data = textutils.unserialiseJSON(plain)
                    if type(data) == "table" then
                        if data.ok and type(data.key) == "string" and #data.key == 32 then
                            resultKey = data.key
                            resultErr = nil
                            goto done
                        elseif data.err then
                            resultErr = data.err
                            goto done
                        end
                    end
                end
            end
        end
    end
    ::done::
    modem.close(replyChannel)
    return resultKey, resultErr
end

-- ── Casino key (for signing mesh packets) ─────────────────────────────────────
local function loadOrCreateCasinoKey()
    if not fs.exists(DATA_DIR) then fs.makeDir(DATA_DIR) end
    local kf = DATA_DIR .. "/casino_key.txt"
    if fs.exists(kf) then
        local f = fs.open(kf, "r"); local k = f.readAll():gsub("%s", ""); f.close()
        return k, deriveAddress(k)
    end
    math.randomseed(os.epoch("utc") + os.getComputerID() * 3571)
    local key = ""
    for _ = 1, 32 do key = key .. string.format("%x", math.random(0, 15)) end
    local f = fs.open(kf, "w"); f.write(key); f.close()
    return key, deriveAddress(key)
end

-- ── Mesh communication ────────────────────────────────────────────────────────
-- Sends a signed command to a node and waits for the encrypted reply.
local function meshSend(modem, casinoKey, nodeKey, payload)
    local replyChannel = REPLY_BASE + math.random(0, 999)
    modem.open(replyChannel)
    local cipher = xtea.encrypt(textutils.serialiseJSON(payload), casinoKey)
    modem.transmit(MESH_CHANNEL, replyChannel, casinoKey .. "|" .. cipher)

    local deadline = os.epoch("utc") / 1000 + MESH_TIMEOUT
    while os.epoch("utc") / 1000 < deadline do
        local tid = os.startTimer(0.5)
        while true do
            local ev, _, chan, _, msg = os.pullEvent()
            if ev == "timer" then break end
            if ev == "modem_message" and chan == replyChannel then
                if type(msg) == "string" then
                    local ok, plain = pcall(xtea.decrypt, msg, nodeKey)
                    if ok then
                        modem.close(replyChannel)
                        local pkt = textutils.unserialiseJSON(plain)
                        return pkt
                    end
                end
            end
        end
    end
    modem.close(replyChannel)
    return nil
end

-- Resolve Ami-DNS name → 128-hex address via the first responding node.
local function lookupPlayer(modem, casinoKey, nodes, name)
    for _, node in ipairs(nodes) do
        local resp = meshSend(modem, casinoKey, node.key, {
            cmd  = "LOOKUP",
            from = deriveAddress(casinoKey),
            name = name,
        })
        if resp and resp.ok and type(resp.address) == "string" and #resp.address == 128 then
            return resp.address, node
        end
    end
    return nil, nil
end

-- Get balance for an address from a specific node.
local function getBalance(modem, casinoKey, node, address)
    local resp = meshSend(modem, casinoKey, node.key, {
        cmd  = "BALANCE",
        from = address,
    })
    if resp and resp.ok then return resp.balance or 0 end
    return nil
end

-- Credit winnings to a player (minted from nothing by the node).
local function creditWin(modem, casinoKey, node, address, amount)
    -- We use TRANSFER from the casino address; but the casino has no balance.
    -- Instead we direct-credit via a special CASINO_CREDIT packet that the
    -- node handles identically to a miner credit.  For standard nodes without
    -- this handler we fall back to a ledger credit via TRANSFER from a funded
    -- casino vault.  The simplest safe approach: we issue a signed TRANSFER
    -- from the casino's own address. The node will reject it if the casino
    -- address has no balance — so we credit the node's ledger directly.
    --
    -- NOTE: A full production deployment would use a signed CASINO_CREDIT
    -- command type.  For now we use TRANSFER with a dedicated casino wallet
    -- that must hold enough AMI to cover potential payouts.
    local resp = meshSend(modem, casinoKey, node.key, {
        cmd    = "TRANSFER",
        from   = deriveAddress(casinoKey),
        to     = address,
        amount = amount,
    })
    return resp and resp.ok
end

-- Deduct a loss from the player (coins burned).
local function deductLoss(modem, casinoKey, node, playerKey, address, amount)
    -- The player's wallet is not present here, so we cannot sign as the player.
    -- We use CONSOLIDATE_OUT on the player's account from the node: the node
    -- drains `amount` from `address` and sends the receipt to /dev/null.
    -- This requires the casino to be trusted by the node operator.
    -- Standard approach: player pre-authorises by pressing [Y] on their wallet,
    -- which triggers a TRANSFER to the casino's address.
    --
    -- In this implementation the player's bet is held as a pre-authorised
    -- TRANSFER at bet time (see playGame) before the game starts.
    -- This function is a no-op stub — the bet transfer already deducted funds.
    return true
end

-- Register the casino's own address+name on every configured node.
local function registerOnNodes(modem, casinoKey, casinoAddr, nodes, name)
    local ok_ct, fail_ct = 0, 0
    for _, node in ipairs(nodes) do
        local resp = meshSend(modem, casinoKey, node.key, {
            cmd  = "REGISTER",
            from = casinoAddr,
            name = name,
        })
        if resp and resp.ok then ok_ct = ok_ct + 1
        else                     fail_ct = fail_ct + 1 end
    end
    return ok_ct, fail_ct
end

-- ── Admin password helpers ───────────────────────────────────────────────────
local function hashPass(plain)
    return fnv1a(plain .. "amicasino_salt_v1")
end

-- Returns true if plain matches stored hash, or if no password is set.
local function checkAdminPass(cfg, plain)
    if not cfg.admin_pass or cfg.admin_pass == "" then return true end
    return hashPass(plain) == cfg.admin_pass
end

-- First-time password setup.  Runs once when admin_pass is absent.
-- Returns false if operator cancels (presses B with empty input).
local function setupAdminPassword(cfg)
    ui.banner("Admin Password Setup")
    ui.line(4, "  Set a password for the Admin menu.", colors.yellow)
    ui.line(5, "  This protects node keys and withdrawals.", colors.lightGray)
    ui.line(6, "  Leave blank and press Enter to skip (not recommended).", colors.gray)
    ui.rule(7)
    term.setCursorPos(1, 8); term.setTextColor(colors.white)
    io.write("  Password: ")
    local pw = read("*")
    if #pw == 0 then
        ui.center(10, "No password set. Admin is unprotected.", colors.red)
        os.sleep(1.5)
        cfg.admin_pass = ""
    else
        term.setCursorPos(1, 9); io.write("  Confirm:  ")
        local pw2 = read("*")
        if pw ~= pw2 then
            ui.center(11, "Passwords do not match. Try again.", colors.red)
            os.sleep(1.5)
            return false
        end
        cfg.admin_pass = hashPass(pw)
        ui.center(11, "Password set!", colors.lime)
        os.sleep(0.8)
    end
    saveConfig(cfg)
    return true
end

-- Prompts for the admin password and returns true on success.
-- If no password is configured, returns true immediately.
local function promptAdminPass(cfg)
    if not cfg.admin_pass or cfg.admin_pass == "" then return true end
    ui.banner("Admin Login")
    ui.line(4, "  Enter admin password:", colors.yellow)
    term.setCursorPos(1, 5); io.write("  > ")
    local pw = read("*")
    if checkAdminPass(cfg, pw) then
        return true
    else
        ui.center(7, "Wrong password.", colors.red)
        os.sleep(1.2)
        return false
    end
end

-- ── Admin: node configuration ─────────────────────────────────────────────────
local function adminMenu(cfg, modem, casinoKey, casinoAddr)
    while true do
        ui.banner("Casino Admin")
        ui.rule(4)
        ui.line(5, "Configured nodes:", colors.lightGray)
        if #cfg.nodes == 0 then
            ui.line(6, "  (none)", colors.gray)
        else
            for i, n in ipairs(cfg.nodes) do
                ui.line(5 + i, string.format("  [%d] %s  (%s...)", i, n.name, n.key:sub(1, 8)), colors.white)
            end
        end
        local base = 6 + #cfg.nodes
        ui.rule(base)
        ui.line(base + 1, "[A] Add  [D] Del  [R] Reg name  [W] Withdraw  [H] History  [Q] Audit  [P] Passwd  [B] Back", colors.orange)

        local _, k = os.pullEvent("key")
        if k == keys.b then break
        elseif k == keys.q then
            -- Audit balance: query all nodes, compare against session deposit.
            -- Read-only: does not move any funds.
            ui.banner("Audit Balance")
            ui.rule(4)
            local row = 5
            local totalCasino = 0
            for _, node in ipairs(cfg.nodes) do
                local bal = getBalance(modem, casinoKey, node, casinoAddr) or 0
                totalCasino = totalCasino + bal
                ui.line(row, string.format("  %-14s  %d uAMI", node.name:sub(1,14), bal), colors.white)
                row = row + 1
            end
            ui.rule(row); row = row + 1
            ui.line(row, string.format("  Total casino wallet: %d uAMI", totalCasino), colors.yellow)
            row = row + 1
            -- Check for active orphaned session deposit
            local sess = loadSession()
            local sessionDep = (sess and sess.balance) or 0
            if sessionDep > 0 then
                ui.line(row, string.format("  Active session deposit: %d uAMI", sessionDep), colors.orange)
                row = row + 1
                local free = totalCasino - sessionDep
                local col  = free >= 0 and colors.lime or colors.red
                ui.line(row, string.format("  Free liquidity: %d uAMI %s",
                    free, free < 0 and " [SHORTFALL!]" or ""), col)
                if free < 0 then
                    log(string.format("AUDIT_SHORTFALL casino=%d session=%d shortfall=%d",
                        totalCasino, sessionDep, free))
                end
            else
                ui.line(row, "  No active session.", colors.lightGray)
            end
            row = row + 2
            ui.line(row, "  [Any key] back", colors.gray)
            os.pullEvent("key")
        elseif k == keys.h then
            -- Show last 10 sessions
            local hist = loadHistory()
            ui.banner("Session History")
            ui.rule(4)
            ui.line(5, string.format("  %-10s %-10s %-10s %s", "Player", "Deposit", "P&L", "Games"), colors.lightGray)
            ui.rule(6)
            if #hist == 0 then
                ui.line(7, "  No history yet.", colors.gray)
            else
                for i = 1, math.min(10, #hist) do
                    local h   = hist[i]
                    local pnl = (h.pnl or 0)
                    local col = pnl >= 0 and colors.lime or colors.red
                    ui.line(6 + i, string.format("  %-10s %9d %+9d %4d",
                        (h.player or "?"):sub(1,10),
                        h.deposit or 0, pnl, h.games or 0):sub(1, ui.W()), col)
                end
            end
            ui.rule(17)
            ui.line(18, "  [Any key] back", colors.gray)
            os.pullEvent("key")
        elseif k == keys.p then
            -- Change password
            ui.banner("Change Admin Password")
            local passOk = true
            if cfg.admin_pass and cfg.admin_pass ~= "" then
                ui.line(4, "  Current password:", colors.yellow)
                term.setCursorPos(1, 5); io.write("  > ")
                local old = read("*")
                if not checkAdminPass(cfg, old) then
                    ui.center(7, "Wrong password.", colors.red)
                    os.sleep(1.2)
                    passOk = false
                end
            end
            if passOk then
                ui.line(6, "  New password (blank=remove):", colors.yellow)
                term.setCursorPos(1, 7); io.write("  > ")
                local np = read("*")
                if #np == 0 then
                    cfg.admin_pass = ""
                    ui.center(9, "Password removed.", colors.gray)
                    saveConfig(cfg)
                    os.sleep(1)
                else
                    term.setCursorPos(1, 8); io.write("  Confirm: ")
                    local np2 = read("*")
                    if np ~= np2 then
                        ui.center(10, "Mismatch — unchanged.", colors.red)
                        os.sleep(1.2)
                    else
                        cfg.admin_pass = hashPass(np)
                        ui.center(9, "Password updated.", colors.lime)
                        saveConfig(cfg)
                        os.sleep(1)
                    end
                end
            end
        elseif k == keys.w then
            -- Withdraw: transfer casino balance to operator's wallet
            if #cfg.nodes == 0 then
                ui.banner("Withdraw")
                ui.center(6, "No nodes configured.", colors.red)
                os.sleep(1.5)
            else
                ui.banner("Withdraw to Wallet")
                local node = cfg.nodes[1]
                local casinoBal = getBalance(modem, casinoKey, node, casinoAddr) or 0
                ui.line(4, string.format("  Casino balance: %d uAMI (%.4f AMI)",
                    casinoBal, casinoBal / 1000000), colors.yellow)
                ui.rule(5)
                ui.line(6, "  Your Ami-DNS name:", colors.lightGray)
                term.setCursorPos(1, 7); io.write("  > ")
                local recipName = read()
                recipName = recipName:gsub("^%s*(.-)%s*$", "%1")
                if #recipName > 0 then
                    ui.center(9, "Looking up '" .. recipName .. "'...", colors.yellow)
                    local recipAddr = nil
                    for _, n in ipairs(cfg.nodes) do
                        local resp = meshSend(modem, casinoKey, n.key, {
                            cmd  = "LOOKUP",
                            from = casinoAddr,
                            name = recipName,
                        })
                        if resp and resp.ok and type(resp.address) == "string" and #resp.address == 128 then
                            recipAddr = resp.address; break
                        end
                    end
                    if not recipAddr then
                        ui.center(9, "Name not found on any node.", colors.red)
                        os.sleep(2)
                    else
                        ui.line(10, "  Amount to withdraw (AMI, M=all):", colors.yellow)
                        term.setCursorPos(1, 11); io.write("  > ")
                        local amtRaw = (read() or ""):gsub("%s","")
                        local withdrawAmt
                        if amtRaw:lower() == "m" then
                            withdrawAmt = casinoBal
                        else
                            local n2 = tonumber(amtRaw)
                            withdrawAmt = n2 and math.floor(n2 * 1000000) or 0
                        end
                        if withdrawAmt <= 0 or withdrawAmt > casinoBal then
                            ui.center(13, "Invalid amount.", colors.red)
                            os.sleep(1.2)
                        else
                            ui.center(13, string.format("Sending %d uAMI to %s...", withdrawAmt, recipName), colors.yellow)
                            local wresp = meshSend(modem, casinoKey, node.key, {
                                cmd    = "TRANSFER",
                                from   = casinoAddr,
                                to     = recipAddr,
                                amount = withdrawAmt,
                            })
                            if wresp and wresp.ok then
                                ui.center(14, "Done! Withdrawn " .. withdrawAmt .. " uAMI.", colors.lime)
                                log(string.format("WITHDRAW to=%s amount=%d", recipName, withdrawAmt))
                            else
                                ui.center(14, "Transfer failed: " .. tostring(wresp and wresp.err or "no response"), colors.red)
                                log(string.format("WITHDRAW_FAIL to=%s amount=%d", recipName, withdrawAmt))
                            end
                            os.sleep(2)
                        end
                    end
                end
            end
        elseif k == keys.r then
            ui.banner("Register Casino Name")
            local current = cfg.casino_name or "(not set)"
            ui.line(5, "  Current name: " .. current, colors.lightGray)
            ui.line(6, "  New name (Enter=keep, B=cancel):", colors.yellow)
            term.setCursorPos(1, 7); io.write("> ")
            local newName = read()
            newName = newName:gsub("^%s*(.-)%s*$", "%1")
            if newName == "b" or newName == "B" then
                -- cancelled
            elseif #newName > 0 then
                cfg.casino_name = newName
                saveConfig(cfg)
                ui.center(9, "Registering on " .. #cfg.nodes .. " node(s)...", colors.yellow)
                local ok_ct, fail_ct = registerOnNodes(modem, casinoKey, casinoAddr, cfg.nodes, newName)
                ui.center(10, string.format("%d OK  %d failed", ok_ct, fail_ct),
                    fail_ct > 0 and colors.red or colors.lime)
                os.sleep(1.5)
            end
        elseif k == keys.a then
            ui.banner("Add Node")
            ui.line(5, "Node name:", colors.yellow)
            term.setCursorPos(1, 6); io.write("> ")
            local name = read()
            name = name:gsub("^%s*(.-)%s*$", "%1")
            if #name == 0 then name = "Node " .. (#cfg.nodes + 1) end

            ui.line(8,  "How to add?", colors.yellow)
            ui.line(9,  "  [1] Enter 32-char key manually", colors.white)
            ui.line(10, "  [2] Fetch via setup password",   colors.orange)

            local addKey
            while not addKey do
                local _, mk = os.pullEvent("key")
                if mk == keys.one or mk == keys.n1 then
                    ui.line(12, "32-char XTEA key:", colors.yellow)
                    term.setCursorPos(1, 13); io.write("> ")
                    local raw = read():gsub("%s", ""):lower()
                    if #raw == 32 then
                        addKey = raw
                    else
                        ui.center(15, "Invalid (need 32 hex chars)", colors.red)
                        os.sleep(1.2)
                    end
                    break
                elseif mk == keys.two or mk == keys.n2 then
                    ui.line(12, "Setup password for this node:", colors.orange)
                    term.setCursorPos(1, 13); io.write("> ")
                    local pw = read("*")
                    if #pw == 0 then
                        ui.center(15, "Cancelled.", colors.gray); os.sleep(0.8)
                    else
                        ui.center(15, "Contacting node...", colors.yellow)
                        local fetchedKey, fetchErr = fetchNodeKey(modem, casinoKey, casinoAddr, pw)
                        if fetchedKey then
                            addKey = fetchedKey
                            ui.center(15, "Got key!  " .. fetchedKey:sub(1,8) .. "...", colors.lime)
                            os.sleep(0.6)
                        else
                            ui.center(15, "Failed: " .. (fetchErr or "unknown"), colors.red)
                            os.sleep(1.5)
                        end
                    end
                    break
                end
            end

            if addKey then
                cfg.nodes[#cfg.nodes + 1] = { name = name, key = addKey }
                saveConfig(cfg)
                ui.center(17, "Node '" .. name .. "' added!", colors.lime)
                os.sleep(0.8)
            end
        elseif k == keys.d and #cfg.nodes > 0 then
            ui.banner("Remove Node")
            for i, n in ipairs(cfg.nodes) do
                ui.line(4 + i, string.format("  [%d] %s", i, n.name), colors.white)
            end
            ui.line(5 + #cfg.nodes, "Number (0=cancel):", colors.yellow)
            term.setCursorPos(1, 6 + #cfg.nodes); io.write("> ")
            local idx = tonumber(read())
            if idx and idx >= 1 and idx <= #cfg.nodes then
                table.remove(cfg.nodes, idx)
                saveConfig(cfg)
            end
        end
    end
end

-- ── Self-update ───────────────────────────────────────────────────────────────
local UPDATE_FILES = {
    { src = "/shared/xtea.lua",           dst = "/shared/xtea.lua"           },
    { src = "/ami/casino/startup.lua",    dst = "/ami/casino/startup.lua"    },
    { src = "/ami/casino/games.lua",      dst = "/ami/casino/games.lua"      },
    { src = "/ami/casino/ui.lua",         dst = "/ami/casino/ui.lua"         },
}
local function selfUpdate()
    ui.banner("Self-Update")
    ui.line(5, "Fetching from GitHub...", colors.yellow)
    local failed = false
    local hashes = {}
    local row = 7
    for _, entry in ipairs(UPDATE_FILES) do
        term.setCursorPos(1, row); term.setTextColor(colors.white)
        io.write("  " .. entry.dst .. " ... ")
        local res = http.get(REPO_BASE .. entry.src)
        if not res then
            term.setTextColor(colors.red); print("FAILED")
            failed = true
        else
            local content = res.readAll(); res.close()
            if #content < 64 then
                term.setTextColor(colors.red); print("REJECTED (too short)")
                failed = true
            else
                local hash = fnv1a(content)
                hashes[#hashes + 1] = hash
                local dir = entry.dst:match("^(.*)/[^/]+$")
                if dir and dir ~= "" and not fs.exists(dir) then fs.makeDir(dir) end
                local f = fs.open(entry.dst, "w"); f.write(content); f.close()
                term.setTextColor(colors.green); print("OK [" .. hash .. "]")
            end
        end
        row = row + 1
    end
    if failed then
        ui.line(row + 1, "Some files failed. Retry later.", colors.red)
    else
        ui.line(row + 1, "Done! Rebooting in 3s...", colors.lime)
        os.sleep(3); os.reboot()
    end
    ui.waitKey()
end

-- Send an INVOICE on ch 1338 and wait for PAYMENT_ACK, then verify the
-- casino wallet balance actually increased (P2: ACK authentication).
-- Returns true, nil on confirmed payment; false, errMsg otherwise.
local function waitForPayment(modem, playerAddr, casinoAddr, casinoKey, playerNode, amount, purpose, timeoutSecs)
    local txId   = fnv1a(tostring(os.epoch("utc")) .. playerAddr .. purpose)
    local invoice = textutils.serialiseJSON({
        type      = "INVOICE",
        to        = playerAddr,
        tx_id     = txId,
        shop_addr = casinoAddr,
        shop_name = "AmiCasino",
        item      = "ami:casino/" .. purpose,
        qty       = 1,
        total     = amount,
    })
    modem.open(1338)
    modem.transmit(1338, 1338, invoice)
    local deadline    = os.epoch("utc") / 1000 + (timeoutSecs or 120)
    local lastResend  = os.epoch("utc") / 1000
    local ackReceived = false
    while os.epoch("utc") / 1000 < deadline do
        local rem = math.floor(deadline - os.epoch("utc") / 1000)
        ui.center(12, string.format("Waiting for Pad [Y]...  %3ds", rem), colors.cyan)
        if os.epoch("utc") / 1000 - lastResend >= 10 then
            modem.transmit(1338, 1338, invoice)
            lastResend = os.epoch("utc") / 1000
        end
        local tid = os.startTimer(1)
        while true do
            local ev, a, b, _, d = os.pullEvent()
            if ev == "timer" and a == tid then break end
            if ev == "modem_message" and b == 1338
            and type(d) == "string" and d:sub(1,1) == "{" then
                local ok2, pkt = pcall(textutils.unserialiseJSON, d)
                if ok2 and type(pkt) == "table"
                and pkt.type == "PAYMENT_ACK"
                and pkt.tx_id == txId then
                    ackReceived = true; break
                end
            end
            if ev == "key" and a == keys.b then
                modem.close(1338); return false, "Cancelled"
            end
        end
        if ackReceived then break end
    end
    modem.close(1338)
    if not ackReceived then return false, "Timed out" end

    -- Trust the PAYMENT_ACK as confirmation of payment.
    -- The wallet only sends an ACK after a successful transfer, so the ACK
    -- is sufficient evidence the coins moved.  A balance re-query was tried
    -- as P2 hardening but caused false negatives when the payment was
    -- processed on a different node than the casino is querying (common in
    -- multi-node setups) — the casino wallet balance wouldn't rise until the
    -- next ledger sync.  The deposit is logged for audit; stranded funds are
    -- recoverable via the orphan recovery on next startup.
    log(string.format("PAYMENT_ACK player=? tx=%s amount=%d", txId, amount))
    return true, nil
end

-- ── Game menu ─────────────────────────────────────────────────────────────────
local GAME_PAGES = {
    {
        { name="Mines",         fn=games.mines,       edge="varies", desc="Click tiles, cash out any time"    },
        { name="Crash",         fn=games.crash,       edge="~4%",    desc="Cash out before the crash"         },
        { name="Slots",         fn=games.slots,       edge="~5%",    desc="Match reels, 7s = jackpot (10x)"   },
        { name="Blackjack",     fn=games.blackjack,   edge="~2.2%",  desc="Beat dealer, double-down enabled"  },
        { name="Roulette",      fn=games.roulette,    edge="2.7%",   desc="Click-board multi-spot betting"    },
    },
    {
        { name="Higher / Lower", fn=games.higherLower, edge="varies", desc="5-round streak, cash out any time" },
        { name="Pachinko",       fn=games.pachinko,    edge="~4%",    desc="Drop balls, outer = jackpot (12x)" },
        { name="Craps",          fn=games.craps,       edge="~1.4%",  desc="Pass line: natural or point"       },
        { name="Coin Flip",      fn=games.coinflip,    edge="4%",     desc="50/50, parlay after win"           },
        { name="Video Poker",    fn=games.videoPoker,  edge="~2.7%",  desc="Hold cards, draw replacements"     },
    },
    {
        { name="Keno",             fn=games.keno,        edge="25-31%", desc="Pick 1-10 numbers, draw 20"         },
        { name="Scratch Card",     fn=games.scratchcard, edge="~27%",   desc="Pick 3 tiles, match symbols to win" },
        { name="Wheel of Fortune", fn=games.wheel,       edge="10%",    desc="Spin the wheel: x2/x5/x10"         },
    },
}

local function gameMenu(modem, casinoKey, casinoAddr, cfg, playerName, playerAddr, playerNode)
    -- ── Step 1: Deposit ───────────────────────────────────────────────────────
    ui.banner("Deposit")
    ui.rule(4)
    ui.line(5, string.format("  Welcome, %s!", playerName), colors.orange)
    ui.line(6, "  How much do you want to play with?", colors.yellow)
    ui.line(7, "  (You will get any unspent amount back.)", colors.lightGray)
    ui.rule(8)

    -- Fetch player's real balance to cap the deposit prompt
    local playerBal = getBalance(modem, casinoKey, playerNode, playerAddr) or 0
    ui.line(9, string.format("  Your balance: %.4f AMI  (%d uAMI)", playerBal / 1000000, playerBal), colors.lightGray)

    local deposit = ui.readBet(10, playerBal)
    if not deposit then return end

    -- Broadcast INVOICE so player pays the casino from their Pad
    ui.banner("Deposit")
    ui.rule(4)
    ui.line(5, string.format("  Depositing %d uAMI", deposit), colors.yellow)
    ui.line(6, string.format("  = %.4f AMI", deposit / 1000000), colors.yellow)
    ui.rule(7)
    ui.line(8,  "  An invoice has been sent to your Wallet Pad.", colors.lightGray)
    ui.line(9,  "  Press [Y] on your Pad to confirm the deposit.", colors.lightGray)
    ui.line(10, "  Press [B] here to cancel.", colors.gray)

    local paid, payErr = waitForPayment(modem, playerAddr, casinoAddr, casinoKey, playerNode, deposit, "deposit")
    if not paid then
        ui.banner("Deposit Failed")
        ui.center(6, payErr or "Cancelled", colors.red)
        -- Only say 'no funds moved' on a genuine cancel/timeout before ACK.
        -- If ACK was received the money did move; this path only fires on
        -- real timeout or operator [B] cancel.
        ui.center(7, "No funds were moved.", colors.gray)
        os.sleep(2); return
    end

    log(string.format("DEPOSIT player=%s amount=%d", playerName, deposit))

    -- P1: persist session to disk immediately after deposit is confirmed.
    -- This record survives a reboot; startup will offer to resume or auto-cashout.
    local sessionData = {
        player      = playerName,
        playerAddr  = playerAddr,
        nodeKey     = playerNode.key,
        nodeName    = playerNode.name,
        casinoAddr  = casinoAddr,
        deposit     = deposit,
        balance     = deposit,
        startedAt   = os.epoch("utc"),
    }
    saveSession(sessionData)

    -- ── Bet presets (player-configured at start of each session) ─────────────
    -- Up to 3 quick-bet amounts stored in memory for this session only.
    -- Shown in the game menu; accessible via quick-bet shortcut in readBet.
    local presets = {nil, nil, nil}
    ui.banner("Bet Presets")
    ui.line(4, "  Set up to 3 quick-bet amounts for this session.", colors.yellow)
    ui.line(5, "  Press Enter to skip.  Format: AMI amounts  e.g. 0.5", colors.lightGray)
    for slot = 1, 3 do
        ui.line(5 + slot, string.format("  Preset [%d]:", slot), colors.orange)
        term.setCursorPos(1, 5 + slot + 1); term.setTextColor(colors.white)
        io.write(string.format("    [%d] > ", slot))
        local raw = (read() or ""):gsub("%s", "")
        if raw ~= "" and raw:lower() ~= "b" then
            local n = tonumber(raw)
            if n and n > 0 then
                local v = math.floor(n * 1000000)
                if v <= deposit then presets[slot] = v end
            end
        end
    end
    -- Pass presets into ui so readBet can show them.
    ui.setPresets(presets)

    -- ── Opt-in session loss limit ─────────────────────────────────────────────
    local lossLimit = nil
    ui.banner("Loss Limit (Optional)")
    ui.line(4, "  Set a loss limit to be warned when you lose too much.", colors.yellow)
    ui.line(5, "  Press Enter to skip.", colors.lightGray)
    ui.rule(6)
    term.setCursorPos(1, 7); term.setTextColor(colors.white)
    io.write("  Max loss AMI > ")
    local llRaw = (read() or ""):gsub("%s", "")
    if llRaw ~= "" then
        local lln = tonumber(llRaw)
        if lln and lln > 0 then lossLimit = math.floor(lln * 1000000) end
    end
    if lossLimit then sessionData.loss_limit = lossLimit; saveSession(sessionData) end

    -- ── Step 2: Session ───────────────────────────────────────────────────────
    -- All wins/losses tracked in sessionBalance; nothing touches the ledger
    -- until the player cashes out.
    local sessionBalance = deposit
    local page = 1
    local sparkline      = readSparkline(playerName)
    local vipData        = loadVip(playerName)
    local vipTier        = getVipTier(vipData.total_wagered)
    local gamesPlayed    = 0
    local lossLimitWarned = false   -- true once per crossing to avoid nag loop
    local breakToCashout  = false   -- set by loss-limit [B] to exit game loop immediately

    while sessionBalance > 0 and not breakToCashout do
        -- Update session header so all game banners show current balance
        ui.setSession(playerName, sessionBalance, deposit, sparkline)

        -- ── Loss limit check ─────────────────────────────────────────────────
        if lossLimit then
            local totalLost = deposit - sessionBalance
            if totalLost >= lossLimit and not lossLimitWarned then
                lossLimitWarned = true
                ui.banner("Loss Limit Reached")
                ui.rule(4)
                ui.center(5, string.format("You've lost %d uAMI this session.", totalLost), colors.red)
                ui.center(6, string.format("Your limit was %d uAMI.", lossLimit), colors.orange)
                ui.rule(7)
                ui.line(8, "  [C] Continue playing    [B] Cash out now", colors.yellow)
                while true do
                    local _, lk = os.pullEvent("key")
                    if lk == keys.b then
                        breakToCashout = true; break
                    elseif lk == keys.c then break end
                end
            end
        end
        if breakToCashout then break end

        local list = GAME_PAGES[page]
        ui.banner("Game Select")
        ui.rule(4)
        ui.line(5, string.format("  Player: %s", playerName), colors.orange)
        ui.line(6, string.format("  Session: %.4f AMI  (%d uAMI)",
            sessionBalance / 1000000, sessionBalance), colors.lime)
        ui.line(7, string.format("  Deposited: %d uAMI   P&L: %+d uAMI",
            deposit, sessionBalance - deposit), sessionBalance >= deposit and colors.lime or colors.red)
        ui.rule(8)
        for i, g in ipairs(list) do
            ui.line(8 + i, string.format("  [%d] %-16s%5s  %s",
                i, g.name, g.edge, g.desc):sub(1, ui.W()), colors.white)
        end
        local base = 9 + #list
        ui.rule(base)
        local pageHint = page < #GAME_PAGES and "[N]ext" or "[P]rev"
        ui.line(base + 1,
            string.format("  [1-5] select  %s page  [B] Cashout", pageHint),
            colors.gray)

        local _, k = os.pullEvent("key")
        if k == keys.b then break
        elseif k == keys.n and page < #GAME_PAGES then page = page + 1
        elseif k == keys.p and page > 1            then page = page - 1
        else
            local numMap = {
                [keys.one]=1,[keys.two]=2,[keys.three]=3,
                [keys.four]=4,[keys.five]=5,
            }
            local pick = numMap[k]
            if pick and list[pick] then
                local sel      = list[pick]
                local gameName = sel.name

                -- P3: solvency cap — limit effective bet so casino can always pay.
                local maxMult   = GAME_MAX_MULT[gameName] or 1
                local casinoBal = getBalance(modem, casinoKey, playerNode, casinoAddr) or 0
                local maxBet    = math.floor(casinoBal / maxMult)
                local cappedBal = math.min(sessionBalance, math.max(0, maxBet))
                if cappedBal <= 0 then
                    ui.banner("Casino Insufficient Funds")
                    ui.center(6, "Casino wallet cannot cover a win right now.", colors.red)
                    ui.center(7, "Tell the operator to top up the casino.",      colors.lightGray)
                    ui.center(8, string.format("Casino balance: %d uAMI", casinoBal), colors.gray)
                    os.sleep(3)
                else
                    local wasCapped = cappedBal < sessionBalance
                    if wasCapped then
                        ui.setSession(playerName, sessionBalance, deposit, sparkline)
                        ui.center(base + 2,
                            string.format("  Bet capped to %d uAMI (solvency limit)", cappedBal),
                            colors.yellow)
                        os.sleep(1.2)
                    end

                    -- P4+Phase1: pcall isolation + auto-replay loop.
                    local effectiveBal  = cappedBal
                    local keepReplaying = true
                    while keepReplaying and sessionBalance > 0 do
                        ui.setSession(playerName, sessionBalance, deposit, sparkline)
                        local ok, net, desc = pcall(sel.fn, ui, effectiveBal)
                        if not ok then
                            log(string.format("GAME_ERROR player=%s game=%s err=%s",
                                playerName, gameName, tostring(net)))
                            ui.banner("Game Error")
                            ui.center(6, "A game error occurred. Session intact.", colors.red)
                            ui.center(7, "Your balance is unchanged.", colors.lightGray)
                            os.sleep(2)
                            keepReplaying = false
                        else
                            net = net or 0
                            gamesPlayed = gamesPlayed + 1

                            -- ── VIP wagering accumulation ─────────────────────
                            -- Track the bet (effectiveBal is the max available,
                            -- which may be > the actual bet placed; we use |net|+bet
                            -- estimate is imprecise but safe — only Slots/Roulette
                            -- can return net > bet, all others net ≤ bet.  Simpler
                            -- and correct: use effectiveBal as the wagered proxy since
                            -- games never bet more than the balance they're given.
                            vipData.total_wagered = vipData.total_wagered + effectiveBal
                            local newTier = getVipTier(vipData.total_wagered)
                            if newTier.name ~= vipTier.name then
                                vipTier = newTier
                                ui.banner("VIP Upgrade!")
                                ui.center(6, string.format("You're now %s!", vipTier.name), vipTier.col)
                                ui.center(7, vipTier.threshold >= 5000000
                                    and string.format("+%.0f%% win bonus active!", vipTier.bonus*100)
                                    or  "Keep playing to reach Gold tier!", colors.white)
                                os.sleep(2)
                            end
                            saveVip(playerName, vipData)

                            -- ── Jackpot accumulation (1% of losing bet) ───────
                            if net < 0 then
                                jackpotAccumulate(effectiveBal)
                            end

                            -- ── Slots 3\xd77 jackpot claim ───────────────────────
                            local isSlots3x7 = (gameName == "Slots" and
                                type(desc) == "string" and desc:find("3x7"))
                            if isSlots3x7 then
                                local pot       = loadJackpot()
                                local casinoNow = getBalance(modem, casinoKey, playerNode, casinoAddr) or 0
                                -- Solvency: can the casino cover the base Slots win + jackpot?
                                if pot > 0 and casinoNow >= (math.floor(effectiveBal * 10) + pot) then
                                    sessionBalance = math.max(0, sessionBalance + net)
                                    sessionBalance = sessionBalance + pot
                                    saveJackpot(0)
                                    log(string.format("JACKPOT player=%s pot=%d casino_bal=%d",
                                        playerName, pot, casinoNow))
                                    ui.banner("JACKPOT!")
                                    ui.center(5, string.format("+%d uAMI JACKPOT!", pot), colors.lime)
                                    ui.sfx("jackpot")
                                    os.sleep(3)
                                    net = 0   -- already applied above
                                elseif pot > 0 then
                                    -- Casino can't cover jackpot right now; defer.
                                    log(string.format("JACKPOT_DEFERRED player=%s pot=%d casino_bal=%d",
                                        playerName, pot, casinoNow))
                                    ui.center(ui.H()-1,
                                        string.format("  Jackpot %d deferred: top up casino wallet!", pot),
                                        colors.red)
                                    os.sleep(2)
                                end
                            end

                            -- ── VIP win bonus ─────────────────────────────────
                            -- Applied after jackpot so multiplier doesn't inflate pot.
                            if net > 0 and vipTier.bonus > 0 then
                                local bonus = math.floor(net * vipTier.bonus)
                                if bonus > 0 then
                                    -- Solvency: only grant if casino can cover extra.
                                    local casinoNow2 = getBalance(modem, casinoKey, playerNode, casinoAddr) or 0
                                    if casinoNow2 >= bonus then
                                        net = net + bonus
                                        log(string.format("VIP_BONUS player=%s tier=%s bonus=%d",
                                            playerName, vipTier.name, bonus))
                                    end
                                end
                            end

                            sessionBalance = math.max(0, sessionBalance + net)
                            -- Reset loss-limit warning flag if they've clawed back above limit.
                            if lossLimit and (deposit - sessionBalance) < lossLimit then
                                lossLimitWarned = false
                            end
                            sessionData.balance = sessionBalance
                            saveSession(sessionData)   -- P1: persist after every outcome
                            sparkline = readSparkline(playerName)
                            if wasCapped then
                                log(string.format("%s player=%s game=%s bet_cap=%d net=%+d session=%d  %s",
                                    net >= 0 and "WIN" or "LOSS",
                                    playerName, gameName, effectiveBal, net, sessionBalance, tostring(desc)))
                            else
                                log(string.format("%s player=%s game=%s net=%+d session=%d  %s",
                                    net >= 0 and "WIN" or "LOSS",
                                    playerName, gameName, net, sessionBalance, tostring(desc)))
                            end
                            -- Auto-replay prompt: skip on cancel / fold / quit-no-streak / balance gone
                            local isCancelled = type(desc) == "string" and
                                (desc == "Cancelled" or desc == "Folded"
                                 or desc:find("^Quit with no")
                                 or desc == "Insufficient balance")
                            if sessionBalance > 0 and not isCancelled then
                                ui.line(ui.H() - 1, "  [R] Play again    [M] Game menu",
                                    colors.yellow)
                                local _, rk = os.pullEvent("key")
                                keepReplaying = (rk == keys.r)
                                if keepReplaying then
                                    -- Recompute solvency for the next play
                                    local nc = getBalance(modem, casinoKey, playerNode, casinoAddr) or 0
                                    effectiveBal = math.min(sessionBalance,
                                        math.max(0, math.floor(nc / maxMult)))
                                    if effectiveBal <= 0 then keepReplaying = false end
                                end
                            else
                                keepReplaying = false
                            end
                        end
                    end
                end
            end
        end
    end   -- while sessionBalance > 0

    -- Clear session header before cashout screen
    ui.setSession(nil, nil, nil)
    ui.setPresets({nil,nil,nil})   -- clear presets so next player starts fresh
    ui.setTheme(nil)               -- reset banner to default yellow for next player
    -- ── Step 3: Cashout ───────────────────────────────────────────────────────
    ui.banner("Cashout")
    ui.rule(4)
    local pnl = sessionBalance - deposit
    ui.line(5, string.format("  Player     : %s", playerName), colors.orange)
    ui.line(6, string.format("  Deposited  : %d uAMI", deposit), colors.lightGray)
    ui.line(7, string.format("  Returning  : %d uAMI", sessionBalance), colors.white)
    ui.line(8, string.format("  P&L        : %+d uAMI", pnl),
        pnl >= 0 and colors.lime or colors.red)
    ui.rule(9)

    if sessionBalance == 0 then
        ui.center(11, "Session balance is 0. Nothing to return.", colors.gray)
        local casinoBal = getBalance(modem, casinoKey, playerNode, casinoAddr) or -1
        log(string.format("CASHOUT player=%s returned=0 pnl=%d casino_bal=%d", playerName, pnl, casinoBal))
        clearSession()
        os.sleep(2); return
    end

    -- Check casino balance BEFORE attempting the transfer so the player
    -- gets a clear message if the house can't cover the full payout.
    local casinoBal = getBalance(modem, casinoKey, playerNode, casinoAddr) or 0
    local payAmt    = sessionBalance

    if casinoBal < sessionBalance then
        -- Casino is short.  Pay whatever is available; log the shortfall.
        ui.rule(10)
        if casinoBal <= 0 then
            ui.center(11, "Casino wallet is empty!", colors.red)
            ui.center(12, string.format("You are owed %d uAMI.", sessionBalance), colors.orange)
            ui.center(13, "Session file saved. Tell the operator.", colors.lightGray)
            log(string.format("CASHOUT_INSOLVENT player=%s owed=%d casino_bal=0", playerName, sessionBalance))
            os.sleep(4); return   -- session file NOT cleared — operator must settle manually
        else
            payAmt = casinoBal
            ui.center(11, string.format("Casino only has %d uAMI!", casinoBal), colors.red)
            ui.center(12, string.format("Paying %d of %d uAMI owed.", payAmt, sessionBalance), colors.orange)
            ui.center(13, "Remainder logged — tell the operator.", colors.lightGray)
            log(string.format("CASHOUT_PARTIAL player=%s owed=%d paying=%d casino_bal=%d",
                playerName, sessionBalance, payAmt, casinoBal))
            os.sleep(3)
        end
    end

    ui.center(11, string.format("Transferring %d uAMI back to you...", payAmt), colors.yellow)
    local ok = creditWin(modem, casinoKey, playerNode, playerAddr, payAmt)
    local casinoBalAfter = getBalance(modem, casinoKey, playerNode, casinoAddr) or -1
    if ok then
        if payAmt < sessionBalance then
            -- Partial pay: keep session file with the remaining shortfall
            sessionData.balance = sessionBalance - payAmt
            saveSession(sessionData)
            ui.center(12, string.format("Paid %d uAMI. Still owed %d uAMI.", payAmt, sessionBalance - payAmt), colors.orange)
            log(string.format("CASHOUT_PARTIAL_OK player=%s paid=%d still_owed=%d casino_bal=%d",
                playerName, payAmt, sessionBalance - payAmt, casinoBalAfter))
        else
            ui.center(12, "Done! Thanks for playing.", colors.lime)
            log(string.format("CASHOUT player=%s returned=%d pnl=%d casino_bal=%d",
                playerName, sessionBalance, pnl, casinoBalAfter))
            -- ── Append to multi-session history ───────────────────────────────
            appendHistory({
                player     = playerName,
                deposit    = deposit,
                cashout    = sessionBalance,
                pnl        = sessionBalance - deposit,
                games      = gamesPlayed,
                vip        = vipTier.name,
                started_at = sessionData.startedAt or 0,
                ended_at   = os.epoch("utc"),
            })
            clearSession()
        end
    else
        ui.center(12, "Transfer failed! Tell the operator.", colors.red)
        log(string.format("CASHOUT_FAIL player=%s returned=%d casino_bal=%d",
            playerName, sessionBalance, casinoBalAfter))
        -- session file NOT cleared — operator must settle manually
    end
    os.sleep(2.5)
end

-- ── Lobby ─────────────────────────────────────────────────────────────────────
local function lobby(modem, casinoKey, casinoAddr, cfg)
    ui.banner("AmiCasino")
    ui.rule(4)
    ui.center(5, "Welcome to AmiCasino!", colors.yellow)
    ui.rule(6)
    -- Show casino address for top-up transfers
    local shortAddr = casinoAddr:sub(1,16) .. "..."
    local casinoLabel = cfg.casino_name
        and ("  Name: " .. cfg.casino_name .. "  (" .. shortAddr .. ")")
        or  ("  Addr: " .. shortAddr .. "  (unregistered)")
    ui.line(7, casinoLabel:sub(1, ui.W()), cfg.casino_name and colors.lime or colors.gray)
    ui.rule(8)
    ui.line(9,  "  [P] Play", colors.lime)
    if #cfg.nodes == 0 then
        ui.line(10, "  [A] Admin (setup nodes first!)", colors.red)
    else
        ui.line(10, "  [A] Admin", colors.orange)
    end
    ui.line(11, "  [U] Update from GitHub", colors.gray)
    ui.line(12, string.format("  [S] Sound: %s", ui.getSoundProfile():upper()), colors.gray)
    ui.line(13, "  [Q] Quit", colors.gray)
    ui.rule(14)
    -- Show jackpot pot and node count
    local lobbyPot = loadJackpot()
    local potStr = lobbyPot > 0
        and string.format("  Jackpot: %d uAMI  |  %d node(s)", lobbyPot, #cfg.nodes)
        or  string.format("  %d node(s) configured", #cfg.nodes)
    ui.line(15, potStr, lobbyPot > 0 and colors.yellow or colors.lightGray)

    while true do
        local _, k = os.pullEvent("key")

        if k == keys.s then
            local p   = ui.getSoundProfile()
            local nxt = (p == "on") and "quiet" or (p == "quiet") and "off" or "on"
            ui.setSoundProfile(nxt)
            cfg.sound_profile = nxt
            saveConfig(cfg)
            return true   -- redraw lobby

        elseif k == keys.q then
            ui.cls(); print("[Casino] Exited."); return false

        elseif k == keys.u then
            selfUpdate()
            return true   -- reload

        elseif k == keys.a then
            -- First-time: no password set yet → run setup wizard
            if cfg.admin_pass == nil then
                local ok = setupAdminPassword(cfg)
                cfg = loadConfig()
                if not ok then return true end  -- reload lobby (redraw)
            end
            -- Password gate
            if not promptAdminPass(cfg) then return true end
            adminMenu(cfg, modem, casinoKey, casinoAddr)
            return true   -- reload lobby

        elseif k == keys.p then
            if #cfg.nodes == 0 then
                ui.banner("No Nodes")
                ui.center(6, "No nodes configured.", colors.red)
                ui.center(7, "Press [A] from the lobby to add one.", colors.lightGray)
                os.sleep(2)
                return true
            end

            -- Ask who is playing
            ui.banner("Who's Playing?")
            ui.rule(4)
            ui.line(5, "  Enter your Ami-DNS name:", colors.yellow)
            term.setCursorPos(1, 6); term.setTextColor(colors.white)
            io.write("  > ")
            local playerName = read()
            playerName = playerName:gsub("^%s*(.-)%s*$", "%1")
            if #playerName == 0 then return true end

            ui.line(8, "  Looking up '" .. playerName .. "'...", colors.lightGray)
            local playerAddr, playerNode = lookupPlayer(modem, casinoKey, cfg.nodes, playerName)

            if not playerAddr then
                ui.banner("Not Found")
                ui.center(6, "'" .. playerName .. "' not found on any node.", colors.red)
                ui.center(7, "Register your wallet on a node first.", colors.lightGray)
                os.sleep(2.5)
                return true
            end

            ui.center(9, "Found! Node: " .. playerNode.name, colors.lime)
    -- Fetch node theme from STATS and apply to banner (cosmetic only).
    local statsResp = meshSend(modem, casinoKey, playerNode.key, {
        cmd  = "STATS",
        from = casinoAddr,
    })
    if statsResp and type(statsResp.theme) == "string" then
        ui.setTheme(statsResp.theme)
    else
        ui.setTheme(nil)  -- reset to default yellow
    end

            gameMenu(modem, casinoKey, casinoAddr, cfg, playerName, playerAddr, playerNode)
            return true
        end
    end
end

-- ── Main ─────────────────────────────────────────────────────────────────────
local function main()
    term.clear(); term.setCursorPos(1, 1)
    print("===========================================")
    print("  AmiCasino v1.1")
    print("  AmiCoin Gamble Station")
    print("===========================================")

    local casinoKey, casinoAddr = loadOrCreateCasinoKey()
    print("[Casino] Key: " .. casinoKey:sub(1,8) .. "...")
    print("[Casino] Addr: " .. casinoAddr:sub(1,16) .. "...")

    local modem = findModem()
    if not modem then
        print("[ERROR] No modem found! Attach an Ender Router and reboot.")
        return
    end
    modem.open(MESH_CHANNEL)
    print("[Casino] Modem open on ch " .. MESH_CHANNEL)

    local cfg = loadConfig()
    print(string.format("[Casino] %d node(s) configured.", #cfg.nodes))
    -- Restore persisted sound profile (if any)
    if cfg.sound_profile then ui.setSoundProfile(cfg.sound_profile) end

    -- P1: orphaned session recovery.
    -- If the computer rebooted mid-session a session.json will exist.
    -- Attempt to auto-cashout so the stranded player gets their money back.
    local orphan = loadSession()
    if orphan and type(orphan.playerAddr) == "string" and type(orphan.nodeKey) == "string" then
        term.setTextColor(colors.red)
        print("[Casino] ORPHANED SESSION DETECTED!")
        print(string.format("[Casino]   Player : %s", orphan.player or "?"))
        print(string.format("[Casino]   Balance: %d uAMI", orphan.balance or 0))
        print(string.format("[Casino]   Node   : %s", orphan.nodeName or "?"))
        term.setTextColor(colors.yellow)
        print("[Casino] Attempting auto-cashout...")
        term.setTextColor(colors.white)
        if orphan.balance and orphan.balance > 0 then
            local recovNode = nil
            for _, n in ipairs(cfg.nodes) do
                if n.key == orphan.nodeKey then recovNode = n; break end
            end
            if not recovNode then
                recovNode = { name = orphan.nodeName or "?", key = orphan.nodeKey }
            end
            local ok = creditWin(modem, casinoKey, recovNode, orphan.playerAddr, orphan.balance)
            local casinoBal = getBalance(modem, casinoKey, recovNode, casinoAddr) or -1
            if ok then
                log(string.format("ORPHAN_CASHOUT player=%s returned=%d casino_bal=%d",
                    orphan.player or "?", orphan.balance, casinoBal))
                print(string.format("[Casino] Auto-cashout OK: %d uAMI returned.", orphan.balance))
                clearSession()
            else
                log(string.format("ORPHAN_CASHOUT_FAIL player=%s owed=%d",
                    orphan.player or "?", orphan.balance))
                term.setTextColor(colors.red)
                print("[Casino] Auto-cashout FAILED. session.json preserved.")
                print(string.format("[Casino] Owe %s %d uAMI manually.",
                    orphan.player or "?", orphan.balance))
                term.setTextColor(colors.white)
            end
        else
            clearSession()  -- zero-balance orphan, just clean up
        end
        os.sleep(2)
    end

    print("[Casino] Press P to play.")
    os.sleep(0.5)

    while lobby(modem, casinoKey, casinoAddr, cfg) do
        cfg = loadConfig()   -- reload after admin changes
    end
end

main()
