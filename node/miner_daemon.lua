-- node/miner_daemon.lua
-- Proof-of-Uptime reward engine.
-- Tracks which wallet addresses have been heard on the mesh within the
-- active window, then mints coins proportional to their online time.
--
-- Reward schedule (per node, per real-time minute of uptime):
--   Base rate : 10 microcoins / minute  (0.00001 AMI)
--   Halving   : every 525,600 minutes (~1 Minecraft year of real time)
--
-- The daemon keeps an in-memory "heartbeat" table.  Wallets that send
-- any signed packet to the node within HEARTBEAT_TTL seconds are
-- considered active.  A background coroutine walks the table every
-- REWARD_INTERVAL seconds and credits each active address.

local ledger = require("ledger")

local daemon = {}

-- ── Configuration ────────────────────────────────────────────────────────────
local REWARD_INTERVAL  = 60          -- seconds between reward ticks
local HEARTBEAT_TTL    = 90          -- seconds a wallet stays "active" after last packet
local BASE_RATE        = 10          -- microcoins per active wallet per tick
local HALVING_TICKS    = 525600      -- ticks before base rate halves

-- ── State ─────────────────────────────────────────────────────────────────────
local activeWallets = {}  -- [address] = lastSeenTimestamp
local totalTicks    = 0

-- ── Helpers ───────────────────────────────────────────────────────────────────
local function currentRate()
    local halvings = math.floor(totalTicks / HALVING_TICKS)
    return math.max(1, math.floor(BASE_RATE / (2 ^ halvings)))
end

-- ── Public API ────────────────────────────────────────────────────────────────

-- Called by startup.lua whenever a valid signed packet is received from a wallet.
function daemon.heartbeat(address)
    if type(address) == "string" and #address == 64 then
        activeWallets[address] = os.epoch("utc") / 1000
        ledger.register(address)  -- no-op if already registered
    end
end

-- Main reward loop.  Call this once; it blocks forever using os.sleep().
function daemon.run()
    print("[Miner] Proof-of-Uptime daemon started.")
    print("[Miner] Reward interval: " .. REWARD_INTERVAL .. "s | Base rate: " .. BASE_RATE .. " uAMI/tick")

    while true do
        os.sleep(REWARD_INTERVAL)
        totalTicks = totalTicks + 1

        local now  = os.epoch("utc") / 1000
        local rate = currentRate()
        local rewarded = 0

        for address, lastSeen in pairs(activeWallets) do
            if (now - lastSeen) <= HEARTBEAT_TTL then
                ledger.credit(address, rate)
                rewarded = rewarded + 1
            else
                activeWallets[address] = nil  -- evict stale wallet
            end
        end

        if rewarded > 0 then
            print(string.format("[Miner] Tick #%d | Rate: %d uAMI | Rewarded %d wallet(s)",
                totalTicks, rate, rewarded))
        end
    end
end

-- Return the current list of active wallet addresses.
function daemon.getActive()
    local now = os.epoch("utc") / 1000
    local list = {}
    for address, lastSeen in pairs(activeWallets) do
        if (now - lastSeen) <= HEARTBEAT_TTL then
            list[#list + 1] = address
        end
    end
    return list
end

return daemon
