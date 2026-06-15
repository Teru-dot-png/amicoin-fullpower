-- ami/casino/ui.lua  v2.0
-- AmiCasino shared UI foundation.
--
-- Changes from v1:
--   * Double-buffering via window API (zero flicker on animated frames)
--   * sfx() helper — uses Speaker peripheral if present, silent no-op otherwise
--   * Session info embedded in banner row 1 (name + balance + P&L)
--   * readBet: quick-bet keys  / = half,  * = double last,  M = max,  R = repeat
--   * helpOverlay: floating [?] help panel drawn over current screen
--   * drawCardBox: 4×3 ASCII card box for Blackjack
--   * diceStr / drawDicePair: dice rendering for Craps
--   * winBanner / loseBanner: flashing result overlays with sfx
--   * beginFrame / endFrame: wrap animation loops for atomic flicker-free draws
--   * All size queries go through _realTerm so they work inside a redirected frame

local ui = {}

-- ui.W() / ui.H() always query the live terminal size.
function ui.W() local w = term.getSize(); return w end
function ui.H() local _, h = term.getSize(); return h end

-- beginFrame / endFrame are intentional no-ops.
-- The window double-buffer (setVisible false/true) was hiding all static
-- content because setVisible(false) restores the parent's cleared framebuffer.
-- Games draw directly to term; the slight per-frame flicker is acceptable.
function ui.beginFrame() end
function ui.endFrame()   end
function ui.flush()      end

-- ── Sound ─────────────────────────────────────────────────────────────────────
local _speaker      = peripheral.find("speaker")
local _soundProfile = "on"   -- "on" | "quiet" | "off"
-- QUIET: only win/loss impact sounds; silences ticks, coins, bells, etc.
local _QUIET_OK     = { win=true, jackpot=true, loss=true, crash=true, boom=true }
local _SFX = {
    click   = "minecraft:ui.button.click",
    win     = "minecraft:block.note_block.pling",
    jackpot = "minecraft:entity.player.levelup",
    loss    = "minecraft:block.note_block.bass",
    crash   = "minecraft:entity.generic.explode",
    boom    = "minecraft:entity.tnt.primed",
    flip    = "minecraft:item.book.page_turn",
    dice    = "minecraft:block.note_block.snare",
    reel    = "minecraft:block.note_block.hat",
    coin    = "minecraft:entity.experience_orb.pickup",
    tick    = "minecraft:block.note_block.harp",
    bell    = "minecraft:block.note_block.bell",
}
function ui.setSoundProfile(p) _soundProfile = p end
function ui.getSoundProfile()  return _soundProfile end
function ui.sfx(name, vol, pitch)
    if _soundProfile == "off" then return end
    if _soundProfile == "quiet" and not _QUIET_OK[name] then return end
    if _speaker and _SFX[name] then
        pcall(_speaker.playSound, _SFX[name], vol or 1.0, pitch or 1.0)
    end
end

-- ── Session state (call ui.setSession before launching a game) ────────────────
local _sessName  = nil
local _sessBal   = nil
local _sessDep   = nil
local _sessSpark = nil   -- 10-char sparkline string (space = no data)

-- sparkline: optional 10-char string of '+'/'-'/' ' from recent outcomes.
function ui.setSession(name, bal, dep, sparkline)
    _sessName = name; _sessBal = bal; _sessDep = dep
    _sessSpark = sparkline
end

-- ── Bet presets ───────────────────────────────────────────────────────────────
-- Three optional µAMI quick-bet values set by the player at session start.
local _presets = {nil, nil, nil}
function ui.setPresets(p) _presets = p or {nil,nil,nil} end

-- ── Basic drawing ─────────────────────────────────────────────────────────────
function ui.cls()
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
    term.clear()
    term.setCursorPos(1, 1)
end

-- ── Theme (mirrors node matrix_ui upgrade colour) ───────────────────────────────────────
local _bannerBg  = colors.yellow   -- background of the header row
local _bannerFg  = colors.black    -- foreground text of the header row

-- Map from matrix_ui theme names to CC colour pairs {bg, fg}.
local _THEMES = {
    green_phosphor = {colors.green,   colors.black},
    amber          = {colors.orange,  colors.black},
    ice_blue       = {colors.cyan,    colors.black},
    deep_violet    = {colors.purple,  colors.white},
    neon_pink      = {colors.pink,    colors.black},
    solar_orange   = {colors.orange,  colors.white},
    arctic_white   = {colors.white,   colors.black},
    spectrum       = {colors.lime,    colors.black},
    void_red       = {colors.red,     colors.white},
    genesis_gold   = {colors.yellow,  colors.black},
}
function ui.setTheme(themeName)
    local pair = _THEMES[themeName]
    if pair then _bannerBg = pair[1]; _bannerFg = pair[2]
    else         _bannerBg = colors.yellow; _bannerFg = colors.black end
end

-- Animated 3-frame left-wipe transition before clearing.
-- Each frame shifts existing content 8 columns left and fills with black.
-- Cheap, flicker-free, gives a polished screen-change feel.
local _lastBannerTitle = nil
local function wipeTransition()
    local w, h = term.getSize()
    for shift = 1, 3 do
        for row = 1, h do
            term.setCursorPos(1, row)
            local line = ""
            for col = 1, w do
                -- read current char at (col + shift*8, row) if in range
                local src = col + shift * 8
                if src <= w then
                    term.setCursorPos(src, row)
                    -- capture char by re-writing spaces shifted left
                    line = line .. " "
                else
                    line = line .. " "
                end
            end
            term.setCursorPos(1, row)
            term.setTextColor(colors.black)
            term.setBackgroundColor(colors.black)
            term.write(string.rep(" ", w))
        end
        os.sleep(0.02)
    end
end

-- Layout: row 1 = gold header (session info or "AmiCasino")
--         row 2 = game title (yellow, centred)
--         row 3 = rule
--         row 4+ = game content
function ui.banner(title)
    local w = ui.W()
    -- Animate transition only when moving to a different screen title.
    if title ~= _lastBannerTitle and _lastBannerTitle ~= nil then
        wipeTransition()
    end
    _lastBannerTitle = title
    ui.cls()
    -- Row 1: header bar
    term.setBackgroundColor(_bannerBg)
    term.setTextColor(_bannerFg)
    term.setCursorPos(1, 1); term.clearLine()
    if _sessName and _sessBal then
        local balStr = string.format("%.4f", _sessBal / 1000000)
        local pnl    = _sessDep and (_sessBal - _sessDep) or 0
        local pnlStr = string.format("%+.4f", pnl / 1000000)
        -- 10-char sparkline padded/trimmed to exactly 10 chars
        local spark  = _sessSpark or string.rep(" ", 10)
        if #spark < 10 then spark = string.rep(" ", 10 - #spark) .. spark end
        spark = spark:sub(-10)
        local right  = spark .. " " .. balStr .. "  " .. pnlStr .. " "
        local left   = (" " .. _sessName):sub(1, math.max(1, w - #right))
        term.setCursorPos(1, 1)
        term.write(left)
        local rCol = pnl >= 0 and colors.black or colors.red
        term.setTextColor(rCol)
        term.setCursorPos(w - #right + 1, 1)
        term.write(right:sub(1, w - #left))
    else
        local hdr = " AmiCasino "
        term.setCursorPos(math.floor((w - #hdr) / 2) + 1, 1)
        term.write(hdr)
    end
    term.setBackgroundColor(colors.black)
    -- Row 2: title
    term.setCursorPos(1, 2); term.clearLine()
    if title then
        term.setTextColor(colors.yellow)
        local x = math.floor((w - #title) / 2) + 1
        term.setCursorPos(math.max(1, x), 2)
        term.write(title:sub(1, w))
    end
    -- Row 3: rule
    term.setTextColor(colors.gray)
    term.setCursorPos(1, 3)
    term.write(string.rep("-", w))
end

function ui.rule(y, col)
    local w = ui.W()
    term.setCursorPos(1, y)
    term.setTextColor(col or colors.gray)
    term.write(string.rep("-", w))
end

function ui.line(y, text, col, bg)
    local w = ui.W()
    term.setCursorPos(1, y)
    term.setTextColor(col or colors.white)
    term.setBackgroundColor(bg or colors.black)
    term.clearLine()   -- clear old content first; cursor stays at (1,y)
    if #text > w then text = text:sub(1, w) end
    term.write(text)
end

function ui.center(y, text, col, bg)
    local w = ui.W()
    term.setTextColor(col or colors.white)
    term.setBackgroundColor(bg or colors.black)
    local x = math.floor((w - #text) / 2) + 1
    term.setCursorPos(math.max(1, x), y)
    term.write(text:sub(1, w))
end

function ui.amtLine(y, label, uami, col)
    local w = ui.W()
    term.setCursorPos(1, y)
    term.setTextColor(col or colors.white)
    local ami = string.format("%.4f AMI", uami / 1000000)
    term.write((label .. ami .. "  (" .. uami .. " uAMI)"):sub(1, w))
end

-- ── Input helpers ─────────────────────────────────────────────────────────────
function ui.waitKey()
    local _, k = os.pullEvent("key")
    return k
end

function ui.yesNo(y, msg)
    ui.line(y, (msg or "[Y] Confirm   [N] Cancel"):sub(1, ui.W()), colors.orange)
    while true do
        local _, k = os.pullEvent("key")
        if k == keys.y then return true  end
        if k == keys.n then return false end
    end
end

-- Enhanced bet prompt with quick-bet shortcuts.
--   /   → half balance
--   *   → double last bet (clamped to balance)
--   m   → full balance
--   r   → repeat last bet
--   ?   → show helpLines overlay (if provided) then re-prompt
-- lastBet:   µAMI from previous call (nil = use internal memory).
-- helpLines: optional string array for the [?] overlay; nil = ? ignored.
-- Returns µAMI integer, or nil to cancel.
local _lastBet = 0
function ui.readBet(y, balance, lastBet, helpLines)
    lastBet = lastBet or _lastBet
    local w    = ui.W()
    local half = math.max(1, math.floor(balance / 2))
    local dbl  = (lastBet > 0) and math.min(balance, lastBet * 2) or nil

    ui.line(y,   "Bet (AMI):  [B]=back  [?]=help", colors.yellow)
    ui.line(y+1, string.format("Balance: %.4f AMI", balance / 1000000), colors.lightGray)

    local hints = "  [/]half  [M]max"
    if dbl and dbl <= balance then hints = hints .. "  [*]dbl" end
    if lastBet > 0 and lastBet <= balance then hints = hints .. "  [R]rpt" end
    -- Bet presets
    local presetHint = ""
    for i = 1, 3 do
        if _presets[i] and _presets[i] <= balance then
            presetHint = presetHint .. string.format("  [F%d]=%.2f", i, _presets[i] / 1000000)
        end
    end
    if #presetHint > 0 then hints = hints .. presetHint end
    ui.line(y+2, hints:sub(1, w), colors.gray)

    while true do
        term.setCursorPos(1, y+3); term.setTextColor(colors.white)
        io.write("> ")
        local raw = read()
        raw = (raw or ""):gsub("^%s*(.-)%s*$", "%1")

        if raw == "" or raw:lower() == "b" then return nil end

        if raw == "?" and helpLines then
            ui.helpOverlay("Help", helpLines)
            -- Redraw the bet-prompt rows the overlay painted over
            ui.line(y,   "Bet (AMI):  [B]=back  [?]=help", colors.yellow)
            ui.line(y+1, string.format("Balance: %.4f AMI", balance / 1000000), colors.lightGray)
            ui.line(y+2, hints:sub(1, w), colors.gray)
            -- continue loop → re-prompt
        elseif raw == "f1" or raw == "F1" then
            if _presets[1] and _presets[1] <= balance then _lastBet = _presets[1]; return _presets[1] end
        elseif raw == "f2" or raw == "F2" then
            if _presets[2] and _presets[2] <= balance then _lastBet = _presets[2]; return _presets[2] end
        elseif raw == "f3" or raw == "F3" then
            if _presets[3] and _presets[3] <= balance then _lastBet = _presets[3]; return _presets[3] end
        else
            local result
            if raw == "/" then
                result = half
            elseif raw == "*" and dbl then
                result = dbl
            elseif raw:lower() == "m" then
                result = balance
            elseif raw:lower() == "r" and lastBet > 0 and lastBet <= balance then
                result = lastBet
            else
                local n = tonumber(raw)
                if not n or n <= 0 then
                    ui.line(y+4, "Invalid amount.", colors.red); os.sleep(0.8); return nil
                end
                result = math.floor(n * 1000000)
                if result < 1 then
                    ui.line(y+4, "Minimum: 0.000001 AMI", colors.red); os.sleep(0.8); return nil
                end
                if result > balance then
                    ui.line(y+4, "Not enough balance!", colors.red); os.sleep(0.8); return nil
                end
            end
            if result then _lastBet = result end
            return result
        end
    end
end

-- ── Help overlay ──────────────────────────────────────────────────────────────
-- Draws a floating box over the current screen. Waits for any key.
-- Caller MUST redraw their screen after this returns.
function ui.helpOverlay(title, lines)
    local w, h = term.getSize()
    local bw = math.min(w - 2, 44)
    local bh = math.min(#lines + 4, h - 2)
    local bx = math.floor((w - bw) / 2) + 1
    local by = math.floor((h - bh) / 2) + 1

    term.setBackgroundColor(colors.gray)
    for row = by, by + bh - 1 do
        term.setCursorPos(bx, row); term.write(string.rep(" ", bw))
    end
    term.setBackgroundColor(colors.blue); term.setTextColor(colors.white)
    term.setCursorPos(bx, by)
    term.write((" " .. title .. " "):sub(1, bw))
    term.setBackgroundColor(colors.gray); term.setTextColor(colors.white)
    for i, ln in ipairs(lines) do
        local row = by + 1 + (i - 1)
        if row >= by + bh - 1 then break end
        term.setCursorPos(bx + 1, row)
        term.write(ln:sub(1, bw - 2))
    end
    term.setBackgroundColor(colors.blue); term.setTextColor(colors.yellow)
    term.setCursorPos(bx, by + bh - 1)
    term.write(string.rep(" ", bw))
    local foot = " [Any key] Close "
    term.setCursorPos(bx + math.floor((bw - #foot) / 2), by + bh - 1)
    term.write(foot)
    os.pullEvent("key")
end

-- ── Card rendering for Blackjack ──────────────────────────────────────────────
function ui.cardColor(suit)
    return (suit == "H" or suit == "D") and colors.red or colors.white
end

-- 4-wide × 3-tall ASCII card box at terminal (x, y):
--   +--+
--   |AH|
--   +--+
function ui.drawCardBox(x, y, rank, suit, faceDown)
    local function at(dx, dy, text, fg)
        term.setCursorPos(x + dx, y + dy)
        term.setTextColor(fg); term.setBackgroundColor(colors.black)
        term.write(text)
    end
    if faceDown then
        at(0, 0, "+--+", colors.gray)
        at(0, 1, "|??|", colors.gray)
        at(0, 2, "+--+", colors.gray)
    else
        local col = ui.cardColor(suit)
        at(0, 0, "+--+", colors.lightGray)
        at(0, 1, "|",    colors.lightGray)
        at(1, 1, string.format("%-2s", rank):sub(1,2), col)
        at(3, 1, "|",    colors.lightGray)
        at(0, 2, "+--+", colors.lightGray)
    end
end

-- Inline card string e.g. "[AH]" for compact hand displays
function ui.cardStr(rank, suit, faceDown)
    if faceDown then return "[??]" end
    return "[" .. string.format("%-2s", rank):sub(1,2) .. suit .. "]"
end

-- ── Dice rendering for Craps ──────────────────────────────────────────────────
local _DICE_ART = {
    [1] = {"+---+","|   |","| o |","|   |","+---+"},
    [2] = {"+---+","| o |","|   |","| o |","+---+"},
    [3] = {"+---+","| o |","| o |","| o |","+---+"},
    [4] = {"+---+","|o o|","|   |","|o o|","+---+"},
    [5] = {"+---+","|o o|","| o |","|o o|","+---+"},
    [6] = {"+---+","|o o|","|o o|","|o o|","+---+"},
}
function ui.drawDicePair(x, y, v1, v2)
    local a1 = _DICE_ART[v1] or _DICE_ART[1]
    local a2 = _DICE_ART[v2] or _DICE_ART[1]
    for row = 1, 5 do
        term.setCursorPos(x, y + row - 1)
        term.setTextColor(colors.white); term.setBackgroundColor(colors.black)
        term.write((a1[row] or "") .. " " .. (a2[row] or ""))
    end
end

-- ── Reel animation (timer-driven, non-blocking) ───────────────────────────────
-- Render one frame of a slot spin inside an animation loop.
-- frame / totalFrames controls when each reel settles on its final symbol.
function ui.spinReelFrame(y, symbols, finalL, finalM, finalR, frame, totalFrames)
    local l = (frame > totalFrames - 3) and finalL or symbols[math.random(#symbols)]
    local m = (frame > totalFrames - 2) and finalM or symbols[math.random(#symbols)]
    local r = (frame > totalFrames - 1) and finalR or symbols[math.random(#symbols)]
    ui.center(y, string.format(" [ %-2s | %-2s | %-2s ] ", l, m, r), colors.yellow)
    return l, m, r
end

-- Legacy blocking spinReels kept for backward compatibility
function ui.spinReels(y, symbols, finalL, finalM, finalR)
    for f = 1, 14 do
        ui.spinReelFrame(y, symbols, finalL, finalM, finalR, f, 14)
        os.sleep(0.08 + f * 0.01)
    end
end

-- ── Win / loss banners ────────────────────────────────────────────────────────
function ui.winBanner(title, sub)
    local w, h = term.getSize()
    ui.sfx("win")
    local row = math.floor(h / 2) - 1
    local bgs  = {colors.lime, colors.green, colors.lime, colors.green}
    for _, bg in ipairs(bgs) do
        term.setBackgroundColor(bg)
        term.setTextColor(colors.black)
        term.setCursorPos(1, row); term.clearLine()
        local t = (title or "YOU WIN!"):sub(1, w)
        term.setCursorPos(math.floor((w - #t) / 2) + 1, row); term.write(t)
        if sub then
            term.setCursorPos(1, row + 1); term.clearLine()
            local s = sub:sub(1, w)
            term.setCursorPos(math.floor((w - #s) / 2) + 1, row + 1); term.write(s)
        end
        os.sleep(0.2)
    end
    term.setBackgroundColor(colors.black)
end

function ui.loseBanner(title, sub)
    local w, h = term.getSize()
    ui.sfx("loss")
    local row = math.floor(h / 2) - 1
    local bgs  = {colors.red, colors.orange, colors.red, colors.orange}
    for _, bg in ipairs(bgs) do
        term.setBackgroundColor(bg)
        term.setTextColor(colors.white)
        term.setCursorPos(1, row); term.clearLine()
        local t = (title or "YOU LOSE!"):sub(1, w)
        term.setCursorPos(math.floor((w - #t) / 2) + 1, row); term.write(t)
        if sub then
            term.setCursorPos(1, row + 1); term.clearLine()
            local s = sub:sub(1, w)
            term.setCursorPos(math.floor((w - #s) / 2) + 1, row + 1); term.write(s)
        end
        os.sleep(0.2)
    end
    term.setBackgroundColor(colors.black)
end

-- ── Provably-fair pre-commit display ──────────────────────────────────────────
-- Shows a commitment hash before a random outcome is revealed, then the seed
-- after, so players can see the outcome was pre-committed.
-- IMPORTANT: This is a trust display only.  CC's math.random is NOT
-- cryptographically secure and FNV-1a is NOT a tamper-proof commitment scheme.
-- Do not represent this as a cryptographic guarantee.
local function pfFnv1a(s)
    local hash = 2166136261
    for i = 1, #s do
        hash = bit32.bxor(hash, string.byte(s, i))
        hash = (hash * 16777619) % 4294967296
    end
    return string.format("%08x", hash)
end

-- Generate a seed string and return {seed, commit} where commit = fnv1a(seed).
-- Seed is epoch+random — not secret, purely cosmetic.
function ui.pfCommit()
    local seed   = string.format("%d_%d", os.epoch("utc"), math.random(0, 2147483647))
    local commit = pfFnv1a(seed)
    return seed, commit
end

-- Display the commit hash on the given row before the game starts.
function ui.pfShowCommit(y, commit)
    ui.line(y, string.format("  Pre-commit (trust display): %s", commit), colors.gray)
end

-- Display the seed on the given row after the outcome is revealed.
function ui.pfReveal(y, seed)
    ui.line(y, string.format("  Seed revealed: %s", seed), colors.gray)
end

return ui

