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
--   4. Deposit verified by checking casino wallet balance actually rose.
--   5. Bets are capped so the casino can always pay the maximum possible win.

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

-- ── Config (node key list) ────────────────────────────────────────────────────
local function loadConfig()
    if not fs.exists(CONFIG_FILE) then
        return { nodes = {}, casino_name = nil }
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
        ui.line(base + 1, "[A] Add node  [D] Delete  [R] Register name  [B] Back", colors.orange)

        local _, k = os.pullEvent("key")
        if k == keys.b then break
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

    -- P2: verify the deposit actually landed in the casino wallet.
    -- The ACK is plaintext and spoofable; the balance check is authoritative.
    ui.center(12, "Verifying payment on ledger...", colors.yellow)
    local balBefore = getBalance(modem, casinoKey, playerNode, casinoAddr) or 0
    local verified  = false
    local vdeadline = os.epoch("utc") / 1000 + 6   -- up to 6s for ledger propagation
    while os.epoch("utc") / 1000 < vdeadline do
        local bal = getBalance(modem, casinoKey, playerNode, casinoAddr) or 0
        if bal >= balBefore + amount then
            verified = true; break
        end
        os.sleep(0.5)
    end
    if not verified then
        return false, "ACK received but payment not confirmed on ledger"
    end
    return true, nil
end

-- ── Game menu ─────────────────────────────────────────────────────────────────
local GAME_PAGES = {
    {
        { name = "Mines",          fn = games.mines       },
        { name = "Crash",          fn = games.crash       },
        { name = "Slots",          fn = games.slots       },
        { name = "Blackjack",      fn = games.blackjack   },
        { name = "Roulette",       fn = games.roulette    },
    },
    {
        { name = "Higher / Lower", fn = games.higherLower },
        { name = "Pachinko",       fn = games.pachinko    },
        { name = "Craps",          fn = games.craps       },
        { name = "Coin Flip",      fn = games.coinflip    },
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
        ui.banner("Deposit Cancelled")
        ui.center(6, payErr or "Cancelled", colors.red)
        ui.center(7, "No funds moved.", colors.gray)
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

    -- ── Step 2: Session ───────────────────────────────────────────────────────
    -- All wins/losses tracked in sessionBalance; nothing touches the ledger
    -- until the player cashes out.
    local sessionBalance = deposit
    local page = 1

    while sessionBalance > 0 do
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
            ui.line(8 + i, string.format("  [%d] %s", i, g.name), colors.white)
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
                local gameName = list[pick].name

                -- P3: solvency cap — limit effective bet so casino can always pay.
                local maxMult    = GAME_MAX_MULT[gameName] or 1
                local casinoBal  = getBalance(modem, casinoKey, playerNode, casinoAddr) or 0
                local maxBet     = math.floor(casinoBal / maxMult)
                local cappedBal  = math.min(sessionBalance, math.max(0, maxBet))
                if cappedBal <= 0 then
                    ui.banner("Casino Insufficient Funds")
                    ui.center(6, "Casino wallet cannot cover a win right now.", colors.red)
                    ui.center(7, "Tell the operator to top up the casino.",      colors.lightGray)
                    ui.center(8, string.format("Casino balance: %d uAMI", casinoBal), colors.gray)
                    os.sleep(3)
                elseif cappedBal < sessionBalance then
                    ui.center(base + 2,
                        string.format("  Bet capped to %d uAMI (solvency limit)", cappedBal),
                        colors.yellow)
                    os.sleep(1.2)
                    -- P4: pcall isolation — a crash in any game returns to menu
                    local ok, net, desc = pcall(list[pick].fn, ui, cappedBal)
                    if not ok then
                        log(string.format("GAME_ERROR player=%s game=%s err=%s", playerName, gameName, tostring(net)))
                        ui.banner("Game Error")
                        ui.center(6, "A game error occurred. Session intact.", colors.red)
                        ui.center(7, "Your balance is unchanged.", colors.lightGray)
                        os.sleep(2)
                    else
                        net = net or 0
                        sessionBalance = sessionBalance + net
                        if sessionBalance < 0 then sessionBalance = 0 end
                        sessionData.balance = sessionBalance
                        saveSession(sessionData)   -- P1: persist after every outcome
                        log(string.format("%s player=%s game=%s bet_cap=%d net=%+d session=%d  %s",
                            net >= 0 and "WIN" or "LOSS",
                            playerName, gameName, cappedBal, net, sessionBalance, tostring(desc)))
                    end
                else
                    -- P4: pcall isolation — a crash in any game returns to menu
                    local ok, net, desc = pcall(list[pick].fn, ui, sessionBalance)
                    if not ok then
                        log(string.format("GAME_ERROR player=%s game=%s err=%s", playerName, gameName, tostring(net)))
                        ui.banner("Game Error")
                        ui.center(6, "A game error occurred. Session intact.", colors.red)
                        ui.center(7, "Your balance is unchanged.", colors.lightGray)
                        os.sleep(2)
                    else
                        net = net or 0
                        sessionBalance = sessionBalance + net
                        if sessionBalance < 0 then sessionBalance = 0 end
                        sessionData.balance = sessionBalance
                        saveSession(sessionData)   -- P1: persist after every outcome
                        log(string.format("%s player=%s game=%s net=%+d session=%d  %s",
                            net >= 0 and "WIN" or "LOSS",
                            playerName, gameName, net, sessionBalance, tostring(desc)))
                    end
                end
            end
        end
    end

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
        -- P5: log casino wallet balance at cashout
        local casinoBal = getBalance(modem, casinoKey, playerNode, casinoAddr) or -1
        log(string.format("CASHOUT player=%s returned=0 pnl=%d casino_bal=%d", playerName, pnl, casinoBal))
        clearSession()   -- P1: clean up session file
        os.sleep(2); return
    end

    ui.center(11, string.format("Transferring %d uAMI back to you...", sessionBalance), colors.yellow)
    local ok = creditWin(modem, casinoKey, playerNode, playerAddr, sessionBalance)
    -- P5: snapshot casino balance after cashout for audit log
    local casinoBalAfter = getBalance(modem, casinoKey, playerNode, casinoAddr) or -1
    if ok then
        ui.center(12, "Done! Thanks for playing.", colors.lime)
        log(string.format("CASHOUT player=%s returned=%d pnl=%d casino_bal=%d",
            playerName, sessionBalance, pnl, casinoBalAfter))
        clearSession()   -- P1: clean up session file on successful cashout
    else
        ui.center(12, "Transfer failed! Tell the operator.", colors.red)
        log(string.format("CASHOUT_FAIL player=%s returned=%d casino_bal=%d",
            playerName, sessionBalance, casinoBalAfter))
        -- P1: session file intentionally NOT cleared on failed cashout
        -- so the operator can manually inspect and recover the amount owed
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
    ui.line(12, "  [Q] Quit", colors.gray)
    ui.rule(13)
    ui.line(14, string.format("  %d node(s) configured", #cfg.nodes), colors.lightGray)

    while true do
        local _, k = os.pullEvent("key")

        if k == keys.q then
            ui.cls(); print("[Casino] Exited."); return false

        elseif k == keys.u then
            selfUpdate()
            return true   -- reload

        elseif k == keys.a then
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
            os.sleep(0.6)

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
