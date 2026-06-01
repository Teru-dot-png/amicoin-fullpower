-- node/upgrades.lua
-- AmiCoin Node Upgrade Engine v1.0
--
-- Provides 10 purchasable node upgrades sold via the standard AmiCoin
-- INVOICE / PAYMENT_ACK flow.  Effects are applied through the public API
-- consumed by miner_daemon.lua, startup.lua, and ledger.lua.
--
-- Key press  : [P] in the node's main input coroutine
-- Data store : /data/upgrades.json
-- Invoice ch : 1338  (same channel as AmiStore PAYMENT_ACK)
--
-- upgrades.json schema:
-- {
--   "treasury":      "<128-hex>",  -- wallet address that receives upgrade revenue
--   "owner_name":    "PlayerName", -- human label for the treasury
--   "owner_address": "<128-hex>",  -- same as treasury (convenience field)
--   "levels": {
--     "miner_boost":   3,
--     "priority_ping": 0,
--     ...                          -- all 10 upgrade IDs, integer 0-10
--   }
-- }

local ledger = require("ledger")

local upgrades = {}

-- ── Constants ─────────────────────────────────────────────────────────────────
local DATA_FILE    = "/data/upgrades.json"
local SHOP_CHANNEL = 1338   -- plaintext invoice / ACK channel
local ACK_TIMEOUT  = 120    -- seconds to wait for PAYMENT_ACK
local PAGE_SIZE    = 5      -- upgrades shown per menu page
local MAX_LEVEL    = 10     -- hard cap on every upgrade

-- ── Upgrade definitions ───────────────────────────────────────────────────────
-- short: max 12 chars (fits the menu column)
-- desc:  one-line effect summary
local DEFS = {
    {
        id    = "miner_boost",
        name  = "Overclocked Miner",
        short = "OvrclkMiner",
        desc  = "+20% mining payout multiplier per level (max 3.0x).",
    },
    {
        id    = "priority_ping",
        name  = "Priority Ping Response",
        short = "PriorityPing",
        desc  = "Removes reply delay. Wallets sort this node first.",
    },
    {
        id    = "privacy_shield",
        name  = "Ledger Privacy Shield",
        short = "PrivacyShld",
        desc  = "LOOKUP for your address returns PRIVATE to others.",
    },
    {
        id    = "smart_cache",
        name  = "Smart Cache Aggregator",
        short = "SmartCache",
        desc  = "Batches ledger writes: +3s flush interval per level.",
    },
    {
        id    = "collision_fix",
        name  = "Collision Handler",
        short = "CollisionFix",
        desc  = "Reduces error-path backoff by 0.05s per level.",
    },
    {
        id    = "fee_snatcher",
        name  = "Routing Fee Snatcher",
        short = "FeeSnatcher",
        desc  = "Skims 100 uAMI per level from CONSOLIDATE_IN ops.",
    },
    {
        id    = "hb_extender",
        name  = "Heartbeat Extender",
        short = "HBExtender",
        desc  = "Extends uptime window +9s/level (90s base, max 180s).",
    },
    {
        id    = "dns_longevity",
        name  = "DNS Cache Longevity",
        short = "DnsLongevity",
        desc  = "Multiplies local DNS TTL by level. Fewer lookups.",
    },
    {
        id    = "matrix_ui",
        name  = "Advanced Matrix UI",
        short = "Matrix UI",
        desc  = "Unlocks premium monitor colour themes per level.",
    },
    {
        id    = "genesis",
        name  = "Genesis Protocol",
        short = "GenesisProto",
        desc  = "PRESTIGE: Broadcasts boot signature across the mesh.",
    },
}

-- ── Pricing formula ───────────────────────────────────────────────────────────
-- cost(level) = floor(1_000_000 * 100 ^ ((level - 1) / 9))
--
-- Level  1 =   1,000,000 uAMI  (  1.0000 AMI)
-- Level  2 =   1,668,101 uAMI  (  1.6681 AMI)
-- Level  3 =   2,782,559 uAMI  (  2.7826 AMI)
-- Level  5 =   7,742,637 uAMI  (  7.7426 AMI)
-- Level  8 =  35,938,137 uAMI  ( 35.9381 AMI)
-- Level 10 = 100,000,000 uAMI  (100.0000 AMI)
local function calcCost(level)
    if level < 1 or level > MAX_LEVEL then return nil end
    return math.floor(1000000 * (100 ^ ((level - 1) / 9)))
end

-- Exposed so startup.lua / UI can display the curve without reimplementing it.
upgrades.getCost = calcCost

-- ── Persistent state ──────────────────────────────────────────────────────────
local _state = nil   -- lazy-loaded; nil means "not yet read from disk"

local function defaultState()
    local levels = {}
    for _, d in ipairs(DEFS) do levels[d.id] = 0 end
    return { treasury=nil, owner_name=nil, owner_address=nil, levels=levels }
end

local function loadState()
    if _state then return _state end
    if fs.exists(DATA_FILE) then
        local f = fs.open(DATA_FILE, "r")
        local raw = f.readAll(); f.close()
        local t = textutils.unserialiseJSON(raw)
        if type(t) == "table" then
            _state = t
            if type(_state.levels) ~= "table" then _state.levels = {} end
            -- Back-fill any missing upgrade IDs (handles schema additions)
            for _, d in ipairs(DEFS) do
                if _state.levels[d.id] == nil then _state.levels[d.id] = 0 end
            end
            return _state
        end
    end
    _state = defaultState()
    return _state
end

local function saveState()
    if not fs.exists("/data") then fs.makeDir("/data") end
    local f = fs.open(DATA_FILE, "w")
    f.write(textutils.serialiseJSON(_state)); f.close()
end

local function getLevel(id)
    return loadState().levels[id] or 0
end

-- ── Effect API ────────────────────────────────────────────────────────────────
-- All callers should query these functions, never read upgrades.json directly.

-- 1. Overclocked Miner: 1.0 + 0.2 per level → max 3.0 at lv10
function upgrades.getMinerMultiplier()
    return 1.0 + 0.2 * getLevel("miner_boost")
end

-- 2. Priority Ping: level > 0 → advertise priority_ping=true in STATS response
function upgrades.hasPriorityPing()
    return getLevel("priority_ping") > 0
end

-- 3. Privacy Shield: returns true if `addr` is the upgrade owner AND shield active.
-- Used in LOOKUP: return "PRIVATE" instead of the real 128-hex address.
function upgrades.hasPrivacyShield(addr)
    local st = loadState()
    return getLevel("privacy_shield") > 0
        and type(st.owner_address) == "string"
        and st.owner_address == addr
end

-- 4. Smart Cache Aggregator: seconds between ledger disk flushes (0 = immediate).
-- Level 1 = 3s, level 10 = 30s.
function upgrades.getSmartCacheDelay()
    return getLevel("smart_cache") * 3
end

-- 5. Collision Handler: error-path backoff in seconds.
-- Baseline 0.5s, −0.05s per level, floor 0s at lv10.
function upgrades.getCollisionDelay()
    return math.max(0.0, 0.5 - 0.05 * getLevel("collision_fix"))
end

-- 6. Routing Fee Snatcher: µAMI skimmed per CONSOLIDATE_IN operation.
-- 100 µAMI per level → max 1 000 µAMI (0.001 AMI) at lv10.
function upgrades.getFeeSnatchAmount()
    return getLevel("fee_snatcher") * 100
end

-- 7. Heartbeat Extender: active-wallet TTL in seconds.
-- Base 90s + 9s per level → max 180s at lv10.
function upgrades.getHeartbeatTTL()
    return 90 + 9 * getLevel("hb_extender")
end

-- 8. DNS Cache Longevity: integer multiplier on local DNS record TTL.
-- Level 0 = 1 (unchanged), level 10 = 10 (records last 10× longer).
function upgrades.getDnsLongevityMult()
    return math.max(1, getLevel("dns_longevity"))
end

-- 9. Advanced Matrix UI: theme key string for monitor rendering, or nil for default.
local MATRIX_THEMES = {
    [1]="green_phosphor", [2]="amber",       [3]="ice_blue",
    [4]="deep_violet",    [5]="neon_pink",   [6]="solar_orange",
    [7]="arctic_white",   [8]="spectrum",    [9]="void_red",
    [10]="genesis_gold",
}
function upgrades.getMatrixTheme()
    return MATRIX_THEMES[getLevel("matrix_ui")]   -- nil at lv0
end

-- 10. Genesis Protocol: returns a broadcast string at boot, nil if not purchased.
function upgrades.getGenesisSignature()
    if getLevel("genesis") == 0 then return nil end
    local st  = loadState()
    local lv  = getLevel("genesis")
    local who = st.owner_name or "Unknown"
    return string.format("[GENESIS] Node blessed by %s — Lv%d — AmiCoin", who, lv)
end

-- Expose the full state for treasury address lookups in startup.lua.
function upgrades.getState()
    return loadState()
end

-- ── Helpers ───────────────────────────────────────────────────────────────────
local function fnv1a(s)
    local hash = 2166136261
    for i = 1, #s do
        hash = bit32.bxor(hash, string.byte(s, i))
        hash = (hash * 16777619) % 4294967296
    end
    return string.format("%08x", hash)
end

local function newUID()
    return fnv1a(
        tostring(os.epoch("utc")) ..
        tostring(os.getComputerID()) ..
        tostring(math.random(0, 2147483647))
    )
end

-- ── Terminal helpers (scoped; do not pollute global state) ────────────────────
local function ugCls()
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
    term.clear()
    term.setCursorPos(1, 1)
end

local function ugBanner(title)
    ugCls()
    local w = term.getSize()
    term.setBackgroundColor(colors.blue)
    term.setTextColor(colors.white)
    term.setCursorPos(1, 1); term.clearLine()
    local hdr = " AmiCoin  Node Upgrades "
    term.setCursorPos(math.floor((w - #hdr) / 2) + 1, 1)
    term.write(hdr)
    term.setBackgroundColor(colors.black)
    if title then
        local w2 = term.getSize()
        term.setTextColor(colors.orange)
        term.setCursorPos(math.floor((w2 - #title) / 2) + 1, 3)
        term.write(title)
    end
end

local function ugLine(y, text, col)
    local w = term.getSize()
    term.setCursorPos(1, y)
    term.setTextColor(col or colors.white)
    term.write(text:sub(1, w))
end

local function ugRule(y)
    local w = term.getSize()
    term.setCursorPos(1, y); term.setTextColor(colors.gray)
    term.write(string.rep("-", w))
end

-- ── Upgrade menu (paginated, PAGE_SIZE items per page) ────────────────────────
local function drawMenu(page, state)
    local w          = term.getSize()
    local totalPages = math.ceil(#DEFS / PAGE_SIZE)
    ugBanner(string.format("Upgrades  [%d/%d]", page, totalPages))
    ugRule(4)
    -- Column header
    ugLine(5, string.format("    %-12s %2s  %13s", "Upgrade", "Lv", "Next Cost"), colors.gray)
    ugRule(6)

    local base = (page - 1) * PAGE_SIZE
    for i = 1, PAGE_SIZE do
        local idx = base + i
        local row = 6 + i
        if idx > #DEFS then
            term.setCursorPos(1, row); term.clearLine()
        else
            local d   = DEFS[idx]
            local lv  = state.levels[d.id] or 0
            local col, costStr
            if lv >= MAX_LEVEL then
                costStr = "  *** MAX ***"
                col     = colors.lime
            else
                local c = calcCost(lv + 1)
                costStr = string.format("%8.4f AMI", c / 1000000)
                col     = (lv == 0) and colors.white or colors.yellow
            end
            -- "[1] OvrclkMiner  3  12.3456 AMI"
            local line = string.format("[%d] %-12s %2d  %s",
                i, d.short:sub(1, 12), lv, costStr)
            ugLine(row, line, col)
        end
    end

    ugRule(12)
    ugLine(13, "  [1-5] select  [,][.] page  [B]ack", colors.gray)
    ugLine(14, string.format("  Page %d / %d  |  %d upgrades total", page, totalPages, #DEFS), colors.lightGray)
end

-- ── Invoice broadcast + PAYMENT_ACK listener ─────────────────────────────────
local SPINNER = { "|", "/", "-", "\\" }

-- Broadcasts INVOICE on ch 1338 and blocks until PAYMENT_ACK arrives or timeout.
-- Verifies payment arrived in the treasury ledger before returning success.
-- Returns: (true, nil) on success | (false, errMsg) on failure/cancel/timeout.
local function broadcastAndWait(router, treasury, playerAddr, playerName, def, cost, txId)
    local invoice = textutils.serialiseJSON({
        type      = "INVOICE",
        to        = playerAddr,
        tx_id     = txId,
        shop_addr = treasury,
        shop_name = "AmiNode Upgrades",
        item      = "ami:node_upgrade/" .. def.id,
        qty       = 1,
        total     = cost,
    })

    -- ── Pending payment screen ────────────────────────────────────────────────
    local w = term.getSize()
    ugBanner("Awaiting Payment")
    ugRule(4)
    ugLine(5, ("  Shop  : AmiNode Upgrades"):sub(1, w),              colors.orange)
    ugLine(6, ("  Item  : " .. def.name):sub(1, w),                  colors.white)
    ugLine(7,  string.format("  Cost  : %.4f AMI  (%d uAMI)", cost / 1000000, cost), colors.yellow)
    ugRule(8)
    ugLine(9,  ("  Buyer : " .. playerName):sub(1, w),               colors.lightGray)
    ugLine(10, ("  TX    : " .. txId:sub(1, w - 8)):sub(1, w),       colors.gray)
    ugRule(11)
    ugLine(13, "  Invoice sent to your Wallet Pad.",                  colors.lightGray)
    ugLine(14, "  Press [Y] on your Pad to confirm.",                 colors.lightGray)
    ugLine(15, "  Press [B] here to cancel.",                         colors.gray)

    local balBefore    = ledger.getBalance(treasury)
    local deadline     = os.epoch("utc") / 1000 + ACK_TIMEOUT
    local frame        = 0
    local rebroadcast  = 0   -- counts 1s ticks; re-sends invoice every 10

    -- Broadcast immediately
    router.transmit(SHOP_CHANNEL, SHOP_CHANNEL, invoice)

    while os.epoch("utc") / 1000 < deadline do
        local remaining = math.floor(deadline - os.epoch("utc") / 1000)
        frame        = (frame % 4) + 1
        rebroadcast  = rebroadcast + 1

        if rebroadcast >= 10 then
            router.transmit(SHOP_CHANNEL, SHOP_CHANNEL, invoice)
            rebroadcast = 0
        end

        -- Spinner row (row 12)
        term.setCursorPos(1, 12); term.setTextColor(colors.cyan)
        term.write(string.format("  %s Waiting for payment...  %3ds remaining  ",
            SPINNER[frame], remaining))

        -- 1-second tick via timer; also catches modem messages and [B] cancel.
        local tid       = os.startTimer(1)
        local cancelled = false
        while true do
            local ev, a, b, c, d = os.pullEvent()
            if ev == "timer" and a == tid then
                break   -- advance spinner frame

            elseif ev == "modem_message" and b == SHOP_CHANNEL then
                if type(d) == "string" and d:sub(1, 1) == "{" then
                    local ok2, pkt = pcall(textutils.unserialiseJSON, d)
                    if ok2 and type(pkt) == "table"
                    and pkt.type == "PAYMENT_ACK"
                    and pkt.tx_id == txId then
                        -- ACK is the wallet's confirmation that transfer succeeded.
                        -- The payment may have settled on a different node, so we
                        -- trust the ACK rather than checking local ledger balance.
                        return true, nil
                    end
                end

            elseif ev == "key" and a == keys.b then
                cancelled = true; break
            end
        end
        if cancelled then return false, "Cancelled by operator" end
    end

    return false, string.format("Timed out after %ds", ACK_TIMEOUT)
end

-- ── First-time treasury setup ─────────────────────────────────────────────────
-- Runs once; prompts the node operator for the wallet name that will receive
-- all upgrade payment revenue.  Stored in upgrades.json as `treasury`.
local function setupTreasury(state)
    ugBanner("First-Time Setup")
    ugLine(5, "  Who receives upgrade payments?",            colors.yellow)
    ugLine(6, "  Enter your registered Ami-DNS name:",       colors.lightGray)
    ugLine(7, "  (Register on a node first if needed.)",     colors.gray)
    ugRule(8)
    term.setCursorPos(1, 9); term.setTextColor(colors.white)
    io.write("  Name > ")
    local inp = read()
    inp = inp:gsub("^%s*(.-)%s*$", "%1")
    if #inp == 0 then
        ugLine(11, "  Cancelled.", colors.gray); os.sleep(1)
        return false
    end
    local addr = ledger.lookupName(inp)
    if not addr then
        ugLine(11, "  Name '" .. inp .. "' not found.", colors.red)
        ugLine(12, "  Register on a node first, then retry.", colors.lightGray)
        os.sleep(2.5); return false
    end
    state.treasury      = addr
    state.owner_name    = inp
    state.owner_address = addr
    saveState()
    ugLine(11, "  Treasury set: " .. inp, colors.green)
    ugLine(12, "  " .. addr:sub(1, 24) .. "...", colors.gray)
    os.sleep(1.5)
    return true
end

-- ── Confirm + execute a single purchase ───────────────────────────────────────
local function doPurchase(router, state, defIdx, buyerAddr, buyerName)
    local w  = term.getSize()
    local d  = DEFS[defIdx]
    local lv = state.levels[d.id] or 0

    if lv >= MAX_LEVEL then
        ugBanner("Already Maxed!")
        ugLine(5, "  " .. d.name,                      colors.lime)
        ugLine(6, "  Level 10 / 10 -- maximum reached.", colors.gray)
        os.sleep(2); return
    end

    local nextLv = lv + 1
    local cost   = calcCost(nextLv)

    -- Confirm screen
    ugBanner("Confirm Upgrade")
    ugRule(4)
    ugLine(5, ("  Upgrade : " .. d.name):sub(1, w),                 colors.orange)
    ugLine(6,  string.format("  Level   : %d  ->  %d  / %d", lv, nextLv, MAX_LEVEL), colors.white)
    ugLine(7, ("  Effect  : " .. d.desc):sub(1, w),                  colors.lightGray)
    ugRule(8)
    ugLine(9,   string.format("  Cost    : %.4f AMI", cost / 1000000), colors.yellow)
    ugLine(10, ("  = " .. cost .. " uAMI"):sub(1, w),                 colors.gray)
    ugRule(11)
    ugLine(12, "  [Y] Confirm    [N] Cancel",                         colors.orange)

    while true do
        local _, key = os.pullEvent("key")
        if key == keys.n then return end
        if key == keys.y then
            local txId = newUID()
            -- Ensure shop channel is open (no-op if already open)
            pcall(function() router.open(SHOP_CHANNEL) end)

            local ok, err = broadcastAndWait(
                router, state.treasury, buyerAddr, buyerName, d, cost, txId)

            if ok then
                -- Level up and persist immediately
                state.levels[d.id] = nextLv
                saveState()

                ugBanner("Upgrade Complete!")
                ugRule(4)
                ugLine(5, ("  " .. d.name):sub(1, w), colors.lime)
                ugLine(6,  string.format("  Level %d / %d  -- active immediately!", nextLv, MAX_LEVEL), colors.green)
                ugRule(7)
                ugLine(8, ("  " .. d.desc):sub(1, w), colors.cyan)
                ugRule(9)

                -- Show the updated numeric effect value
                if     d.id == "miner_boost"   then
                    ugLine(10, string.format("  Mining multiplier: x%.1f", 1.0 + 0.2 * nextLv), colors.lime)
                elseif d.id == "hb_extender"   then
                    ugLine(10, string.format("  Uptime window: %ds", 90 + 9 * nextLv), colors.lime)
                elseif d.id == "fee_snatcher"  then
                    ugLine(10, string.format("  Fee per CONSOLIDATE: %d uAMI", nextLv * 100), colors.lime)
                elseif d.id == "collision_fix" then
                    ugLine(10, string.format("  Error backoff: %.2fs", math.max(0, 0.5 - 0.05 * nextLv)), colors.lime)
                elseif d.id == "smart_cache"   then
                    ugLine(10, string.format("  Write interval: %ds", nextLv * 3), colors.lime)
                end

                ugLine(11, ("  Thank you, " .. buyerName .. "!"):sub(1, w), colors.yellow)
                os.sleep(3)
            else
                ugBanner("Payment Failed")
                ugLine(5, ("  " .. (err or "Unknown error")):sub(1, w), colors.red)
                ugLine(6, "  No upgrade was applied.",                    colors.gray)
                ugLine(7, "  Coins were not moved.",                       colors.lightGray)
                os.sleep(2.5)
            end
            return
        end
    end
end

-- ── Main upgrade flow (called by [P] key in startup.lua) ─────────────────────
-- `router`: the Ender Router peripheral, used to broadcast INVOICE packets.
-- Blocks until the player exits with [B].  All other parallel coroutines
-- (mesh packet handler, miner, monitor) continue to run normally.
function upgrades.runUpgradeFlow(router)
    local state = loadState()

    -- First-time: prompt operator to configure the treasury wallet
    if type(state.treasury) ~= "string" or #state.treasury ~= 128 then
        if not setupTreasury(state) then
            ugCls(); return
        end
        state = loadState()   -- reload after treasury save
    end

    -- Identify the buyer by Ami-DNS name
    ugBanner("Node Upgrades")
    ugLine(5, "  Enter your Ami-DNS name:", colors.white)
    ugRule(6)
    term.setCursorPos(1, 7); term.setTextColor(colors.white)
    io.write("  Name > ")
    local buyerName = read()
    buyerName = buyerName:gsub("^%s*(.-)%s*$", "%1")
    if #buyerName == 0 then ugCls(); return end

    local buyerAddr = ledger.lookupName(buyerName)
    if not buyerAddr then
        ugLine(9,  "  Name '" .. buyerName .. "' not found.", colors.red)
        ugLine(10, "  Register on a node first.",              colors.lightGray)
        os.sleep(2); ugCls(); return
    end
    ugLine(9, ("  Found: " .. buyerAddr:sub(1, 24) .. "..."):sub(1, term.getSize()), colors.green)
    os.sleep(0.6)

    -- Browse and buy loop
    local page       = 1
    local totalPages = math.ceil(#DEFS / PAGE_SIZE)
    while true do
        state = loadState()   -- always use freshest level data for display
        drawMenu(page, state)
        local _, key = os.pullEvent("key")

        if key == keys.b then
            break
        -- Page navigation: comma/period or left/right arrows
        elseif key == keys.period or key == keys.right then
            if page < totalPages then page = page + 1 end
        elseif key == keys.comma or key == keys.left then
            if page > 1 then page = page - 1 end
        else
            -- Number keys 1-5 select an item on the current page
            local numMap = {
                [keys.one]  =1, [keys.two]  =2, [keys.three]=3,
                [keys.four] =4, [keys.five] =5,
            }
            local pick = numMap[key]
            if pick then
                local defIdx = (page - 1) * PAGE_SIZE + pick
                if defIdx <= #DEFS then
                    doPurchase(router, state, defIdx, buyerAddr, buyerName)
                end
            end
        end
    end

    -- Restore terminal to plain node state
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
    term.clear()
    term.setCursorPos(1, 1)
    print("=====================================")
    print("  AmiCoin Node -- Upgrade shop closed")
    print("=====================================")
    print("[Upgrades] Returned to node shell.")
    print("[Tip] Press U to update  |  P for Upgrade Shop")
end

return upgrades
