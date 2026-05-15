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

    -- Delta-check helper: hash a file on disk, nil if absent.
    local function hashFile(path)
        if not fs.exists(path) then return nil end
        local f = fs.open(path, "r")
        local c = f.readAll(); f.close()
        return fnv1a(c)
    end
    local failed = false
    local hashes = {}

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
                local remoteHash = fnv1a(content)
                if hashFile(entry.dst) == remoteHash then
                    term.setTextColor(colors.gray)
                    print("skip  [" .. remoteHash .. "]")
                    term.setTextColor(colors.white)
                    hashes[#hashes + 1] = remoteHash
                else
                    local bakPath = entry.dst .. ".bak"
                    if fs.exists(entry.dst) then
                        if fs.exists(bakPath) then fs.delete(bakPath) end
                        pcall(fs.copy, entry.dst, bakPath)
                    end
                    local f = fs.open(entry.dst, "w")
                    f.write(content); f.close()
                    if hashFile(entry.dst) ~= remoteHash then
                        if fs.exists(bakPath) then
                            pcall(fs.delete, entry.dst)
                            pcall(fs.copy, bakPath, entry.dst)
                        end
                        term.setTextColor(colors.red)
                        print("FAILED (verify -- backup restored)")
                        term.setTextColor(colors.white)
                        failed = true
                    else
                        term.setTextColor(colors.green)
                        print("OK  [" .. remoteHash .. "]")
                        term.setTextColor(colors.white)
                        hashes[#hashes + 1] = remoteHash
                    end
                end
            end
        end
    end

    print("")
    if failed then
        term.setTextColor(colors.red)
        print("Update failed. Backup files (.bak) retained.")
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
        -- Route plaintext (PAYMENT_ACK) vs XTEA (CONFIRM) on SHOP_CHANNEL.
        local ev, _, ch, replyCh, wire = os.pullEvent("modem_message")
        if ch == SHOP_CHANNEL then
            if type(wire) == "string" and wire:sub(1, 1) == "{" then
                -- Plaintext broadcast: PAYMENT_ACK from a wallet.
                local pkt = api.processShopBroadcast(wire)
                if pkt and pkt.type == "PAYMENT_ACK" then
                    local ok, err = api.executeInvoice(pkt.tx_id)
                    if ok then
                        term.setTextColor(colors.green)
                        print("[Net] Invoice " .. pkt.tx_id:sub(1, 8) .. " fulfilled.")
                        term.setTextColor(colors.white)
                    else
                        term.setTextColor(colors.red)
                        print("[Net] Invoice execute failed: " .. (err or "?"))
                        term.setTextColor(colors.white)
                    end
                    api.syncInventory()
                    ui.drawShop(api.getListings(), api.getShopBal(), true)
                end
            else
                -- Legacy XTEA path.
                local action = api.processWire(wire, replyCh)
                if action then
                    if action.type == "CONFIRM" and action.preview then
                        local order = action.order
                        ui.showReceiptPreview(
                            action.tx_id, "WTS",
                            order.item, order.qty,
                            order.price * order.qty)
                        os.sleep(3)
                        api.executeConfirm(action)
                    end
                    api.syncInventory()
                    ui.drawShop(api.getListings(), api.getShopBal(), true)
                end
            end
        end
    end
end

-- ── Periodic inventory sync ────────────────────────────────────────────────────
local function syncLoop()
    api.registerShop()
    api.syncInventory()
    api.prunePendingOrders()
    api.pruneInvoices()
    ui.drawShop(api.getListings(), api.getShopBal(), true)
    while true do
        os.sleep(SYNC_INTERVAL)
        api.syncInventory()
        api.prunePendingOrders()
        api.pruneInvoices()
        -- Only redraw catalog if no invoice is pending (pending screen should persist).
        if not api.getPendingInvoice() then
            ui.drawShop(api.getListings(), api.getShopBal(), true)
        end
    end
end

-- ── Monitor animation loop ────────────────────────────────────────────────────
-- Drives the "Processing" spinner on the monitor while an invoice is pending.
-- Wakes every 0.5 s via os.sleep so the animation stays smooth.
local function animLoop()
    local frame = 0
    while true do
        os.sleep(0.5)
        frame = frame + 1
        local inv = api.getPendingInvoice()
        if inv then
            ui.drawPending(inv.txId, inv.shop_name or "AmiStore",
                inv.item, inv.qty or 1, inv.total, inv.buyerName, frame)
        end
    end
end

-- ── Operator terminal menu ───────────────────────────────────────────────────
-- Admin access: hidden backtick (`) key -- never shown in this menu.
local function printMenu()
    local netUp = api.getModem() ~= nil
    local inv   = api.getPendingInvoice()
    term.setCursorPos(1, 1); term.clear()
    term.setTextColor(colors.orange)
    print("  AmiStore v1.1")
    term.setTextColor(colors.gray)
    print("  ----------------------------------------")
    term.setTextColor(colors.white)
    if inv then
        term.setTextColor(colors.yellow)
        print("  INVOICE PENDING: " .. inv.buyerName)
        term.setTextColor(colors.white)
        print("  Item : " .. (inv.item:match(":(.+)$") or inv.item))
        print("  Total: " .. inv.total .. " uAMI")
        term.setTextColor(colors.red)
        print("  [C]  Cancel invoice")
        term.setTextColor(colors.gray)
    elseif netUp then
        print("  Touch the monitor to start a sale.")
    else
        term.setTextColor(colors.red)
        print("  NETWORK OFFLINE -- modem not on BACK")
        term.setTextColor(colors.white)
    end
    print("")
    print("  [R]  Reload listings")
    print("  [Q]  Quit")
    term.setTextColor(colors.gray)
    print("  ----------------------------------------")
    term.setTextColor(colors.white)
end

-- ── Touch-driven invoice flow ──────────────────────────────────────────────────
-- Called by touchLoop when a listing card is tapped.
-- Prompts for player name on the operator terminal, sends invoice,
-- then switches monitor to PENDING state.
local function invoiceFlow(listing)
    -- Don't start a new invoice while one is already pending.
    if api.getPendingInvoice() then
        term.setTextColor(colors.yellow)
        print("[Touch] Invoice already pending -- cancel it first with [C].")
        term.setTextColor(colors.white)
        return
    end

    -- Availability check before prompting.
    if listing.type == "WTS" and (listing._stock or 0) == 0 then
        term.setCursorPos(1, 1); term.clear()
        term.setTextColor(colors.red)
        print("Out of stock: " .. (listing.item:match(":(.+)$") or listing.item))
        term.setTextColor(colors.white)
        os.sleep(1.5)
        ui.drawShop(api.getListings(), api.getShopBal(), true)
        printMenu()
        return
    end
    if listing.type == "WTB" and (listing._liquid or 0) < listing.price then
        term.setCursorPos(1, 1); term.clear()
        term.setTextColor(colors.red)
        print("Shop liquidity too low for this WTB listing.")
        term.setTextColor(colors.white)
        os.sleep(1.5)
        ui.drawShop(api.getListings(), api.getShopBal(), true)
        printMenu()
        return
    end

    -- Prompt buyer identity on terminal (monitor is still showing catalog).
    term.setCursorPos(1, 1); term.clear()
    term.setTextColor(colors.orange)
    local short = listing.item:match(":(.+)$") or listing.item
    print(string.format("Tap selected: %s  %d uAMI", short, listing.price))
    term.setTextColor(colors.white)
    io.write("Qty (Enter=1): ")
    local qtyRaw = io.read() or "1"
    local qtyNum = tonumber((qtyRaw:gsub("%s", ""))) or 1
    local qty    = math.max(1, math.floor(qtyNum))

    io.write("Player name or address: ")
    local raw = (io.read() or ""):gsub("^%s+",""):gsub("%s+$","")
    if #raw == 0 then
        print("Cancelled."); os.sleep(0.8)
        ui.drawShop(api.getListings(), api.getShopBal(), true)
        printMenu()
        return
    end

    -- Resolve name -> address.
    local buyerAddr = raw
    local buyerName = raw
    if #raw ~= 128 or not raw:match("^[0-9a-fA-F]+$") then
        io.write("  Resolving '" .. raw .. "'... ")
        local resolved = api.lookupName(raw)
        if resolved then
            buyerAddr = resolved
            print("OK")
        else
            term.setTextColor(colors.red)
            print("Name not found. Use exact player name or 128-hex address.")
            term.setTextColor(colors.white)
            os.sleep(2)
            ui.drawShop(api.getListings(), api.getShopBal(), true)
            printMenu()
            return
        end
    end

    -- Send invoice and switch monitor to pending state.
    local txId, err = api.sendInvoice(buyerAddr, buyerName, listing, qty)
    if not txId then
        term.setTextColor(colors.red); print("Invoice error: " .. (err or "?"))
        term.setTextColor(colors.white); os.sleep(2)
        ui.drawShop(api.getListings(), api.getShopBal(), true)
        printMenu()
        return
    end
    local cfg = loadCfg()
    ui.drawPending(txId, cfg.shop_name or "AmiStore",
        listing.item, qty, listing.price * qty, buyerName)
    printMenu()   -- terminal shows invoice status + [C] cancel
end

-- ── Touch event loop (parallel with networkLoop / syncLoop / inputLoop) ──────
local function touchLoop()
    while true do
        local ev, side, tx, ty = os.pullEvent("monitor_touch")
        -- Only act on touches to the TOP monitor.
        if side == "top" then
            local listing = ui.getTouchedListing(tx, ty)
            if listing then
                invoiceFlow(listing)
            end
        end
    end
end

-- ── Node manager (called only from adminLoop, never from public inputLoop) ───
local function nodeManager()
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
                print(string.format("  [%d] %-16s  %s...", i, n.name, n.key:sub(1, 8)))
            end
        end
        print("")
        print("Shop name : " .. (cfg.shop_name or "AmiStore"))
        print("Sweep to  : " .. (#(cfg.sweep_to or "") > 0 and cfg.sweep_to or "(not set)"))
        print("Sweep %   : " .. (cfg.sweep_pct or 5) .. "%")
        print("")
        print("[A]dd  [D]elete  [N]ame  [S]weepTo  [P] Node key password  [B]ack")
        local _, k = os.pullEvent("key")

        if k == keys.b then
            break

        elseif k == keys.a then
            term.setCursorPos(1, 1); term.clear()
            term.setTextColor(colors.orange); print("Add Node"); term.setTextColor(colors.white)
            print("")
            io.write("Node name: ")
            local nm = (io.read() or ""):gsub("^%s+", ""):gsub("%s+$", "")
            if #nm == 0 then nm = "Node " .. (#loadCfg().nodes + 1) end
            print("")
            print("  [1] Enter 32-char key manually")
            print("  [2] Fetch via setup password")
            local addKey
            while not addKey do
                local _, ak = os.pullEvent("key")
                if ak == keys.one or ak == keys.n1 then
                    io.write("Node key (32 hex): ")
                    local raw = (io.read() or ""):gsub("%s", ""):lower()
                    if #raw == 32 then
                        addKey = raw
                    else
                        term.setTextColor(colors.red); print("Must be exactly 32 hex chars.")
                        term.setTextColor(colors.white); os.sleep(1)
                    end
                    break
                elseif ak == keys.two or ak == keys.n2 then
                    io.write("Node lookup password: ")
                    local pw = read("*")
                    pw = (pw or ""):gsub("%s", "")
                    if #pw == 0 then
                        print("Cancelled."); os.sleep(0.8)
                    else
                        -- pcall: returns  pcallOk, fn_ok, nodeKey, fn_err
                        -- api.fetchNodeKey returns: ok(bool), key(str|nil), err(str|nil)
                        local pcallOk, fnOk, nodeKey, fnErr = pcall(api.fetchNodeKey, pw)
                        if not pcallOk then
                            -- Lua-level error (fnOk holds the error message)
                            term.setTextColor(colors.red); print("Connection error.")
                            term.setTextColor(colors.white); os.sleep(2)
                        elseif fnOk and type(nodeKey) == "string" and #nodeKey == 32 then
                            addKey = nodeKey
                            term.setTextColor(colors.green); print("Key received.")
                            term.setTextColor(colors.white); os.sleep(0.5)
                        else
                            local errMsg = type(fnErr) == "string" and fnErr or "Connection timeout"
                            term.setTextColor(colors.red); print("Lookup failed: " .. errMsg)
                            term.setTextColor(colors.white); os.sleep(2)
                        end
                    end
                    break
                end
            end
            if addKey then
                local callOk, ok, err = pcall(api.addNode, nm, addKey)
                if callOk and ok then
                    term.setTextColor(colors.green); print("Node added: " .. nm)
                elseif callOk then
                    term.setTextColor(colors.red); print("Failed: " .. (err or "unknown error"))
                else
                    term.setTextColor(colors.red); print("Internal error — node not saved.")
                end
                term.setTextColor(colors.white); os.sleep(1)
            end

        elseif k == keys.d then
            term.setCursorPos(1, 1); term.clear()
            print("Delete Node")
            io.write("Index to remove: ")
            local idx = tonumber(io.read())
            local ok, err = api.removeNode(idx)
            term.setTextColor(ok and colors.green or colors.red)
            print(ok and "Removed." or ("Error: " .. (err or "?")))
            term.setTextColor(colors.white); os.sleep(1)

        elseif k == keys.n then
            term.setCursorPos(1, 1); term.clear()
            print("Set Shop Name (used for DNS registration)")
            local cfg2 = loadCfg()
            io.write("New name: ")
            local nm = (io.read() or ""):gsub("^%s+", ""):gsub("%s+$", "")
            if #nm > 0 then
                cfg2.shop_name = nm; saveCfg(cfg2); api.registerShop()
                term.setTextColor(colors.green); print("Name updated and re-registered.")
            else
                print("Unchanged.")
            end
            term.setTextColor(colors.white); os.sleep(1)

        elseif k == keys.s then
            term.setCursorPos(1, 1); term.clear()
            print("Set Sweep Target (player name to receive profits)")
            local cfg2 = loadCfg()
            print("Current: " .. (#(cfg2.sweep_to or "") > 0 and cfg2.sweep_to or "(none)"))
            io.write("Player name (blank to clear): ")
            local nm = (io.read() or ""):gsub("%s", "")
            cfg2.sweep_to = nm; saveCfg(cfg2)
            term.setTextColor(colors.green)
            print(#nm > 0 and ("Sweep target: " .. nm) or "Sweep target cleared.")
            term.setTextColor(colors.white); os.sleep(1)

        elseif k == keys.p then
            term.setCursorPos(1, 1); term.clear()
            term.setTextColor(colors.orange); print("Node Setup Password"); term.setTextColor(colors.white)
            print("This password is shared with your AmiCoin node.")
            print("It is used to fetch a node key without typing 32 hex chars.")
            print("")
            if api.hasNodePass() then
                print("A node setup password is already saved.")
            else
                print("No node setup password saved yet.")
            end
            print("")
            io.write("New password (blank to clear): ")
            local pw1 = read("*")
            if #pw1 == 0 then
                api.setNodePass("")
                term.setTextColor(colors.yellow); print("Node setup password cleared.")
            elseif #pw1 < 4 then
                term.setTextColor(colors.red); print("Too short -- minimum 4 characters. Unchanged.")
            else
                io.write("Confirm: "); local pw2 = read("*")
                if pw1 == pw2 then
                    api.setNodePass(pw1)
                    term.setTextColor(colors.green); print("Node setup password saved.")
                else
                    term.setTextColor(colors.red); print("Passwords do not match. Unchanged.")
                end
            end
            term.setTextColor(colors.white); os.sleep(1)
        end
    end
    api.registerShop()
end

-- ── Admin panel loop (called from inputLoop after password check) ─────────────
local function adminLoop()
    local lst = api.getListings()
    local cfg = loadCfg()
    while true do
        ui.drawAdmin(lst, cfg)
        term.setCursorPos(1, 1); term.clear()
        term.setTextColor(colors.orange)
        print("  AmiStore -- Admin Panel")
        term.setTextColor(colors.gray)
        print("  ----------------------------------------")
        term.setTextColor(colors.white)
        print("  [B]  Back to storefront")
        print("  [P]  Edit listing price")
        print("  [+]  Add listing")
        print("  [-]  Remove listing")
        print("  [S]  Vault sweep %")
        print("  [N]  Node manager")
        print("  [U]  Self-update from GitHub")
        term.setTextColor(colors.gray)
        print("  ----------------------------------------")
        term.setTextColor(colors.white)
        local _, key = os.pullEvent("key")

        if key == keys.b then
            break

        elseif key == keys.p then
            term.setCursorPos(1, 1); term.clear()
            print("Edit Listing Price")
            io.write("Listing index: ")
            local idx = tonumber(io.read())
            if idx and lst[idx] then
                print(string.format("Current: %s  =  %d uAMI", lst[idx].item, lst[idx].price))
                io.write("New price (uAMI): ")
                local p = tonumber(io.read())
                if p and p > 0 then lst[idx].price = math.floor(p); api.saveListings(lst); print("Saved.") end
            end
            os.sleep(0.5)

        elseif key == keys.s then
            term.setCursorPos(1, 1); term.clear()
            print("Vault Sweep %")
            print(string.format("Current: %d%%", cfg.sweep_pct or 5))
            io.write("New sweep % (1-50): ")
            local sp = tonumber(io.read())
            if sp and sp >= 1 and sp <= 50 then cfg.sweep_pct = sp; saveCfg(cfg); print("Saved.") end
            os.sleep(0.5)

        elseif key == keys.equals then   -- [+]
            term.setCursorPos(1, 1); term.clear()
            print("Add Listing")
            io.write("Type (WTS / WTB): ")
            local lt = (io.read() or ""):upper():gsub("%s", "")
            io.write("Item name (e.g. minecraft:diamond): ")
            local li = (io.read() or ""):gsub("%s", "")
            io.write("Price in uAMI: ")
            local lp = tonumber(io.read())
            if (lt == "WTS" or lt == "WTB") and #li > 3 and lp and lp > 0 then
                lst[#lst + 1] = {type = lt, item = li, price = math.floor(lp)}
                api.saveListings(lst)
                print(string.format("Added: [%s] %s @ %d uAMI", lt, li, math.floor(lp)))
            else
                print("Invalid input — not saved.")
            end
            os.sleep(0.8)

        elseif key == keys.minus then    -- [-]
            term.setCursorPos(1, 1); term.clear()
            print("Remove Listing")
            io.write("Index to remove: ")
            local idx = tonumber(io.read())
            if idx and lst[idx] then
                local removed = lst[idx].item; table.remove(lst, idx)
                api.saveListings(lst); print("Removed: " .. removed)
            else
                print("Invalid index.")
            end
            os.sleep(0.5)

        elseif key == keys.n then
            nodeManager()
            cfg = loadCfg()   -- refresh after possible shop_name change

        elseif key == keys.u then
            selfUpdate()
            -- only returns on failure; on success it reboots
        end
    end
    api.syncInventory()
    ui.drawShop(api.getListings(), api.getShopBal(), true)
end

-- ── Keyboard input loop ────────────────────────────────────────────────────────
-- Admin access: press GRAVE (`) -- not shown in the public menu.
local function inputLoop()
    while true do
        printMenu()
        local _, key = os.pullEvent("key")

        -- GRAVE (`) -- hidden admin trigger
        if key == keys.grave then
            term.setCursorPos(1, 1); term.clear()
            term.setTextColor(colors.orange)
            print("Access required.")
            term.setTextColor(colors.white)
            io.write("Password: ")
            local inp = read("*")
            inp = (inp or ""):gsub("%s", "")
            if #inp > 0 and api.checkAdminPass(inp) then
                ui.setAdminUnlocked(true)
                adminLoop()
                ui.setAdminUnlocked(false)
            else
                term.setTextColor(colors.red)
                print("Access denied.")
                term.setTextColor(colors.white)
                os.sleep(1)
                ui.drawShop(api.getListings(), api.getShopBal(), true)
            end

        -- [C] -- cancel active pending invoice
        elseif key == keys.c then
            if api.getPendingInvoice() then
                api.cancelInvoice()
                term.setTextColor(colors.yellow)
                print("Invoice cancelled.")
                term.setTextColor(colors.white)
                os.sleep(0.8)
                ui.drawShop(api.getListings(), api.getShopBal(), true)
            end

        -- [R] -- manual refresh
        elseif key == keys.r then
            api.syncInventory()
            ui.drawShop(api.getListings(), api.getShopBal(), true)

        -- [Q] -- graceful quit
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
ui.drawShop(api.getListings(), 0, true)

-- Run all four loops concurrently.
-- touchLoop watches monitor_touch; inputLoop watches keyboard.
-- If inputLoop returns (user pressed Q), the others are killed automatically.
parallel.waitForAll(networkLoop, syncLoop, animLoop, touchLoop, inputLoop)

term.clear(); term.setCursorPos(1, 1)
print("AmiStore shut down cleanly.")
