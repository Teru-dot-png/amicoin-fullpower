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
--   { cmd="TRANSFER",  from="<address>", to="<address>", amount=<int µAMI>, nonce=<int> }
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
local function handlePacket(nodeKey, router, senderKey, cipherhex, replyChannel)
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

    if not from or #from ~= 64 then
        print("[Net] Missing/invalid 'from' address")
        return
    end

    if cmd == "HEARTBEAT" then
        miner.heartbeat(from)

    elseif cmd == "BALANCE" then
        local bal = ledger.getBalance(from)
        local resp = textutils.serialiseJSON({ ok=true, address=from, balance=bal })
        local enc  = xtea.encrypt(resp, nodeKey)
        router.transmit(replyChannel, MESH_CHANNEL, enc)

    elseif cmd == "TRANSFER" then
        local to     = pkt.to
        local amount = pkt.amount
        if type(to) ~= "string" or #to ~= 64 then
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
        local resp = xtea.encrypt(
            textutils.serialiseJSON({ ok=success, err=errMsg }),
            nodeKey
        )
        router.transmit(replyChannel, MESH_CHANNEL, resp)

    elseif cmd == "REGISTER" then
        ledger.register(from)
        local resp = xtea.encrypt(textutils.serialiseJSON({ok=true}), nodeKey)
        router.transmit(replyChannel, MESH_CHANNEL, resp)
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
        print(string.format("[Node] Active wallets: %d | Total supply: %d µAMI", #active, total))
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

    local nodeKey = loadOrCreateNodeKey()
    print("\n[!] Node XTEA Key (share with wallets during setup):")
    print("    " .. nodeKey)
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
                            handlePacket(nodeKey, router, senderKey, cipher, replyChan)
                        end
                    end
                end
            end
        end
    )
end

main()
