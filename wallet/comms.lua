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
-- Uses os.startTimer so the timeout actually fires even with no modem traffic.
-- Returns: ok (bool), payload (table or nil), errMsg (string or nil)
local function send(secretKey, nodeKey, packet, expectReply)
    local r = getRouter()
    if not r then
        return false, nil, "No Ender Router found on this Pad"
    end

    local plain  = textutils.serialiseJSON(packet)
    local cipher = xtea.encrypt(plain, secretKey)
    local wire   = secretKey .. "|" .. cipher

    local replyChannel = REPLY_BASE + math.random(0, 999)
    r.open(MESH_CHANNEL)
    r.open(replyChannel)
    r.transmit(MESH_CHANNEL, replyChannel, wire)

    if not expectReply then
        r.close(replyChannel)
        return true, nil, nil
    end

    -- Timer-based timeout: os.pullEvent with a modem filter never fires
    -- on its own if no message comes, so we use an unfiltered pull + timer.
    local timer = os.startTimer(TIMEOUT)
    local result_ok, result_data, result_err = false, nil, "Timeout"

    while true do
        local ev, p1, p2, p3, p4 = os.pullEvent()
        if ev == "modem_message" and p3 == replyChannel and type(p4) == "string" then
            os.cancelTimer(timer)
            local ok2, plain2 = pcall(xtea.decrypt, p4, nodeKey)
            if ok2 then
                local data = textutils.unserialiseJSON(plain2)
                if type(data) == "table" then
                    result_ok   = data.ok ~= false
                    result_data = data
                    result_err  = data.err
                else
                    result_err = "Bad response format"
                end
            else
                result_err = "Decrypt failed - check node key"
            end
            break
        elseif ev == "timer" and p1 == timer then
            result_err = "Timeout - node did not respond"
            break
        end
    end

    r.close(replyChannel)
    return result_ok, result_data, result_err
end

-- ── Public API ────────────────────────────────────────────────────────────────

-- Send a HEARTBEAT to a single node (fire-and-forget).
function comms.heartbeat(secretKey, address, nodeKey)
    -- nodeKey unused for heartbeat (no reply expected) but kept for API symmetry
    return send(secretKey, nil, { cmd="HEARTBEAT", from=address }, false)
end

-- Send heartbeats to ALL nodes in a nodes table: {{name, key}, ...}
function comms.heartbeatAll(secretKey, address, nodes)
    if not nodes then return end
    for _, node in ipairs(nodes) do
        comms.heartbeat(secretKey, address, node.key)
    end
end

-- Query balance from a single node.
function comms.getBalance(secretKey, nodeKey, address)
    return send(secretKey, nodeKey, { cmd="BALANCE", from=address, nonce=os.epoch("utc") }, true)
end

-- Query balance from ALL nodes; returns total and per-node breakdown.
-- Returns: totalBalance (int), perNode (array of {name, balance, err})
function comms.getAllBalances(secretKey, address, nodes)
    if not nodes or #nodes == 0 then
        return 0, {}
    end
    local total   = 0
    local perNode = {}
    for _, node in ipairs(nodes) do
        local ok, data, err = comms.getBalance(secretKey, node.key, address)
        if ok and data and data.balance then
            total = total + data.balance
            perNode[#perNode + 1] = { name=node.name, balance=data.balance, err=nil }
        else
            perNode[#perNode + 1] = { name=node.name, balance=0, err=err or "no response" }
        end
    end
    return total, perNode
end

-- Send a transfer request through a specific node.
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

-- Register the address (and optional player name) on a single node.
function comms.register(secretKey, nodeKey, address, name)
    local pkt = { cmd="REGISTER", from=address }
    if type(name) == "string" and #name > 0 then
        pkt.name = name
    end
    return send(secretKey, nodeKey, pkt, true)
end

-- Register on ALL nodes.
function comms.registerAll(secretKey, address, name, nodes)
    if not nodes then return end
    for _, node in ipairs(nodes) do
        comms.register(secretKey, node.key, address, name)
    end
end

-- Look up a player name on a specific node.
function comms.lookup(secretKey, nodeKey, address, name)
    return send(secretKey, nodeKey, { cmd="LOOKUP", from=address, name=name, nonce=os.epoch("utc") }, true)
end

-- Look up a player name across all nodes; returns first match found.
function comms.lookupAll(secretKey, address, name, nodes)
    if not nodes then return false, nil, "No nodes configured" end
    for _, node in ipairs(nodes) do
        local ok, data, err = comms.lookup(secretKey, node.key, address, name)
        if ok and data and data.address then
            return true, data, nil
        end
    end
    return false, nil, "Player '" .. name .. "' not found on any node"
end

return comms
