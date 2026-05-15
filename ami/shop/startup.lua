-- /ami/shop/startup.lua
-- AmiStore v1.1 — Merchant Node entry point.
-- Run this on the Merchant Node computer: shell.run("/ami/shop/startup")
--
-- Requires the following peripherals (hardcoded sides — see shop_api.lua):
--   TOP:    3x3 Advanced Monitor
--   LEFT:   Printer
--   RIGHT:  meBridge (AE2CC)
--   BOTTOM: Inventory / Barrel (vending tray)
--   BACK:   Wired or Wireless Modem

package.path = package.path .. ";/ami/shop/?.lua"
local api = require("shop_api")
local ui  = require("shop_ui")

local SYNC_INTERVAL = 30   -- seconds between automatic inventory refreshes
local SHOP_CHANNEL  = 1338
local REPO_BASE     = "https://raw.githubusercontent.com/Teru-dot-png/amicoin-fullpower/refs/heads/main"

local UPDATE_FILES = {
    { src = "/shared/xtea.lua",       dst = "/shared/xtea.lua"       },
    { src = "/ami/shop/shop_api.lua", dst = "/ami/shop/shop_api.lua" },
    { src = "/ami/shop/shop_ui.lua",  dst = "/ami/shop/shop_ui.lua"  },
    { src = "/ami/shop/startup.lua",  dst = "/ami/shop/startup.lua"  },
}

-- ── Config helpers ────────────────────────────────────────────────────────────
local function loadCfg()   return api.loadConfig() end
local function saveCfg(c)  api.saveConfig(c) end

-- ── FNV-1a hash (for self-update fingerprint verification) ───────────────────
local function fnv1a(s)
    local hash = 2166136261
    for i = 1, #s do
        hash = bit32.bxor(hash, string.byte(s, i))
        hash = (hash * 16777619) % 4294967296
    end
    return string.format("%08x", hash)
end

-- ── Self-update ───────────────────────────────────────────────────────────────
local function selfUpdate()
    term.clear(); term.setCursorPos(1, 1)
    term.setTextColor(colors.yellow)
    print("AmiStore Self-Update")
    print("Downloading from GitHub...")
    print("")
    term.setTextColor(colors.white)

    local failed   = false
    local hashes   = {}

    for _, entry in ipairs(UPDATE_FILES) do
        io.write("  " .. entry.dst .. " ... ")
        local res = http.get(REPO_BASE .. entry.src)
        if not res then
            term.setTextColor(colors.red)
            print("FAILED (no response)")
            term.setTextColor(colors.white)
            failed = true
        else
            local content = res.readAll(); res.close()
            if #content < 64 then
                term.setTextColor(colors.red)
                print("FAILED (too short — 404?)")
                term.setTextColor(colors.white)
                failed = true
            else
                local hash = fnv1a(content)
                if fs.exists(entry.dst) then fs.delete(entry.dst) end
                local f = fs.open(entry.dst, "w")
                f.write(content); f.close()
                term.setTextColor(colors.green)
                print("OK  [" .. hash .. "]")
                term.setTextColor(colors.white)
                hashes[#hashes + 1] = hash
            end
        end
    end

    print("")
    if failed then
        term.setTextColor(colors.red)
        print("Update failed. Some files could not be downloaded.")
        print("AmiStore will continue running the old version.")
        term.setTextColor(colors.white)
        os.sleep(3)
    else
        local combined = table.concat(hashes, ":")
        term.setTextColor(colors.green)
        print("Update complete!")
        term.setTextColor(colors.yellow)
        print("Fingerprint : " .. fnv1a(combined))
        term.setTextColor(colors.white)
        print("Rebooting in 3 seconds...")
        os.sleep(3)
        os.reboot()
    end
end

-- ── Network listener ─────────────────────────────────────────────────────────
-- Runs in its own parallel coroutine; handles incoming buyer/seller packets.
local function networkLoop()
    local modem = api.getModem()
    if not modem then
        print("[AmiStore] WARNING: No modem on BACK — network disabled.")
        -- Yield forever so parallel.waitForAll doesn't abort.
        while true do os.pullEvent() end
    end

    while true do
        -- Filter to SHOP_CHANNEL messages only.
        local ev, _, ch, replyCh, wire = os.pullEvent("modem_message")
        if ch == SHOP_CHANNEL then
            local action = api.processWire(wire, replyCh)

            if action then
                local listings = api.getListings()
                local balance  = api.getShopBal()

                if action.type == "CONFIRM" and action.preview then
                    -- Show receipt preview on monitor, pause, then execute.
                    local order = action.order
                    ui.showReceiptPreview(
                        action.tx_id, "WTS",
                        order.item, order.qty,
                        order.price * order.qty)
                    os.sleep(3)   -- 3-second preview window
                    api.executeConfirm(action)
                end

                -- Sync inventory and redraw after any action.
                api.syncInventory()
                ui.drawShop(api.getListings(), api.getShopBal())
            end
        end
    end
end

-- ── Periodic inventory sync ────────────────────────────────────────────────────
local function syncLoop()
    while true do
        os.sleep(SYNC_INTERVAL)
        api.syncInventory()
        api.prunePendingOrders()
        ui.drawShop(api.getListings(), api.getShopBal())
    end
end

-- ── Keyboard input loop ────────────────────────────────────────────────────────
-- Handles [A]dmin, [R]eload, [Q]uit on the terminal.
local adminToken    = nil
local adminUnlocked = false

local function inputLoop()
    while true do
        local _, key = os.pullEvent("key")

        -- [A] — attempt admin login
        if key == keys.a and not adminUnlocked then
            term.setCursorPos(1, 1); term.clear()
            print("AmiStore Admin Login")
            print("Session token (printed at boot):")
            local inp = read("*")
            if inp == adminToken then
                adminUnlocked = true
                ui.setAdminUnlocked(true)
                local lst = api.getListings()
                local cfg = loadCfg()
                -- adminLoop blocks until [B]ack is pressed.
                ui.adminLoop(
                    lst, cfg,
                    function(l) api.saveListings(l) end,
                    function(c) saveCfg(c) end)
                adminUnlocked = false
                ui.setAdminUnlocked(false)
                -- Redraw storefront after returning from admin.
                api.syncInventory()
                ui.drawShop(api.getListings(), api.getShopBal())
            else
                print("Invalid token. Access denied.")
                os.sleep(1.5)
                ui.drawShop(api.getListings(), api.getShopBal())
            end

        -- [R] — manual refresh
        elseif key == keys.r then
            api.syncInventory()
            ui.drawShop(api.getListings(), api.getShopBal())

        -- [U] — self-update from GitHub
        elseif key == keys.u then
            selfUpdate()
            -- selfUpdate() only returns on failure; on success it reboots.
            ui.drawShop(api.getListings(), api.getShopBal())

        -- [Q] — graceful quit
        elseif key == keys.q then
            term.clear(); term.setCursorPos(1, 1)
            print("AmiStore stopped.")
            return
        end
    end
end

-- ── Boot sequence ─────────────────────────────────────────────────────────────
term.clear(); term.setCursorPos(1, 1)
print("============================================")
print("  AmiStore v1.1  —  Merchant Node Boot")
print("============================================")
print("")
print("Initialising peripherals...")

local shopAddr = api.init()

print("  Shop address : " .. shopAddr:sub(1, 16) .. "...")
print("  Monitor      : " .. (api.getMonitor() and "TOP [OK]"      or "TOP [MISSING]"))
print("  meBridge     : " .. (peripheral.isPresent("right")        and "RIGHT [OK]" or "RIGHT [--]"))
print("  Printer      : " .. (peripheral.isPresent("left")         and "LEFT [OK]"  or "LEFT [--]"))
print("  Inventory    : " .. (peripheral.isPresent("bottom")       and "BOTTOM [OK]" or "BOTTOM [--]"))
print("  Modem        : " .. (api.getModem() and "BACK [OK]"       or "BACK [MISSING]"))
print("")

adminToken = api.getSessionToken()
print("Admin session token (keep private):")
print("  " .. adminToken)
print("")

local listings = api.getListings()
print(string.format("Loaded %d listing(s).", #listings))
print("Starting in 3 seconds...")
os.sleep(3)

-- Initial draw
ui.init(api.getMonitor(), shopAddr)
api.syncInventory()
ui.drawShop(api.getListings(), api.getShopBal())

-- Run all three loops concurrently.
-- If inputLoop returns (user pressed Q), the others are killed automatically.
parallel.waitForAll(networkLoop, syncLoop, inputLoop)

term.clear(); term.setCursorPos(1, 1)
print("AmiStore shut down cleanly.")
