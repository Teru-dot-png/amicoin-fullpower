-- /ami/shop/shop_ui.lua
-- AmiStore v1.1 — Glass Cockpit UI
-- Renders onto the 3x3 Advanced Monitor attached to TOP.
-- All drawing calls are gated: if no monitor is attached, functions no-op.
--
-- Exported API:
--   ui.init(monitor, shopAddr)
--   ui.drawShop(listings, balance)       — main storefront view
--   ui.drawAdmin(listings, cfg)          — admin dashboard
--   ui.showReceiptPreview(...)           — overlay before committing a sale
--   ui.clearReceiptPreview(listings, bal)— restore main view after preview
--   ui.setAdminUnlocked(bool)
--   ui.adminLoop(listings, cfg, saveFn, saveCfgFn)

local ui = {}

-- ── Owned state ───────────────────────────────────────────────────────────────
local mon           = nil
local W, H          = 51, 19   -- updated after init
local shopAddr      = "?"
local adminUnlocked = false

-- ── Colour palette (red / orange / gray theme) ────────────────────────────────────
local BG      = colors.black
local HDR_BG  = colors.gray
local HDR_FG  = colors.white
local TITLE   = colors.orange
local WTS_C   = colors.lime       -- WTS (shop sells) = player BUYs  → positive/green
local WTB_C   = colors.orange     -- WTB (shop buys)  = player SELLs → warm/orange
local PRICE_C = colors.yellow
local DIM     = colors.lightGray
local BAD     = colors.red
local BORDER  = colors.gray
local ACCENT  = colors.orange
local ADM_BG  = colors.gray      -- dark, serious admin panel
local GLASS   = colors.orange    -- accent glass / info highlight

-- ── Guard ─────────────────────────────────────────────────────────────────────
local function hasMon() return mon ~= nil end

-- ── Primitives ────────────────────────────────────────────────────────────────
local function put(x, y, text, fg, bg)
    if not hasMon() then return end
    if bg  then mon.setBackgroundColor(bg) end
    if fg  then mon.setTextColor(fg) end
    mon.setCursorPos(x, y)
    mon.write(text)
end

local function fill(x, y, w, h, bg)
    if not hasMon() then return end
    mon.setBackgroundColor(bg or BG)
    local blank = string.rep(" ", w)
    for row = y, y + h - 1 do
        mon.setCursorPos(x, row); mon.write(blank)
    end
end

local function hline(x, y, w, fg, bg)
    put(x, y, string.rep("-", w), fg or BORDER, bg or BG)
end

local function box(x, y, w, h, fg, bg)
    if not hasMon() then return end
    bg = bg or BG; fg = fg or BORDER
    mon.setBackgroundColor(bg); mon.setTextColor(fg)
    mon.setCursorPos(x, y);         mon.write("+" .. string.rep("-", w - 2) .. "+")
    for row = y + 1, y + h - 2 do
        mon.setCursorPos(x, row);     mon.write("|")
        mon.setCursorPos(x + w - 1, row); mon.write("|")
    end
    mon.setCursorPos(x, y + h - 1); mon.write("+" .. string.rep("-", w - 2) .. "+")
end

local function center(text, w)
    local pad = math.max(0, math.floor((w - #text) / 2))
    return string.rep(" ", pad) .. text .. string.rep(" ", math.max(0, w - pad - #text))
end

-- ── Gloss-shaded Ami-Head logo ─────────────────────────────────────────────────
-- Drawn as a 9-wide × 5-tall block of coloured spaces.
-- Layout (b=rim/gray, f=face/orange, g=gloss/yellow):
--   .bbbbbbb.
--   bggfffffb
--   bgffOfffb    (O = eyes, drawn as small darker px)
--   bfffffffb
--   .bbbbbbb.
local function drawAmiHead(ox, oy)
    if not hasMon() then return end
    local function px(dx, dy, c)
        mon.setBackgroundColor(c); mon.setTextColor(c)
        mon.setCursorPos(ox + dx, oy + dy); mon.write(" ")
    end
    local rim   = colors.gray
    local face  = colors.orange
    local gloss = colors.yellow
    -- top rim
    for i = 1, 7 do px(i, 0, rim) end
    -- rows 1-3
    for row = 1, 3 do
        px(0, row, rim); px(8, row, rim)
        for i = 1, 7 do px(i, row, face) end
    end
    -- gloss sheen (top-left two cells of face)
    px(1, 1, gloss); px(2, 1, gloss)
    -- bottom rim
    for i = 1, 7 do px(i, 4, rim) end
    -- restore
    mon.setBackgroundColor(BG)
end

-- ── Header ────────────────────────────────────────────────────────────────────
local function drawHeader(title)
    fill(1, 1, W, 1, colors.gray)
    put(1, 1, center(title or "  AMISTORE  v1.1  ", W), colors.orange, colors.gray)
end

-- (footer removed — key legend lives on the operator terminal)

-- ── Listing card (3 rows tall, w wide) ────────────────────────────────────────
local function drawCard(x, y, w, listing)
    if not hasMon() then return end
    fill(x, y, w, 3, BG)
    box(x, y, w, 3, BORDER, BG)

    -- Badge and colour from the PLAYER's point of view:
    --   WTS (shop sells)  → player action is "BUY"  (lime)
    --   WTB (shop buys)   → player action is "SELL" (orange)
    local tc    = listing.type == "WTS" and WTS_C or WTB_C
    local badge = listing.type == "WTS" and "BUY " or "SELL"

    -- type badge
    put(x + 1, y,     badge, tc, BG)
    -- item name (truncated to fit, dots as ellipsis)
    local short = (listing.item:match(":(.+)$") or listing.item)
    local maxL  = w - 6
    if #short > maxL then short = short:sub(1, maxL - 1) .. "~" end
    put(x + 1, y + 1, short, HDR_FG, BG)
    -- price
    put(x + 1, y + 2, string.format("%d uAMI", listing.price), PRICE_C, BG)

    -- availability badge (right-aligned)
    if listing.type == "WTS" then
        local stock = listing._stock or 0
        local s     = stock > 0 and string.format("x%d", stock) or "OUT"
        local sc    = stock > 0 and colors.orange or BAD
        put(x + w - #s - 2, y + 1, s, sc, BG)
    else
        local ok2   = (listing._liquid or 0) >= listing.price
        local s     = ok2 and "OK " or "LOW"
        put(x + w - 4, y + 1, s, ok2 and colors.orange or BAD, BG)
    end
end

-- ── Main storefront view ──────────────────────────────────────────────────────
function ui.drawShop(lst, balance)
    if not hasMon() then return end
    mon.setBackgroundColor(BG); mon.clear()

    local contentBottom = H

    drawHeader("  AMISTORE  v1.1  ")

    -- Ami-Head logo in top-right (needs at least 12 cols free)
    if W >= 28 then drawAmiHead(W - 9, 2) end

    -- Shop info block (top-left)
    put(2, 2, "Balance:", DIM, BG)
    put(2, 3, string.format("%.4f AMI", (balance or 0) / 1000000), ACCENT, BG)
    put(2, 4, string.format("%d uAMI", balance or 0), DIM, BG)
    put(2, 5, os.date("Sync: %H:%M:%S"), DIM, BG)

    -- Column divider — labels are from the player's perspective
    fill(1, 6, W, 1, colors.gray)
    put(1, 6, center("[ BUY ] lime  |  [ SELL ] orange", W), DIM, colors.gray)

    -- Two-column listing grid
    local colW  = math.floor((W - 3) / 2)
    local leftX = 1
    local rigX  = leftX + colW + 1
    local row   = 7
    local wts, wtb = {}, {}
    for _, l in ipairs(lst or {}) do
        if l.type == "WTS" then wts[#wts + 1] = l
        else                     wtb[#wtb + 1] = l end
    end

    for i = 1, math.max(#wts, #wtb) do
        if row + 2 > contentBottom then break end
        if wts[i] then drawCard(leftX, row, colW, wts[i]) end
        if wtb[i] then drawCard(rigX,  row, colW, wtb[i]) end
        row = row + 3
    end

    if #(lst or {}) == 0 then
        put(2, 8, "No listings — edit /ami/shop/listings.json", DIM, BG)
    end
end

-- ── Admin dashboard ────────────────────────────────────────────────────────────
function ui.drawAdmin(lst, cfg)
    if not hasMon() then return end
    mon.setBackgroundColor(BG); mon.clear()
    fill(1, 1, W, 1, colors.gray)
    put(1, 1, center("AMISTORE  ADMIN  DASHBOARD", W), colors.orange, colors.gray)

    put(2, 3, "Session : ACTIVE (hardware-bound)", GLASS, BG)
    put(2, 4, "Addr    : " .. shopAddr:sub(1, 24) .. "...", DIM, BG)
    put(2, 5, string.format("Sweep   : %d%%  |  Nodes: %d",
              cfg.sweep_pct or 5, #(cfg.nodes or {})), ACCENT, BG)

    hline(1, 6, W, BORDER, BG)
    put(1, 6, center("  Listings  ", W), DIM, BG)

    local contentBottom = H

    local row = 7
    for i, l in ipairs(lst or {}) do
        if row > contentBottom then break end
        local tc     = l.type == "WTS" and WTS_C or WTB_C
        local pLabel = l.type == "WTS" and "BUY " or "SELL"
        local short  = (l.item:match(":(.+)$") or l.item):sub(1, 24)
        put(2, row,
            string.format("[%2d] %s  %-24s  %7d uAMI", i, pLabel, short, l.price),
            tc, BG)
        row = row + 1
    end
    if #(lst or {}) == 0 then
        put(2, row, "  (empty)", DIM, BG)
    end
end

-- ── Receipt preview overlay ────────────────────────────────────────────────────
-- Drawn centred on the monitor. Shows the printed slip before it is committed.
function ui.showReceiptPreview(txId, txType, itemName, qty, totalMicro)
    if not hasMon() then return end
    local bw = math.min(34, W - 4)
    local bh = 13
    local bx = math.floor((W  - bw) / 2) + 1
    local by = math.floor((H  - bh) / 2) + 1

    fill(bx, by, bw, bh, colors.white)
    box(bx, by, bw, bh, colors.black, colors.white)

    local function pln(dy, text, fg)
        mon.setCursorPos(bx + 1, by + dy)
        mon.setBackgroundColor(colors.white)
        mon.setTextColor(fg or colors.black)
        mon.write(text:sub(1, bw - 2))
    end

    pln(0,  "--- RECEIPT PREVIEW ---", colors.gray)
    pln(1,  "TX:  " .. (txId     or "?"):sub(1, bw - 6))
    pln(2,  "Type:" .. (txType   or "?"))
    pln(3,  "Item:" .. (itemName or "?"):sub(1, bw - 6))
    pln(4,  string.format("Qty: %d", qty or 0))
    pln(5,  string.format("Amt: %d uAMI", totalMicro or 0))
    pln(6,  string.format("    (%.4f AMI)", (totalMicro or 0) / 1000000))
    pln(7,  "   .---.   ", colors.orange)
    pln(8,  "  (  o  )  ", colors.orange)
    pln(9,  "   `---'   ", colors.orange)
    pln(10, "Confirm in 3 s...", colors.gray)
end

-- Restore the main shop view after clearing the preview overlay.
function ui.clearReceiptPreview(lst, balance)
    ui.drawShop(lst, balance)
end

-- ── Admin input loop (blocking, called from startup.lua) ─────────────────────
-- Uses the terminal (not the monitor) for text input so the monitor keeps
-- showing the admin dashboard while the operator types.
function ui.adminLoop(lst, cfg, saveListingsFn, saveConfigFn)
    while true do
        ui.drawAdmin(lst, cfg)
        -- Print admin key legend to operator terminal
        term.setCursorPos(1, 1); term.clear()
        term.setTextColor(colors.orange)
        print("  AmiStore — Admin Panel")
        term.setTextColor(colors.gray)
        print("  ----------------------------------------")
        term.setTextColor(colors.white)
        print("  [B]  Back to storefront")
        print("  [P]  Edit listing price")
        print("  [+]  Add listing")
        print("  [-]  Remove listing")
        print("  [S]  Vault sweep %")
        print("  [U]  Self-update from GitHub")
        term.setTextColor(colors.gray)
        print("  ----------------------------------------")
        term.setTextColor(colors.white)
        local _, key = os.pullEvent("key")

        if key == keys.b then
            adminUnlocked = false
            return "back"

        elseif key == keys.p then
            -- Edit price of an existing listing
            term.setCursorPos(1, 1); term.clear()
            print("AmiStore Admin — Edit price")
            print("Listing index:")
            local idx = tonumber(io.read())
            if idx and lst[idx] then
                print(string.format("Current price for %s: %d uAMI",
                      lst[idx].item, lst[idx].price))
                print("New price (uAMI):")
                local p = tonumber(io.read())
                if p and p > 0 then
                    lst[idx].price = math.floor(p)
                    saveListingsFn(lst)
                    print("Saved.")
                end
            end
            os.sleep(0.5)

        elseif key == keys.s then
            -- Edit vault sweep percentage
            term.setCursorPos(1, 1); term.clear()
            print("AmiStore Admin — Vault Sweep %")
            print(string.format("Current: %d%%", cfg.sweep_pct or 5))
            print("New sweep % (1-50):")
            local sp = tonumber(io.read())
            if sp and sp >= 1 and sp <= 50 then
                cfg.sweep_pct = sp
                saveConfigFn(cfg)
                print("Saved.")
            end
            os.sleep(0.5)

        elseif key == keys.equals then   -- [+] add listing
            term.setCursorPos(1, 1); term.clear()
            print("AmiStore Admin — Add Listing")
            print("Type (WTS / WTB):")
            local lt = (io.read() or ""):upper():gsub("%s", "")
            print("Item name (e.g. minecraft:diamond):")
            local li = (io.read() or ""):gsub("%s", "")
            print("Price in uAMI:")
            local lp = tonumber(io.read())
            if (lt == "WTS" or lt == "WTB") and #li > 3 and lp and lp > 0 then
                lst[#lst + 1] = {type = lt, item = li, price = math.floor(lp)}
                saveListingsFn(lst)
                print(string.format("Added: [%s] %s @ %d uAMI", lt, li, math.floor(lp)))
            else
                print("Invalid input — not saved.")
            end
            os.sleep(0.8)

        elseif key == keys.minus then    -- [-] remove listing
            term.setCursorPos(1, 1); term.clear()
            print("AmiStore Admin — Remove Listing")
            print("Index to remove:")
            local idx = tonumber(io.read())
            if idx and lst[idx] then
                local removed = lst[idx].item
                table.remove(lst, idx)
                saveListingsFn(lst)
                print("Removed: " .. removed)
            else
                print("Invalid index.")
            end
            os.sleep(0.5)
        end
    end
end

-- ── Init ──────────────────────────────────────────────────────────────────────
function ui.init(monitor, addr)
    mon       = monitor
    shopAddr  = addr or "?"
    if mon then
        mon.setTextScale(0.5)   -- 0.5 = maximum resolution on a 3x3 monitor
        W, H = mon.getSize()
        mon.setBackgroundColor(BG)
        mon.clear()
    end
end

function ui.setAdminUnlocked(v) adminUnlocked = v end
function ui.getSize() return W, H end

return ui
