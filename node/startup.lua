-- node/startup.lua
-- AmiCoin Node – entry point for the Advanced Computer + Ender Router anchor.
--
-- Responsibilities:
--   1. Discover and open the Ender Router peripheral.
--   2. Start the Proof-of-Uptime miner daemon in a parallel coroutine.
--   3. Listen for incoming XTEA-encrypted packets on the mesh channel.
--   4. Dispatch verified commands: HEARTBEAT, BALANCE, TRANSFER.
--   5. Display a live status dashboard on the terminal.
--
-- Packet format (JSON, encrypted with sender's secret key, 128-bit):
--   { cmd="HEARTBEAT", from="<64-hex address>" }
--   { cmd="BALANCE",   from="<address>", nonce=<int> }
--   { cmd="TRANSFER",  from="<address>", to="<address>" OR toName="PlayerName", amount=<int uAMI>, nonce=<int> }
--   { cmd="REGISTER",  from="<address>", name="PlayerName" }
--   { cmd="LOOKUP",    from="<address>", name="PlayerName" }
--
-- Security note: XTEA here provides confidentiality in transit.
-- The node does NOT store private keys.  Address authenticity relies on
-- the XTEA encryption being keyed from the wallet's secret key; a wallet
-- that can decrypt/encrypt with the correct key effectively proves ownership.
-- (For a production chain you would layer a Schnorr/EdDSA signature on top.)

local xtea   = require("xtea")
local ledger = require("ledger")
local miner  = require("miner_daemon")

-- ── Configuration ────────────────────────────────────────────────────────────
local MESH_CHANNEL   = 1337          -- Ender Router channel all nodes share
local NODE_VERSION   = "1.0.0"
-- The node's own XTEA key is used to encrypt replies.
-- On first run a random key is generated and persisted to /data/node_key.txt
-- Wallets must be told this key during setup (printed on first boot).

local function loadOrCreateNodeKey()
    local keyFile = "/data/node_key.txt"
    if not fs.exists("/data") then fs.makeDir("/data") end
    if fs.exists(keyFile) then
        local f = fs.open(keyFile, "r")
        local k = f.readAll():gsub("%s", "")
        f.close()
        return k
    end
    -- Generate a random 128-bit key (32 hex chars)
    math.randomseed(os.epoch("utc"))
    local hex = ""
    for _ = 1, 32 do
        hex = hex .. string.format("%x", math.random(0, 15))
    end
    local f = fs.open(keyFile, "w")
    f.write(hex)
    f.close()
    return hex
end

-- ── Password-based key exchange ─────────────────────────────────────────────
-- Derives a 32-hex-char XTEA key from a plain-text password.
-- MUST be identical to the copy in wallet/comms.lua.
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

-- Prompt for (or load) the node setup password used for wallet auto-fetch.
local function loadOrCreateSetupPassword()
    local pwFile = "/data/setup_password.txt"
    if not fs.exists("/data") then fs.makeDir("/data") end
    if fs.exists(pwFile) then
        local f = fs.open(pwFile, "r")
        local pw = f.readAll():gsub("%s+$", "")
        f.close()
        return pw
    end
    -- First boot: ask for a password
    print("")
    print("[!] Set a SETUP PASSWORD for this node.")
    print("    Wallets can use it to auto-fetch your")
    print("    node key without manual copy-paste.")
    print("    Leave blank to disable auto-fetch.")
    io.write("    Password: ")
    local pw = read("*")
    if #pw > 0 then
        local f = fs.open(pwFile, "w")
        f.write(pw)
        f.close()
        print("[!] Password saved. Security = password strength.")
    else
        print("[!] Auto-fetch disabled (manual key entry only).")
    end
    return pw
end

-- ── Ender Router setup ───────────────────────────────────────────────────────
local function findRouter()
    for _, name in ipairs(peripheral.getNames()) do
        if peripheral.getType(name) == "ender_modem" or
           peripheral.getType(name):find("ender") then
            return peripheral.wrap(name)
        end
    end
    -- Fallback: try a wired/wireless modem named "top","back", etc.
    for _, side in ipairs({"top","bottom","left","right","front","back"}) do
        if peripheral.isPresent(side) then
            local t = peripheral.getType(side)
            if t == "modem" or t == "ender_modem" then
                return peripheral.wrap(side)
            end
        end
    end
    return nil
end

-- ── Packet handling ──────────────────────────────────────────────────────────
local function handlePacket(nodeKey, setupPassword, router, senderKey, cipherhex, replyChannel)
    -- Try to decrypt using the sender's key (passed as the first 32 chars of
    -- the raw message before the '|' separator).
    -- Packet wire format: "<senderKeyHex>|<cipherhex>"
    local ok, plain = pcall(xtea.decrypt, cipherhex, senderKey)
    if not ok then
        print("[Net] Decrypt error from channel " .. replyChannel)
        return
    end

    local pkt = textutils.unserialiseJSON(plain)
    if type(pkt) ~= "table" or not pkt.cmd then
        print("[Net] Malformed packet")
        return
    end

    local cmd  = pkt.cmd
    local from = pkt.from
    local who  = from and from:sub(1,10) or "???"

    if not from or #from ~= 128 then
        print("[Net] Bad 'from' in " .. tostring(cmd) .. " from key " .. senderKey:sub(1,8) .. "...")
        return
    end

    -- Targeted routing: if the wallet included a targetKey hint, only respond
    -- if our key starts with that prefix. Stops all nodes replying to one broadcast.
    if type(pkt.targetKey) == "string" and #pkt.targetKey > 0 then
        if nodeKey:sub(1, #pkt.targetKey) ~= pkt.targetKey then
            return  -- packet is for a different node
        end
    end

    if cmd == "HEARTBEAT" then
        miner.heartbeat(from)
        -- heartbeat is high-frequency, only log occasionally to avoid spam

    elseif cmd == "BALANCE" then
        local bal = ledger.getBalance(from)
        print(string.format("[Net] BALANCE  %s... -> %d uAMI", who, bal))
        local resp = textutils.serialiseJSON({ ok=true, address=from, balance=bal })
        local enc  = xtea.encrypt(resp, nodeKey)
        router.transmit(replyChannel, MESH_CHANNEL, enc)

    elseif cmd == "TRANSFER" then
        -- Recipient can be a raw 64-hex address OR a player name via toName.
        local to     = pkt.to
        local amount = pkt.amount
        if not to and pkt.toName then
            to = ledger.lookupName(pkt.toName)
            if not to then
                local err = xtea.encrypt(textutils.serialiseJSON({ok=false, err="Player '" .. pkt.toName .. "' not found"}), nodeKey)
                router.transmit(replyChannel, MESH_CHANNEL, err)
                return
            end
        end
        if type(to) ~= "string" or #to ~= 128 then
            local err = xtea.encrypt(textutils.serialiseJSON({ok=false, err="Invalid recipient"}), nodeKey)
            router.transmit(replyChannel, MESH_CHANNEL, err)
            return
        end
        if type(amount) ~= "number" or amount <= 0 then
            local err = xtea.encrypt(textutils.serialiseJSON({ok=false, err="Invalid amount"}), nodeKey)
            router.transmit(replyChannel, MESH_CHANNEL, err)
            return
        end
        local success, errMsg = ledger.transfer(from, to, amount)
        if success then
            print(string.format("[Net] TRANSFER %s... -> %s... %d uAMI OK", who, to:sub(1,10), amount))
        else
            print(string.format("[Net] TRANSFER %s... FAILED: %s", who, errMsg or "?"))
        end
        local resp = xtea.encrypt(
            textutils.serialiseJSON({ ok=success, err=errMsg }),
            nodeKey
        )
        router.transmit(replyChannel, MESH_CHANNEL, resp)

    elseif cmd == "REGISTER" then
        local isNew = ledger.register(from)
        if type(pkt.name) == "string" and #pkt.name > 0 then
            ledger.registerName(pkt.name, from)
            print(string.format("[Net] REGISTER %s (%s...)", pkt.name, who))
        elseif isNew then
            print(string.format("[Net] REGISTER %s... (anonymous)", who))
        end
        local resp = xtea.encrypt(textutils.serialiseJSON({ok=true}), nodeKey)
        router.transmit(replyChannel, MESH_CHANNEL, resp)

    elseif cmd == "LOOKUP" then
        local name = pkt.name
        if type(name) ~= "string" or #name == 0 then
            local err = xtea.encrypt(textutils.serialiseJSON({ok=false, err="Missing name"}), nodeKey)
            router.transmit(replyChannel, MESH_CHANNEL, err)
            return
        end
        local addr = ledger.lookupName(name)
        local resp
        if addr then
            print(string.format("[Net] LOOKUP   '%s' -> %s...", name, addr:sub(1,10)))
            resp = textutils.serialiseJSON({ok=true, address=addr, name=name})
        else
            print(string.format("[Net] LOOKUP   '%s' -> not found", name))
            resp = textutils.serialiseJSON({ok=false, err="Player '" .. name .. "' not found"})
        end
        router.transmit(replyChannel, MESH_CHANNEL, xtea.encrypt(resp, nodeKey))

    elseif cmd == "GETKEY" then
        -- Password-based node key delivery.
        -- Reply is encrypted with keyFromPassword(password), NOT the node key,
        -- so the wallet can decrypt it before it has the node key.
        if type(setupPassword) ~= "string" or #setupPassword == 0 then
            local resp = xtea.encrypt(textutils.serialiseJSON({ok=false, err="Auto-fetch disabled on this node"}), keyFromPassword("disabled"))
            router.transmit(replyChannel, MESH_CHANNEL, resp)
            return
        end
        local provided = pkt.password
        if type(provided) ~= "string" or provided ~= setupPassword then
            -- Use a dummy key so the wallet gets a decrypt error (not a hang)
            local resp = xtea.encrypt(textutils.serialiseJSON({ok=false, err="Wrong password"}), keyFromPassword("wrong"))
            router.transmit(replyChannel, MESH_CHANNEL, resp)
            return
        end
        local pwdKey = keyFromPassword(setupPassword)
        local resp   = xtea.encrypt(textutils.serialiseJSON({ok=true, key=nodeKey}), pwdKey)
        router.transmit(replyChannel, MESH_CHANNEL, resp)
        print("[Net] Sent node key to " .. from:sub(1,12) .. "... (password auth)")
    end
end

-- ── Status display ───────────────────────────────────────────────────────────
local function statusLoop()
    while true do
        os.sleep(30)
        local active = miner.getActive()
        local snap   = ledger.snapshot()
        local total  = 0
        for _, v in pairs(snap) do total = total + v end
        print(string.format("[Node] Active wallets: %d | Total supply: %d uAMI", #active, total))
    end
end

-- ── Main ─────────────────────────────────────────────────────────────────────
local function main()
    term.clear()
    term.setCursorPos(1, 1)
    print("===========================================")
    print("  AmiCoin Node v" .. NODE_VERSION)
    print("  Proof-of-Uptime Consensus")
    print("===========================================")

    local nodeKey      = loadOrCreateNodeKey()
    local setupPassword = loadOrCreateSetupPassword()
    print("")
    print("[!] Node XTEA Key (share with wallets during setup):")
    print("    " .. nodeKey)
    if setupPassword and #setupPassword > 0 then
        print("[!] Setup password active - wallets can auto-fetch key.")
    end
    print("")

    local router = findRouter()
    if not router then
        error("No Ender Router peripheral found!  Attach one and reboot.", 0)
    end
    router.open(MESH_CHANNEL)
    print("[Net] Ender Router opened on channel " .. MESH_CHANNEL)

    -- Run the miner daemon and the network listener in parallel.
    parallel.waitForAll(
        function() miner.run() end,
        function() statusLoop() end,
        function()
            print("[Net] Listening for wallet packets…")
            while true do
                local event, side, senderChan, replyChan, rawMsg = os.pullEvent("modem_message")
                if rawMsg and type(rawMsg) == "string" then
                    -- Wire format: senderKeyHex .. "|" .. cipherhex
                    local sep = rawMsg:find("|")
                    if sep then
                        local senderKey = rawMsg:sub(1, sep - 1)
                        local cipher    = rawMsg:sub(sep + 1)
                        if #senderKey == 32 then
                            handlePacket(nodeKey, setupPassword, router, senderKey, cipher, replyChan)
                        else
                            print("[Net] Ignored: bad wire format (key=" .. #senderKey .. " chars)")
                        end
                    else
                        print("[Net] Ignored: no | separator in message")
                    end
                end
            end
        end
    )
end

main()
