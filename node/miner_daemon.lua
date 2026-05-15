-- node/miner_daemon.lua
-- Proof-of-Uptime reward engine.
-- Tracks which wallet addresses have been heard on the mesh within the
-- active window, then mints coins proportional to their online time.
--
-- Reward schedule (per node, per real-time minute of uptime):
--   Base rate : 25 microcoins / minute  (0.000025 AMI)
--   Halving   : every 525,600 minutes (~1 Minecraft year of real time)
--
-- The daemon keeps an in-memory "heartbeat" table.  Wallets that send
-- any signed packet to the node within HEARTBEAT_TTL seconds are
-- considered active.  A background coroutine walks the table every
-- REWARD_INTERVAL seconds and credits each active address.

local ledger = require("ledger")

local daemon = {}

-- ── Configuration ────────────────────────────────────────────────────────────
local REWARD_INTERVAL     = 30       -- seconds between reward ticks
local HEARTBEAT_TTL       = 90       -- seconds a wallet stays "active" after last packet
local BASE_RATE           = 25       -- microcoins per active wallet per tick (live from GitHub)
local HALVING_TICKS       = 525600   -- ticks before base rate halves
local RATE_URL            = "https://raw.githubusercontent.com/Teru-dot-png/amicoin-fullpower/refs/heads/main/reward_rate.txt"
local RATE_REFRESH_TICKS  = 10       -- re-fetch remote rate every N ticks

-- ── Remote rate fetch ────────────────────────────────────────────────────────
-- Fetches BASE_RATE from GitHub.  Never saved to disk; falls back to current
-- value if the request fails or returns a non-numeric / out-of-range body.
local function fetchRemoteRate()
    local ok, res = pcall(http.get, RATE_URL)
    if not ok or not res then return end
    local body = res.readAll()
    res.close()
    local clean_body = (body or ""):gsub("%s", "")
    local n = tonumber(clean_body)
    if n and n >= 1 and n <= 100000 then
        if n ~= BASE_RATE then
            print(string.format("[Miner] Remote rate: %d -> %d uAMI/tick", BASE_RATE, n))
            BASE_RATE = n
        end
    end
end

-- ── State ─────────────────────────────────────────────────────────────────────
local activeWallets = {}  -- [address] = lastSeenTimestamp
local totalTicks    = 0
local lastLagFactor = 1.0  -- 1.0 = perfect timing; < 0.7 = server lag detected

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
    fetchRemoteRate()                          -- pull live rate before first tick
    print("[Miner] Proof-of-Uptime daemon started.")
    print(string.format("[Miner] Reward interval: %ds | Base rate: %d uAMI | Tick: #%d",
        REWARD_INTERVAL, BASE_RATE, totalTicks))

    while true do
        local cycleStart = os.epoch("utc")   -- ms timestamp before sleep
        os.sleep(REWARD_INTERVAL)
        local elapsed = (os.epoch("utc") - cycleStart) / 1000  -- actual seconds

        -- Lag factor: 1.0 = on time, <1.0 = server behind schedule.
        -- Clamp to [0.1, 1.0] so division/display is always safe.
        lastLagFactor = math.min(1.0, REWARD_INTERVAL / math.max(elapsed, REWARD_INTERVAL * 0.1))

        if lastLagFactor < 0.7 then
            print(string.format("[Miner] Lag! Cycle %.1fs (want %ds) | TPS ~%.1f",
                elapsed, REWARD_INTERVAL, lastLagFactor * 20))
        end

        totalTicks = totalTicks + 1
        saveState()
        if totalTicks % RATE_REFRESH_TICKS == 0 then fetchRemoteRate() end

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
            print(string.format("[Miner] Tick #%d | Rate: %d uAMI | %d wallet(s) | lag=%.2f",
                totalTicks, rate, rewarded, lastLagFactor))
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

-- Expose the current reward rate, tick count, and server lag factor for STATS/monitor.
function daemon.getCurrentRate() return currentRate()  end
function daemon.getTotalTicks()  return totalTicks     end
function daemon.getLagFactor()   return lastLagFactor  end

return daemon
