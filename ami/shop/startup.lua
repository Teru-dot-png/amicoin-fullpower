-- /ami/shop/startup.lua
-- AmiStore v1.1 — Merchant Node entry point.
-- Run this on the Merchant Node computer: shell.run("/ami/shop/startup")
--
-- Requires the following peripherals (hardcoded sides — see shop_api.lua):
--   TOP:    3x3 Advanced Monitor
--   LEFT:   Printer
--   RIGHT:  me_bridge (AE2CC)
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
    -- Register with nodes immediately (fire-and-forget, non-blocking).
    api.registerShop()
    -- First sync: runs right away inside the parallel coroutine so the
    -- main boot sequence never blocks on network calls.
    api.syncInventory()
    api.prunePendingOrders()
    ui.drawShop(api.getListings(), api.getShopBal())
    while true do
        os.sleep(SYNC_INTERVAL)
        api.syncInventory()
        api.prunePendingOrders()
        ui.drawShop(api.getListings(), api.getShopBal())
    end
end

-- ── Operator terminal menu ───────────────────────────────────────────────────
local function printMenu()
    term.setCursorPos(1, 1); term.clear()
    term.setTextColor(colors.orange)
    print("  AmiStore v1.1  —  Running")
    term.setTextColor(colors.gray)
    print("  ----------------------------------------")
    term.setTextColor(colors.white)
    print("  [A]  Admin panel")
    print("  [B]  Walk-up buy terminal")
    print("  [N]  Node manager")
    print("  [R]  Reload listings")
    print("  [U]  Self-update from GitHub")
    print("  [Q]  Quit")
    term.setTextColor(colors.gray)
    print("  ----------------------------------------")
    term.setTextColor(colors.white)
end

-- ── Keyboard input loop ────────────────────────────────────────────────────────
-- Handles [A]dmin, [B]uy, [N]odes, [R]eload, [U]pdate, [Q]uit on the terminal.
local adminToken    = nil
local adminUnlocked = false

local function inputLoop()
    while true do
        printMenu()
        local _, key = os.pullEvent("key")

        -- [A] — attempt admin login
        if key == keys.a and not adminUnlocked then
            term.setCursorPos(1, 1); term.clear()
            term.setTextColor(colors.orange)
            print("AmiStore Admin Login")
            term.setTextColor(colors.white)
            io.write("Password: ")
            local inp = read("*")
            if api.checkAdminPass(inp) then
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

        -- [B] — walk-up buy terminal
        elseif key == keys.b then
            term.setCursorPos(1, 1); term.clear()
            term.setTextColor(colors.orange)
            print("=== AmiStore  Walk-Up Buy ===")
            term.setTextColor(colors.white)
            print("")

            -- Show available WTS listings.
            local lst = api.getListings()
            local wts = {}
            for _, l in ipairs(lst) do
                if l.type == "WTS" and (l._stock or 0) > 0 then
                    wts[#wts + 1] = l
                end
            end
            if #wts == 0 then
                print("No items in stock right now.")
                os.sleep(2)
                ui.drawShop(api.getListings(), api.getShopBal())
            else
                for i, l in ipairs(wts) do
                    local short = (l.item:match(":(.+)$") or l.item)
                    print(string.format("  [%d] %-24s  %d uAMI  (x%d in stock)",
                        i, short, l.price, l._stock))
                end
                print("")
                io.write("Item number (or Enter to cancel): ")
                local iStr = io.read()
                local idx = tonumber(iStr)
                if idx and wts[idx] then
                    local chosen = wts[idx]
                    io.write("Quantity: ")
                    local qty = math.max(1, math.floor(tonumber(io.read() or "1") or 1))
                    print("")
                    io.write("Your address or player name: ")
                    local raw = (io.read() or ""):gsub("%s", "")
                    local buyerAddr = raw
                    -- Resolve name → address if it looks like a name (not 128-hex).
                    if #raw ~= 128 then
                        io.write("  Resolving '" .. raw .. "'... ")
                        buyerAddr = api.lookupName(raw)
                        if buyerAddr then
                            print("OK")
                        else
                            term.setTextColor(colors.red)
                            print("Not found. Check spelling or use raw address.")
                            term.setTextColor(colors.white)
                            os.sleep(2)
                            ui.drawShop(api.getListings(), api.getShopBal())
                            goto continue_input
                        end
                    end
                    local totalPrice = chosen.price * qty
                    print("")
                    term.setTextColor(colors.yellow)
                    print(string.format("Order : %d x %s", qty,
                        (chosen.item:match(":(.+)$") or chosen.item)))
                    print(string.format("Total : %d uAMI  (%.4f AMI)",
                        totalPrice, totalPrice / 1000000))
                    term.setTextColor(colors.white)
                    print("")
                    print("Ask the player to send " .. totalPrice .. " uAMI")
                    print("to shop address:")
                    print("  " .. api.getShopAddr():sub(1, 32) .. "...")
                    print("")
                    io.write("Confirm payment received? [Y/N]: ")
                    local conf = (io.read() or ""):lower():sub(1, 1)
                    if conf == "y" then
                        local ok, txId, _ = api.localBuy(buyerAddr, chosen, qty)
                        if ok then
                            local vok, verr = api.localBuyConfirm(txId)
                            if vok then
                                term.setTextColor(colors.green)
                                print("Done! Item exported to BOTTOM tray.")
                            else
                                term.setTextColor(colors.red)
                                print("Failed: " .. (verr or "unknown error"))
                            end
                            term.setTextColor(colors.white)
                        end
                    else
                        print("Cancelled.")
                    end
                    os.sleep(2)
                    api.syncInventory()
                    ui.drawShop(api.getListings(), api.getShopBal())
                else
                    print("Cancelled.")
                    os.sleep(1)
                    ui.drawShop(api.getListings(), api.getShopBal())
                end
            end
            ::continue_input::

        -- [N] — node manager
        elseif key == keys.n then
            while true do
                term.setCursorPos(1, 1); term.clear()
                term.setTextColor(colors.orange)
                print("=== AmiStore  Node Manager ===")
                term.setTextColor(colors.white)
                print("")
                local cfg = loadCfg()
                if #cfg.nodes == 0 then
                    print("  (no nodes configured)")
                else
                    for i, n in ipairs(cfg.nodes) do
                        print(string.format("  [%d] %-16s  %s...", i,
                            n.name, n.key:sub(1, 8)))
                    end
                end
                print("")
                print("Shop name : " .. (cfg.shop_name or "AmiStore"))
                print("Sweep to  : " .. (#(cfg.sweep_to or "") > 0
                    and cfg.sweep_to or "(not set)"))
                print("Sweep %   : " .. (cfg.sweep_pct or 5) .. "%")
                print("")
                print("[A]dd  [D]elete  [N]ame  [S]weepTo  [P]assword  [B]ack")
                local _, k = os.pullEvent("key")
                if k == keys.b then
                    break

                elseif k == keys.a then
                    term.setCursorPos(1, 1); term.clear()
                    print("Add Node")
                    io.write("Node name: ")
                    local nm = io.read() or ""
                    io.write("Node key (32 hex): ")
                    local nk = (io.read() or ""):gsub("%s", "")
                    local ok, err = api.addNode(nm, nk)
                    if ok then
                        term.setTextColor(colors.green)
                        print("Added: " .. nm)
                    else
                        term.setTextColor(colors.red)
                        print("Error: " .. (err or "?"))
                    end
                    term.setTextColor(colors.white)
                    os.sleep(1)

                elseif k == keys.d then
                    term.setCursorPos(1, 1); term.clear()
                    print("Delete Node")
                    io.write("Index to remove: ")
                    local idx = tonumber(io.read())
                    local ok, err = api.removeNode(idx)
                    if ok then
                        term.setTextColor(colors.green); print("Removed.")
                    else
                        term.setTextColor(colors.red)
                        print("Error: " .. (err or "?"))
                    end
                    term.setTextColor(colors.white)
                    os.sleep(1)

                elseif k == keys.n then
                    term.setCursorPos(1, 1); term.clear()
                    print("Set Shop Name (used for DNS registration)")
                    local cfg2 = loadCfg()
                    io.write("New name: ")
                    local nm = (io.read() or ""):gsub("^%s+", ""):gsub("%s+$", "")
                    if #nm > 0 then
                        cfg2.shop_name = nm
                        saveCfg(cfg2)
                        api.registerShop()
                        term.setTextColor(colors.green)
                        print("Name updated and re-registered.")
                    else
                        print("Unchanged.")
                    end
                    term.setTextColor(colors.white)
                    os.sleep(1)

                elseif k == keys.s then
                    term.setCursorPos(1, 1); term.clear()
                    print("Set Sweep Target (player name to receive profits)")
                    local cfg2 = loadCfg()
                    print("Current: " .. (#(cfg2.sweep_to or "") > 0
                        and cfg2.sweep_to or "(none)"))
                    io.write("Player name (blank to clear): ")
                    local nm = (io.read() or ""):gsub("%s", "")
                    cfg2.sweep_to = nm
                    saveCfg(cfg2)
                    term.setTextColor(colors.green)
                    print(#nm > 0 and ("Sweep target set to: " .. nm) or "Sweep target cleared.")
                    term.setTextColor(colors.white)
                    os.sleep(1)

                elseif k == keys.p then
                    term.setCursorPos(1, 1); term.clear()
                    print("Change Admin Password")
                    print("")
                    local pw1, pw2
                    repeat
                        io.write("New password: ")
                        pw1 = read("*")
                        if #pw1 < 4 then
                            print("Too short — minimum 4 characters.")
                            pw1 = nil
                        else
                            io.write("Confirm: ")
                            pw2 = read("*")
                            if pw1 ~= pw2 then
                                print("Passwords do not match, try again.")
                                pw1 = nil
                            end
                        end
                    until pw1 and pw1 == pw2
                    api.setAdminPass(pw1)
                    term.setTextColor(colors.green)
                    print("Password updated.")
                    term.setTextColor(colors.white)
                    os.sleep(1)
                end
            end
            -- Re-register with (possibly updated) shop name after leaving node manager.
            api.registerShop()
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
print("  me_bridge    : " .. (peripheral.isPresent("right")        and "RIGHT [OK]" or "RIGHT [--]"))
print("  Printer      : " .. (peripheral.isPresent("left")         and "LEFT [OK]"  or "LEFT [--]"))
print("  Inventory    : " .. (peripheral.isPresent("bottom")       and "BOTTOM [OK]" or "BOTTOM [--]"))
print("  Modem        : " .. (api.getModem() and "BACK [OK]"       or "BACK [MISSING]"))
print("")

-- Password setup: if no admin password is saved, prompt to create one now.
if not api.hasAdminPass() then
    print("============================================")
    print("  First-Run Setup: Set Admin Password")
    print("============================================")
    print("")
    print("No admin password is set. Create one now.")
    print("(This is used to unlock the admin panel.)")
    print("")
    local pw1, pw2
    repeat
        io.write("New password: ")
        pw1 = read("*")
        if #pw1 < 4 then
            print("Too short — minimum 4 characters.")
        else
            io.write("Confirm password: ")
            pw2 = read("*")
            if pw1 ~= pw2 then
                print("Passwords do not match, try again.")
                pw1 = nil
            end
        end
    until pw1 and pw1 == pw2
    api.setAdminPass(pw1)
    term.setTextColor(colors.green)
    print("Password saved.")
    term.setTextColor(colors.white)
    print("")
end

local listings = api.getListings()
print(string.format("Loaded %d listing(s).", #listings))
print("Starting in 3 seconds...")
os.sleep(3)

-- Initial draw with placeholder balance; syncLoop will populate on first tick.
ui.init(api.getMonitor(), shopAddr)
ui.drawShop(api.getListings(), 0)

-- Run all three loops concurrently.
-- If inputLoop returns (user pressed Q), the others are killed automatically.
parallel.waitForAll(networkLoop, syncLoop, inputLoop)

term.clear(); term.setCursorPos(1, 1)
print("AmiStore shut down cleanly.")
