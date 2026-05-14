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

-- Persist totalTicks so the halving schedule survives reboots.
local STATE_FILE = "/data/miner_state.json"
local function loadState()
    if not fs.exists(STATE_FILE) then return { totalTicks = 0 } end
    local f = fs.open(STATE_FILE, "r")
    local raw = f.readAll()
    f.close()
    return textutils.unserialiseJSON(raw) or { totalTicks = 0 }
end
local function saveState()
    if not fs.exists("/data") then fs.makeDir("/data") end
    local f = fs.open(STATE_FILE, "w")
    f.write(textutils.serialiseJSON({ totalTicks = totalTicks }))
    f.close()
end

-- ── Helpers ───────────────────────────────────────────────────────────────────
local function currentRate()
    local halvings = math.floor(totalTicks / HALVING_TICKS)
    return math.max(1, math.floor(BASE_RATE / (2 ^ halvings)))
end

-- ── Public API ────────────────────────────────────────────────────────────────

-- Called by startup.lua whenever a valid signed packet is received from a wallet.
function daemon.heartbeat(address)
    if type(address) == "string" and #address == 128 then
        activeWallets[address] = os.epoch("utc") / 1000
        ledger.register(address)  -- no-op if already registered
    end
end

-- Main reward loop.  Call this once; it blocks forever using os.sleep().
function daemon.run()
    local state = loadState()
    totalTicks  = state.totalTicks or 0       -- restore halving progress
    print("[Miner] Proof-of-Uptime daemon started.")
    print(string.format("[Miner] Reward interval: %ds | Base rate: %d uAMI | Tick: #%d",
        REWARD_INTERVAL, BASE_RATE, totalTicks))

    while true do
        os.sleep(REWARD_INTERVAL)
        totalTicks = totalTicks + 1
        saveState()

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

-- Expose the current reward rate and tick count for STATS queries.
function daemon.getCurrentRate() return currentRate() end
function daemon.getTotalTicks()  return totalTicks      end

return daemon
