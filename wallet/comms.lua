-- wallet/comms.lua
-- Handles all network communication between the Ender Pad wallet and the node.
-- Every outgoing packet is XTEA-encrypted with the wallet's own secret key.
-- The node key (shared during node setup) is used to decrypt replies.

local xtea = require("shared.xtea")

local comms = {}

local MESH_CHANNEL = 1337
local REPLY_BASE   = 2000   -- Pad listens on 2000 + math.random(0,999)
local TIMEOUT      = 8      -- seconds to wait for a node reply

local router = nil

-- ── Internal ──────────────────────────────────────────────────────────────────

local function getRouter()
    if router then return router end
    for _, name in ipairs(peripheral.getNames()) do
        local t = peripheral.getType(name)
        if t == "ender_modem" or t:find("ender") then
            router = peripheral.wrap(name)
            return router
        end
    end
    for _, side in ipairs({"top","bottom","left","right","front","back"}) do
        if peripheral.isPresent(side) then
            local t = peripheral.getType(side)
            if t == "modem" or t == "ender_modem" then
                router = peripheral.wrap(side)
                return router
            end
        end
    end
    return nil
end

-- Build and transmit an encrypted packet; wait for an optional reply.
-- Returns: ok (bool), payload (table or nil), errMsg (string or nil)
local function send(secretKey, nodeKey, packet, expectReply)
    local r = getRouter()
    if not r then
        return false, nil, "No Ender Router found on this Pad"
    end

    local plain  = textutils.serialiseJSON(packet)
    local cipher = xtea.encrypt(plain, secretKey)
    -- Wire format expected by the node: senderKeyHex .. "|" .. cipherhex
    local wire   = secretKey .. "|" .. cipher

    local replyChannel = REPLY_BASE + math.random(0, 999)
    r.open(MESH_CHANNEL)
    r.open(replyChannel)

    r.transmit(MESH_CHANNEL, replyChannel, wire)

    if not expectReply then
        r.close(replyChannel)
        return true, nil, nil
    end

    -- Wait for a reply within TIMEOUT seconds
    local deadline = os.epoch("utc") / 1000 + TIMEOUT
    while os.epoch("utc") / 1000 < deadline do
        local ev, _, _, replyCh, msg = os.pullEvent("modem_message")
        if replyCh == replyChannel and type(msg) == "string" then
            r.close(replyChannel)
            local ok2, plain2 = pcall(xtea.decrypt, msg, nodeKey)
            if ok2 then
                local data = textutils.unserialiseJSON(plain2)
                if type(data) == "table" then
                    return data.ok ~= false, data, data.err
                end
            end
            return false, nil, "Decrypt failed – check node key"
        end
    end
    r.close(replyChannel)
    return false, nil, "Timeout waiting for node reply"
end

-- ── Public API ────────────────────────────────────────────────────────────────

-- Send a HEARTBEAT so the node keeps this wallet active for rewards.
function comms.heartbeat(secretKey, address)
    return send(secretKey, nil, { cmd="HEARTBEAT", from=address }, false)
end

-- Query the balance of this wallet address.
-- nodeKey: the XTEA key of the destination node (for decrypting the reply).
function comms.getBalance(secretKey, nodeKey, address)
    return send(secretKey, nodeKey, { cmd="BALANCE", from=address, nonce=os.epoch("utc") }, true)
end

-- Send a transfer request.
function comms.transfer(secretKey, nodeKey, fromAddress, toAddress, amountMicro)
    local pkt = {
        cmd    = "TRANSFER",
        from   = fromAddress,
        to     = toAddress,
        amount = amountMicro,
        nonce  = os.epoch("utc"),
    }
    return send(secretKey, nodeKey, pkt, true)
end

-- Register the address (and optional player name) on the node.
function comms.register(secretKey, nodeKey, address, name)
    local pkt = { cmd="REGISTER", from=address }
    if type(name) == "string" and #name > 0 then
        pkt.name = name
    end
    return send(secretKey, nodeKey, pkt, true)
end

-- Look up a player name and return their address.
-- Returns: ok (bool), data (table with .address), errMsg
function comms.lookup(secretKey, nodeKey, address, name)
    return send(secretKey, nodeKey, { cmd="LOOKUP", from=address, name=name, nonce=os.epoch("utc") }, true)
end

return comms
