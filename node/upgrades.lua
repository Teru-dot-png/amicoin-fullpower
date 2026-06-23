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
-- upgrades.json schema (plaintext; the file itself is XTEA-encrypted on disk):
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
local xtea   = require("xtea")

local upgrades = {}

-- ── Constants ─────────────────────────────────────────────────────────────────
local DATA_FILE    = "/data/upgrades.json"
local SHOP_CHANNEL = 1338   -- plaintext invoice / ACK channel
local ACK_TIMEOUT  = 120    -- seconds to wait for PAYMENT_ACK
local PAGE_SIZE    = 5      -- upgrades shown per menu page
local MAX_LEVEL    = 10     -- default hard cap; individual upgrades may override

-- Per-upgrade max levels. Defaults to MAX_LEVEL when absent.
local UPGRADE_MAX = {
    amidecode = 4,   -- AMIdecode: Fallout-style hacking, max level 4
}
local function upgradeMax(id)
    return UPGRADE_MAX[id] or MAX_LEVEL
end

-- Compound-interest ceiling: interest is computed on at most this many uAMI.
local CI_BALANCE_CAP = 1000000000   -- 1,000 AMI cap
-- Compound-interest trigger: fires every N ticks.
local CI_TICK_INTERVAL = 10

-- ── Thermal constants (Stage 3) ─────────────────────────────────────────────────────
local THERMAL_AMBIENT   = 30    -- base ambient temp in degC
local THERMAL_HEAT_PER_OC  = 28 -- degC added per overclock level
local THERMAL_COOL_PER_LV  = 28 -- degC removed per air_cooler level
local THERMAL_JITTER_MAX   = 3  -- cosmetic fluctuation range +/- degC

-- ── Upgrade definitions ───────────────────────────────────────────────────────
-- short: max 12 chars (fits the menu column)
-- desc:  one-line effect summary
--
-- RETIRED upgrades are hidden from the shop but grandfathered: their levels and
-- effects persist forever on nodes that already own them.
local RETIRED_IDS = {
    "priority_ping", "smart_cache", "collision_fix", "dns_longevity", "hb_extender",
}
local RETIRED_SET = {}
for _, id in ipairs(RETIRED_IDS) do RETIRED_SET[id] = true end

local DEFS = {
    {
        id    = "miner_boost",
        name  = "Overclocked Miner",
        short = "OvrclkMiner",
        desc  = "+20% mining payout multiplier per level (max 3.0x).",
    },
    {
        id    = "mint_surge",
        name  = "Mint Surge",
        short = "MintSurge",
        desc  = "Bonus 2x reward tick every 80-8*(lv-1) min (Lv1=80m, Lv10=8m).",
    },
    {
        id    = "fee_snatcher",
        name  = "Routing Fee & Vault Yield",
        short = "FeeVaultYld",
        desc  = "100uAMI/lv per CONSOLIDATE + 5uAMI/tick/vault per level.",
    },
    {
        id    = "transfer_toll",
        name  = "Transfer Toll",
        short = "XferToll",
        desc  = "50uAMI per level skimmed from every TRANSFER this node routes.",
    },
    {
        id    = "wallet_bonus",
        name  = "Wallet Bonus",
        short = "WalletBonus",
        desc  = "+1uAMI/tick per active wallet per level credited to treasury.",
    },
    -- Stage 1 new upgrades
    {
        id    = "mint_echo",
        name  = "Mint Echo",
        short = "MintEcho",
        desc  = "Treasury earns floor(rate*0.05*lv) uAMI extra per mint tick.",
    },
    {
        id    = "casino_rake",
        name  = "Casino Rake",
        short = "CasinoRake",
        desc  = "Skim floor(bet*0.001*lv) uAMI from AmiCasino bets via this node.",
    },
    {
        id    = "compound_interest",
        name  = "Compound Interest",
        short = "CompoundInt",
        desc  = "Every 10 ticks: treasury += floor(min(bal,1BAMT)*0.0001*lv).",
    },
    {
        id    = "mega_burn",
        name  = "Mega Burn",
        short = "MegaBurn",
        desc  = "BURN 5AMI/lv. Base mint becomes floor(rate*1.05^lv) pre-OC.",
        burn  = true,   -- purchase burns to unspendable address, no treasury
    },
    {
        id    = "sovereign_node",
        name  = "Sovereign Node",
        short = "SovereNode",
        desc  = "+floor(rate*0.1*lv)/tick per loyal wallet (active+registered).",
    },
    {
        id    = "prestige_crown",
        name  = "Prestige Crown",
        short = "PrestigeCrn",
        desc  = "BURN 0.2AMI/lv. Crown suffix on node name + crown_gold theme@Lv5.",
        burn  = true,
    },
    -- Stage 2: AMIdecode hacking minigame
    {
        id    = "amidecode",
        name  = "AMIdecode",
        short = "AMIdecode",
        desc  = "Press [T]: hack for a temp mining boost. Lv*30min. Max Lv4.",
    },
    -- Stage 3: thermal cooling upgrades
    {
        id    = "air_cooler",
        name  = "Air Cooler",
        short = "AirCooler",
        desc  = "Reduces node temp by 28C/level. Keeps mining under 300C.",
    },
    {
        id    = "liquid_cooling",
        name  = "Liquid Cooling",
        short = "LiquidCool",
        desc  = "Reduces yield penalty at 100-300C by 10%/level. Lv10 removes penalty.",
    },
    -- Cosmetics
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

-- ── Pricing ─────────────────────────────────────────────────────────────────────────────────
-- Per-upgrade cost curves:
--   miner_boost, mint_surge : exponential 1->100 AMI (1M * 100^((lv-1)/9))
--   fee_snatcher, transfer_toll : flat 200,000 uAMI per level (0.2 AMI, max 2 AMI)
--   wallet_bonus               : flat 100,000 uAMI per level (0.1 AMI, max 1 AMI)
--   matrix_ui, genesis         : flat  50,000 uAMI per level (0.05 AMI, max 0.5 AMI)
local COST_TABLE = {
    miner_boost         = function(lv) return math.floor(1000000 * (100 ^ ((lv-1)/9))) end,
    mint_surge          = function(lv) return math.floor(1000000 * (100 ^ ((lv-1)/9))) end,
    fee_snatcher        = function(lv) return 200000 * lv end,
    transfer_toll       = function(lv) return 200000 * lv end,
    wallet_bonus        = function(lv) return 100000 * lv end,
    mint_echo           = function(lv) return 500000 * lv end,   -- 0.5 AMI/lv
    casino_rake         = function(lv) return 300000 * lv end,   -- 0.3 AMI/lv
    compound_interest   = function(lv) return 2000000 * lv end,  -- 2 AMI/lv
    mega_burn           = function(lv) return 5000000 * lv end,  -- BURN 5 AMI/lv
    sovereign_node      = function(lv) return 1000000 * lv end,  -- 1 AMI/lv
    prestige_crown      = function(lv) return 200000 * lv end,   -- BURN 0.2 AMI/lv
    amidecode           = function(lv) return 5000000 * lv end,  -- 5 AMI/lv, max 20 AMI at lv4
    air_cooler          = function(lv) return 500000 * lv end,   -- 0.5 AMI/lv
    liquid_cooling      = function(lv) return 500000 * lv end,   -- 0.5 AMI/lv
    matrix_ui           = function(lv) return  50000 * lv end,
    genesis             = function(lv) return  50000 * lv end,
}

local function calcCost(id, level)
    if level < 1 or level > MAX_LEVEL then return nil end
    local fn = COST_TABLE[id]
    if fn then return fn(level) end
    return nil  -- retired upgrades are not for sale
end

-- Exposed so startup.lua / UI can display the curve without reimplementing it.
upgrades.getCost = calcCost

-- ── Node-key loader ─────────────────────────────────────────────────────────
-- Reads the same 32-hex-char key that startup.lua generates on first boot at
-- /data/node_key.txt.  That file lives in /data/ which is NOT overwritten by
-- code updates, so the key survives restarts and upgrades.
local _nodeKey = nil
local function loadNodeKey()
    if _nodeKey then return _nodeKey end
    local keyFile = "/data/node_key.txt"
    if not fs.exists(keyFile) then
        -- startup.lua hasn't run yet (shouldn't happen in normal flow).
        -- Derive a deterministic fallback from the computer ID so the node
        -- can still save state; startup.lua will overwrite with its own key
        -- on the very next boot, at which point loadState() will fall back
        -- to the plaintext migration path and re-encrypt with the real key.
        local seed = tostring(os.getComputerID())
        local tmp = ""
        for i = 1, 32 do
            local b = (seed:byte((i - 1) % #seed + 1) * 31 + i * 17) % 16
            tmp = tmp .. string.format("%x", b)
        end
        _nodeKey = tmp
        return _nodeKey
    end
    local f = fs.open(keyFile, "r")
    local k = f.readAll():gsub("%s", "")
    f.close()
    if #k ~= 32 then
        -- Corrupt key file; reset so startup.lua regenerates it on next boot.
        _nodeKey = string.rep("0", 32)
    else
        _nodeKey = k
    end
    return _nodeKey
end

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
        local t = nil
        -- First attempt: try to decrypt with node key (normal path after first save).
        local ok, plain = pcall(xtea.decrypt, raw, loadNodeKey())
        if ok and type(plain) == "string" then
            t = textutils.unserialiseJSON(plain)
        end
        -- Fallback: try raw plaintext JSON (migration from unencrypted file).
        if type(t) ~= "table" then
            t = textutils.unserialiseJSON(raw)
            if type(t) == "table" then
                print("[Upgrades] Migrating upgrades.json to encrypted format.")
            end
        end
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
    local json = textutils.serialiseJSON(_state)
    local cipher = xtea.encrypt(json, loadNodeKey())
    local f = fs.open(DATA_FILE, "w")
    f.write(cipher); f.close()
end

local function getLevel(id)
    local lv = loadState().levels[id] or 0
    -- Clamp to per-upgrade maximum (most are 10; amidecode is 4).
    return math.max(0, math.min(upgradeMax(id), math.floor(lv)))
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

-- 3. Mint Surge: cooldown in seconds between bonus 2x ticks.
-- Lv0 = disabled (0).  Lv1 = 80 min, Lv10 = 8 min.
-- Formula: (80 - 8*(level-1)) * 60  seconds.
function upgrades.getMintSurgeCooldown()
    local lv = getLevel("mint_surge")
    if lv == 0 then return 0 end
    return (80 - 8 * (lv - 1)) * 60
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

-- 6. Routing Fee Snatcher (reworked): per-CONSOLIDATE_IN fee + vault yield per tick.
-- Consolidate fee: 100 uAMI per level (unchanged).
-- Vault yield: +5 uAMI per level per active vault lock on this node, per tick.
function upgrades.getFeeSnatchAmount()
    return getLevel("fee_snatcher") * 100
end
function upgrades.getVaultYieldPerTick()
    return getLevel("fee_snatcher") * 5
end

-- 7. Heartbeat Extender (GRANDFATHERED): active-wallet TTL in seconds.
-- Kept for nodes that already own it; hidden from shop.
-- Base 90s + 9s per level → max 180s at lv10.
function upgrades.getHeartbeatTTL()
    return 90 + 9 * getLevel("hb_extender")
end

-- 8. DNS Cache Longevity (GRANDFATHERED): integer multiplier on local DNS record TTL.
-- Kept for nodes that already own it; hidden from shop.
function upgrades.getDnsLongevityMult()
    return math.max(1, getLevel("dns_longevity"))
end

-- NEW: Transfer Toll -- 50 uAMI per level per TRANSFER routed through this node.
-- Comes from the sender as an extra routing charge after the transfer completes.
-- Level 0 = 0 (disabled). Level 10 = 500 uAMI per transfer.
function upgrades.getTransferTollAmount()
    return getLevel("transfer_toll") * 50
end

-- NEW: Wallet Bonus -- +1 uAMI per tick per active wallet per level credited to treasury.
-- Level 0 = 0 (disabled). Level 10 = 10 uAMI/tick/wallet.
function upgrades.getWalletBonusPerTick()
    return getLevel("wallet_bonus") * 1
end

-- NEW Stage 1 effects

-- Mint Echo: treasury earns extra per mint tick.
-- floor(rate * 0.05 * lv) uAMI/tick. MAX: floor(25 * 0.05 * 10) = 12 uAMI/tick.
function upgrades.getMintEchoPerTick(rate)
    local lv = getLevel("mint_echo")
    if lv == 0 then return 0 end
    return math.floor(rate * 0.05 * lv)
end

-- Casino Rake: level used by casino; exposed here for STATS advertisement.
-- floor(bet * 0.001 * lv) per bet, settled in batch at casino.
function upgrades.getCasinoRakeLevel()
    return getLevel("casino_rake")
end

-- Compound Interest: per-tick interest trigger info.
function upgrades.getCompoundInterestLevel() return getLevel("compound_interest") end
function upgrades.getCITickInterval()         return CI_TICK_INTERVAL end
function upgrades.getCIBalanceCap()           return CI_BALANCE_CAP end

-- Compound interest yield for one trigger event.
-- treasury earns floor(min(treasury_bal, CAP) * 0.0001 * lv)
-- MAX: floor(1,000,000,000 * 0.0001 * 10) = 1,000,000 uAMI per trigger
function upgrades.calcCompoundInterest(treasuryBal)
    local lv = getLevel("compound_interest")
    if lv == 0 then return 0 end
    local base = math.min(treasuryBal, CI_BALANCE_CAP)
    return math.floor(base * 0.0001 * lv)
end

-- Mega Burn: base mint multiplier BEFORE Overclock.
-- floor(rate * 1.05^lv). Lv0 = rate unchanged; Lv10 = rate * 1.6289.
function upgrades.getMegaBurnMultiplier()
    local lv = getLevel("mega_burn")
    if lv == 0 then return 1.0 end
    return 1.05 ^ lv
end

-- Sovereign Node: extra per-tick yield per loyal wallet (active + DNS-registered here).
-- floor(rate * 0.1 * lv) uAMI/tick per loyal wallet. MAX: floor(25*0.1*10)=25 uAMI/tick/wallet.
function upgrades.getSovereignBonusPerTick(rate)
    local lv = getLevel("sovereign_node")
    if lv == 0 then return 0 end
    return math.floor(rate * 0.1 * lv)
end

-- Prestige Crown: crown level; node name suffix and theme.
function upgrades.getCrownLevel() return getLevel("prestige_crown") end

local CROWN_THEMES = { [5]="crown_gold", [6]="crown_gold", [7]="crown_gold",
                       [8]="crown_gold", [9]="crown_gold", [10]="crown_gold" }
function upgrades.getCrownTheme()
    return CROWN_THEMES[getLevel("prestige_crown")]   -- nil below Lv5
end

-- Returns the display node name with crown suffix appended if Prestige Crown >= 1.
function upgrades.getCrownedName(baseName)
    if getLevel("prestige_crown") >= 1 then
        return baseName .. " [*]"
    end
    return baseName
end

-- Combined theme: prestige crown overrides matrix_ui if active.
function upgrades.getActiveTheme()
    local crown = upgrades.getCrownTheme()
    if crown then return crown end
    return upgrades.getMatrixTheme()
end

-- ── Thermal system (Stage 3) effect API ───────────────────────────────────────────────
-- Compute current node temperature in degC with optional jitter.
-- net_temp = AMBIENT + overclock_lv*HEAT_PER_OC - air_cooler_lv*COOL_PER_LV + jitter
-- jitter is a small cosmetic fluctuation recomputed on each call.
function upgrades.computeNetTemp(withJitter)
    local oc_lv  = getLevel("miner_boost")
    local ac_lv  = getLevel("air_cooler")
    local base   = THERMAL_AMBIENT + oc_lv * THERMAL_HEAT_PER_OC - ac_lv * THERMAL_COOL_PER_LV
    local jitter = withJitter and math.random(-THERMAL_JITTER_MAX, THERMAL_JITTER_MAX) or 0
    return base + jitter
end

-- Compute thermal yield factor and the flag indicating a hard shutoff.
-- Returns: factor (0.0-1.0), shutoff (bool), penalty_pct (0, 0.25, or 0.50 before mitigation)
function upgrades.computeThermalFactor()
    local lc_lv    = getLevel("liquid_cooling")
    local mitigation = math.min(1.0, lc_lv * 0.10)  -- Lv10 = 1.0 (full removal)
    local temp     = upgrades.computeNetTemp(false)   -- no jitter in miner pipeline (deterministic)

    if temp >= 300 then
        -- Hard shutoff: liquid cooling cannot lift this cap.
        return 0.0, true, 0.50
    elseif temp >= 200 then
        local penalty = 0.50 * (1.0 - mitigation)
        return 1.0 - penalty, false, 0.50
    elseif temp >= 100 then
        local penalty = 0.25 * (1.0 - mitigation)
        return 1.0 - penalty, false, 0.25
    else
        return 1.0, false, 0.0
    end
end

-- Air Cooler level (exposed for display).
function upgrades.getAirCoolerLevel()    return getLevel("air_cooler") end
-- Liquid Cooling level (exposed for display).
function upgrades.getLiquidCoolingLevel() return getLevel("liquid_cooling") end

-- Grandfathered summary: list of retired upgrades this node owns (level > 0).
-- Called on boot from startup.lua to log/display preserved effects.
function upgrades.getGrandfatheredSummary()
    local st = loadState()
    local owned = {}
    for _, id in ipairs(RETIRED_IDS) do
        local lv = math.max(0, math.min(MAX_LEVEL, math.floor(st.levels[id] or 0)))
        if lv > 0 then
            owned[#owned + 1] = id .. " Lv" .. lv
        end
    end
    return owned
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
    -- Build a 128-bit transaction ID (four independent 32-bit FNV1a hashes)
    -- to make tx_id forgery via channel-1338 broadcast infeasible.
    local base = tostring(os.epoch("utc")) .. tostring(os.getComputerID())
    return fnv1a(base .. tostring(math.random(0, 2147483647)) .. "a") ..
           fnv1a(base .. tostring(math.random(0, 2147483647)) .. "b") ..
           fnv1a(base .. tostring(math.random(0, 2147483647)) .. "c") ..
           fnv1a(base .. tostring(math.random(0, 2147483647)) .. "d")
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
                local c = calcCost(d.id, lv + 1)
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
-- All-zeros address used as a coin sink when the buyer IS the treasury.
-- Nobody holds the private key for this address, so coins sent here are
-- permanently removed from circulation (burned).
local BURN_ADDRESS = string.rep("0", 128)

local function broadcastAndWait(router, treasury, playerAddr, playerName, def, cost, txId)
    -- If the buyer is the node operator (treasury == buyer), routing the
    -- payment to the treasury would be a no-op self-transfer.  Instead route
    -- to the burn address so coins are actually destroyed.
    local payAddr = (playerAddr == treasury) and BURN_ADDRESS or treasury

    local invoice = textutils.serialiseJSON({
        type      = "INVOICE",
        to        = playerAddr,
        tx_id     = txId,
        shop_addr = payAddr,
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
                        -- The wallet's PAYMENT_ACK is the confirmation the transfer
                        -- succeeded. We trust it here because the payment may settle
                        -- on a different node than this one (common in multi-node
                        -- setups), so a local ledger re-check would produce false
                        -- negatives. The tx_id is 128-bit so forging a matching ACK
                        -- on channel 1338 is not feasible.
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

    if lv >= upgradeMax(d.id) then
        ugBanner("Already Maxed!")
        ugLine(5, "  " .. d.name,                      colors.lime)
        ugLine(6, string.format("  Level %d / %d -- maximum reached.",
            upgradeMax(d.id), upgradeMax(d.id)), colors.gray)
        os.sleep(2); return
    end

    local nextLv  = lv + 1
    local cost    = calcCost(d.id, nextLv)
    local isBurn  = d.burn == true

    -- Confirm screen
    ugBanner("Confirm Upgrade")
    ugRule(4)
    ugLine(5, ("  Upgrade : " .. d.name):sub(1, w),                 colors.orange)
    ugLine(6,  string.format("  Level   : %d  ->  %d  / %d", lv, nextLv, upgradeMax(d.id)), colors.white)
    ugLine(7, ("  Effect  : " .. d.desc):sub(1, w),                  colors.lightGray)
    ugRule(8)
    if isBurn then
        ugLine(9, string.format("  BURN    : %.4f AMI (coins destroyed)", cost / 1000000), colors.red)
        ugLine(10, ("  = " .. cost .. " uAMI"):sub(1, w), colors.gray)
    else
        ugLine(9,   string.format("  Cost    : %.4f AMI", cost / 1000000), colors.yellow)
        ugLine(10, ("  = " .. cost .. " uAMI"):sub(1, w),                 colors.gray)
    end
    ugRule(11)
    ugLine(12, "  [Y] Confirm    [N] Cancel",                         colors.orange)

    while true do
        local _, key = os.pullEvent("key")
        if key == keys.n then return end
        if key == keys.y then
            local txId = newUID()
            pcall(function() router.open(SHOP_CHANNEL) end)

            local ok, err
            if isBurn then
                -- Burn upgrades: coins go to the unspendable zero address,
                -- not to any treasury. We route the invoice payment to BURN_ADDRESS.
                -- Nobody holds that key; coins are permanently destroyed.
                ok, err = broadcastAndWait(
                    router, BURN_ADDRESS, buyerAddr, buyerName, d, cost, txId)
            else
                ok, err = broadcastAndWait(
                    router, state.treasury, buyerAddr, buyerName, d, cost, txId)
            end

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

-- ── Opus shop data API (read-only catalog + purchase wrappers) ───────────────
-- These power the Opus UI upgrade shop without duplicating purchase/payment
-- logic. Additive only; all existing flow logic above is unchanged.

-- Read-only catalog snapshot: one entry per upgrade with live level/cost.
function upgrades.getCatalog()
    local state = loadState()
    local out   = {}
    for idx, d in ipairs(DEFS) do
        local lv    = state.levels[d.id] or 0
        local mx    = upgradeMax(d.id)
        local maxed = lv >= mx
        out[#out + 1] = {
            idx      = idx,
            id       = d.id,
            name     = d.name,
            short    = d.short,
            desc     = d.desc,
            burn     = d.burn == true,
            level    = lv,
            max      = mx,
            maxed    = maxed,
            nextCost = maxed and 0 or calcCost(d.id, lv + 1),  -- uAMI
        }
    end
    return out
end

-- True when the treasury wallet hasn't been configured yet (first-run setup).
function upgrades.needsTreasurySetup()
    local state = loadState()
    return type(state.treasury) ~= "string" or #state.treasury ~= 128
end

-- Run the term-based first-run treasury wizard. Returns true on success.
function upgrades.setupTreasuryFlow()
    local state = loadState()
    return setupTreasury(state) and true or false
end

-- Resolve an Ami-DNS name to an address (or nil) + the trimmed name.
function upgrades.resolveBuyer(name)
    if type(name) ~= "string" then return nil end
    name = name:gsub("^%s*(.-)%s*$", "%1")
    if #name == 0 then return nil end
    return ledger.lookupName(name), name
end

-- Purchase one upgrade by catalog index, reusing the EXACT existing term-based
-- confirm + INVOICE/PAYMENT_ACK flow (doPurchase). doPurchase draws its own
-- confirm/wait screens and applies the level on success.
function upgrades.purchaseByIndex(router, defIdx, buyerAddr, buyerName)
    if type(defIdx) ~= "number" or defIdx < 1 or defIdx > #DEFS then return end
    local state = loadState()
    doPurchase(router, state, defIdx, buyerAddr, buyerName)
end

-- Returns formatted lines for every active (level > 0) upgrade.
-- Used by monitorLoop in startup.lua to render the upgrades panel.
function upgrades.getActiveSummary()
    local st    = loadState()
    local lines = {}
    for _, d in ipairs(DEFS) do
        local lv = st.levels[d.id] or 0
        if lv > 0 then
            lines[#lines + 1] = string.format("%-12s Lv%d", d.short, lv)
        end
    end
    -- Append AMIdecode boost status if active. Route the multiplier through the
    -- module table (upgrades.getAmdBoostMultiplier) - calling the file-local
    -- loadAmdState directly here is a forward reference (it's declared lower in
    -- the file) and would resolve to a nil global at runtime.
    local br, cd = upgrades.getAmdStatus()
    if br > 0 then
        lines[#lines + 1] = string.format("AMIdecode  BOOST x%.2f %dm", upgrades.getAmdBoostMultiplier(), math.floor(br/60))
    elseif cd > 0 then
        lines[#lines + 1] = string.format("AMIdecode  CD %dm", math.floor(cd/60))
    end
    return lines
end

-- ── AMIdecode Stage 2 ─────────────────────────────────────────────────────────
-- Persistent boost/cooldown state lives at /data/amidecode.json so it
-- survives reboots (written with temp-file-then-rename).
-- Schema: { boost_mult=2.5, boost_end=<epoch_s>, cooldown_end=<epoch_s> }
local AMIDECODE_FILE = "/data/amidecode.json"
local AMIDECODE_TMP  = "/data/amidecode.json.tmp"

-- AMIdecode tunable constants
local AMD_WORDS      = 8    -- candidate count shown per game
local AMD_WORDLEN    = 6    -- chars per candidate (uppercase letters)
local AMD_GUESSES    = 3    -- max guesses per game
local AMD_MULT_BASE  = 2.0  -- base multiplier on solve
local AMD_MULT_MAX   = 3.0  -- cap
local AMD_BONUS_1ST  = 0.5  -- extra if solved on first guess
local AMD_BONUS_FAST = 0.25 -- extra if solved within AMD_FAST_SEC seconds
local AMD_FAST_SEC   = 8    -- seconds threshold for fast-solve bonus
local AMD_COOLDOWN_EXTRA = 30 * 60  -- extra cooldown seconds appended after boost

local function loadAmdState()
    -- Recover from a crashed mid-write by checking for .tmp first.
    if fs.exists(AMIDECODE_TMP) and not fs.exists(AMIDECODE_FILE) then
        fs.move(AMIDECODE_TMP, AMIDECODE_FILE)
    end
    if not fs.exists(AMIDECODE_FILE) then
        return { boost_mult=1.0, boost_end=0, cooldown_end=0 }
    end
    local f = fs.open(AMIDECODE_FILE, "r")
    local t = textutils.unserialiseJSON(f.readAll())
    f.close()
    if type(t) ~= "table" then
        return { boost_mult=1.0, boost_end=0, cooldown_end=0 }
    end
    return {
        boost_mult   = tonumber(t.boost_mult)   or 1.0,
        boost_end    = tonumber(t.boost_end)    or 0,
        cooldown_end = tonumber(t.cooldown_end) or 0,
    }
end

local function saveAmdState(st)
    if not fs.exists("/data") then fs.makeDir("/data") end
    local f = fs.open(AMIDECODE_TMP, "w")
    f.write(textutils.serialiseJSON(st)); f.close()
    if fs.exists(AMIDECODE_FILE) then fs.delete(AMIDECODE_FILE) end
    fs.move(AMIDECODE_TMP, AMIDECODE_FILE)
end

-- Returns the current active boost multiplier (1.0 if no active boost).
function upgrades.getAmdBoostMultiplier()
    if getLevel("amidecode") == 0 then return 1.0 end
    local st  = loadAmdState()
    local now = os.epoch("utc") / 1000
    if now < st.boost_end and st.boost_mult > 1.0 then
        return st.boost_mult
    end
    return 1.0
end

-- Returns remaining boost seconds (0 if none), remaining cooldown seconds (0 if none).
function upgrades.getAmdStatus()
    local st  = loadAmdState()
    local now = os.epoch("utc") / 1000
    local boost_rem    = math.max(0, math.floor(st.boost_end    - now))
    local cooldown_rem = math.max(0, math.floor(st.cooldown_end - now))
    -- If boost has expired but cooldown hasn't, boost_rem = 0 correctly.
    if boost_rem > 0 then
        return boost_rem, 0   -- boost is active; cooldown not started yet
    end
    return 0, cooldown_rem
end

-- ── AMIdecode minigame ────────────────────────────────────────────────────────
local function mkWord()
    local s = ""
    for _ = 1, AMD_WORDLEN do
        -- uppercase letters A-Z only (CC char range 65-90)
        s = s .. string.char(math.random(65, 90))
    end
    return s
end

local function likeness(guess, secret)
    local count = 0
    for i = 1, #secret do
        if guess:sub(i,i) == secret:sub(i,i) then count = count + 1 end
    end
    return count
end

-- Called by the [T] key handler in startup.lua.
-- Blocks while the minigame runs. Result stored in persisted AMD state.
function upgrades.runAmdMinigame()
    local lv = getLevel("amidecode")
    if lv == 0 then
        term.setTextColor(colors.red)
        print("[AMIdecode] Upgrade not purchased. Press [P] to buy.")
        term.setTextColor(colors.white)
        return
    end

    local now  = os.epoch("utc") / 1000
    local br, cd = upgrades.getAmdStatus()
    if cd > 0 then
        term.setTextColor(colors.orange)
        print(string.format("[AMIdecode] Cooling down. %dm%02ds remaining.",
            math.floor(cd/60), cd % 60))
        term.setTextColor(colors.white)
        return
    end
    if br > 0 then
        local st = loadAmdState()
        term.setTextColor(colors.lime)
        print(string.format("[AMIdecode] Boost active! x%.2f, %dm%02ds remaining.",
            st.boost_mult, math.floor(br/60), br % 60))
        term.setTextColor(colors.white)
        return
    end

    -- Generate candidates
    math.randomseed(os.epoch("utc") + os.getComputerID() * 1337)
    local secret = mkWord()
    local words  = { secret }
    while #words < AMD_WORDS do
        local w = mkWord()
        local dup = false
        for _, x in ipairs(words) do if x == w then dup = true; break end end
        if not dup then words[#words + 1] = w end
    end
    -- Fisher-Yates shuffle
    for i = #words, 2, -1 do
        local j = math.random(i)
        words[i], words[j] = words[j], words[i]
    end

    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.lime)
    term.clear(); term.setCursorPos(1, 1)
    print("===================================")
    print("  AMIdecode v" .. lv .. "  //  ACCESS TERMINAL  ")
    print("===================================")
    print("ATTEMPTS REMAINING: " .. AMD_GUESSES)
    print("SELECT PASSWORD:")
    print("")
    for i, w in ipairs(words) do
        term.setTextColor(colors.lime)
        print(string.format("  [%d] %s", i, w))
    end
    print("")
    term.setTextColor(colors.gray)
    print("Press number key (1-8) to guess.")
    term.setTextColor(colors.white)

    local guessesLeft = AMD_GUESSES
    local startTime   = now
    local firstGuess  = true

    while guessesLeft > 0 do
        local pick = nil
        while not pick do
            local _, key = os.pullEvent("key")
            local n = nil
            if     key == keys.one   then n=1
            elseif key == keys.two   then n=2
            elseif key == keys.three then n=3
            elseif key == keys.four  then n=4
            elseif key == keys.five  then n=5
            elseif key == keys.six   then n=6
            elseif key == keys.seven then n=7
            elseif key == keys.eight then n=8
            end
            if n and n >= 1 and n <= AMD_WORDS then pick = n end
        end

        local guess   = words[pick]
        local lk      = likeness(guess, secret)
        guessesLeft   = guessesLeft - 1

        if guess == secret then
            -- SOLVE: compute multiplier with bonuses
            local elapsed = os.epoch("utc") / 1000 - startTime
            local mult    = AMD_MULT_BASE
            if firstGuess              then mult = mult + AMD_BONUS_1ST  end
            if elapsed <= AMD_FAST_SEC then mult = mult + AMD_BONUS_FAST end
            mult = math.min(mult, AMD_MULT_MAX)

            local boostSecs = lv * 30 * 60
            local coolSecs  = boostSecs + AMD_COOLDOWN_EXTRA
            saveAmdState({
                boost_mult   = mult,
                boost_end    = now + boostSecs,
                cooldown_end = now + coolSecs,
            })
            term.setTextColor(colors.lime)
            print("")
            print(">>> ACCESS GRANTED <<<")
            print(string.format("  Password: %s   Likeness: %d/%d",
                guess, lk, AMD_WORDLEN))
            print(string.format("  Boost: x%.2f for %dm  (Cooldown %dm after)",
                mult, math.floor(boostSecs/60), math.floor(coolSecs/60)))
            term.setTextColor(colors.white)
            return
        else
            firstGuess = false
            term.setTextColor(colors.red)
            print(string.format("  '%s'  LIKENESS: %d/%d  Attempts left: %d",
                guess, lk, AMD_WORDLEN, guessesLeft))
            term.setTextColor(colors.white)
        end
    end

    -- FAIL: set cooldown, no boost
    local boostSecs = lv * 30 * 60
    local coolSecs  = boostSecs + AMD_COOLDOWN_EXTRA
    saveAmdState({ boost_mult=1.0, boost_end=0, cooldown_end=now+coolSecs })
    term.setTextColor(colors.red)
    print("")
    print(">>> ACCESS DENIED <<<")
    print("  Password was: " .. secret)
    print(string.format("  Cooldown: %dm", math.floor(coolSecs/60)))
    term.setTextColor(colors.white)
end

return upgrades
