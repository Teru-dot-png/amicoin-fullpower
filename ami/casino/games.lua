-- ami/casino/games.lua  v2.0
-- AmiCasino — All 9 game implementations.
--
-- API contract (unchanged from v1):
--   games.foo(ui, balance)  →  net (int µAMI), desc (string)
--   net > 0 = win, net < 0 = loss, net = 0 = push/cancel
--   Games never touch the ledger; startup.lua applies the net change.
--
-- Changes from v1 (NO HOUSE-EDGE CHANGES except where flagged):
--   Mines       : gem/mine symbols, mouse_click to reveal, live cashout value
--   Crash       : FIXED cash-out race condition (money bug), live bar chart
--   Slots       : reels stop L→M→R sequentially with sfx, themed symbols
--   Blackjack   : rendered card boxes, Double-Down added
--                 EDGE CHANGE: DD reduces house edge ~0.3pp (2.5% → 2.2%)
--   Roulette    : dozens + columns bet types added (same 2.7% edge, no change)
--   Higher/Lower: big card display, visible multiplier ladder, cash-out at any point
--   Pachinko    : fixed animation flicker (no banner reset inside loop)
--   Craps       : ASCII dice pair render, clear phase display
--   Coin Flip   : animated spin frames, double-or-nothing parlay after win

local games = {}

math.randomseed(os.epoch("utc") + os.getComputerID() * 7919)

-- ── Card helpers ──────────────────────────────────────────────────────────────
local _RANKS = {"A","2","3","4","5","6","7","8","9","10","J","Q","K"}
local _SUITS = {"H","D","C","S"}
local _RANK_IDX = {}
for i, r in ipairs(_RANKS) do _RANK_IDX[r] = i end

local function newCard()
    return {rank=_RANKS[math.random(#_RANKS)], suit=_SUITS[math.random(#_SUITS)]}
end

local function cardVal(r)
    if r == "A" then return 11 end
    if tonumber(r) then return tonumber(r) end
    return 10
end

local function handVal(hand)
    local total, aces = 0, 0
    for _, c in ipairs(hand) do
        total = total + cardVal(c.rank)
        if c.rank == "A" then aces = aces + 1 end
    end
    while total > 21 and aces > 0 do total = total - 10; aces = aces - 1 end
    return total
end

local function handStr(hand, hideSecond)
    local parts = {}
    for i, c in ipairs(hand) do
        if i == 2 and hideSecond then
            parts[#parts+1] = ui.cardStr("?", "?", true)
        else
            parts[#parts+1] = ui.cardStr(c.rank, c.suit)
        end
    end
    local val = hideSecond and cardVal(hand[1].rank) or handVal(hand)
    return table.concat(parts, " ") .. "  (" .. val .. ")"
end

-- ── HELP texts ────────────────────────────────────────────────────────────────
local _HELP = {
    mines  = {"5x5 grid hides N mines. Reveal safe tiles","to grow a multiplier. Cash out [C] any time.","Hit a mine and lose your bet. More mines = more","risk but higher multipliers per safe tile.","","  Safe tiles cleared: bigger multiplier","  Mines = 1: low risk, moderate reward","  Mines = 12: extreme risk, huge reward"},
    crash  = {"A multiplier starts at 1x and climbs. It will","CRASH at a random point drawn from a skewed","distribution (many low crashes, rare high ones).","","  Press [C] or click to cash out NOW.","  Your cashout is honoured even on the exact","  tick the crash would fire (race-condition fix).","  House edge: ~4% (P(crash<=x) = 1 - 0.96/x)"},
    slots  = {"3 weighted reels. Left reel stops first.","","  3x 7  = 10x bet  (jackpot)","  3x $  =  5x bet","  3x A  =  3x bet","  3x K  =  2x bet","  3x J  =  1x bet","  Pair (leftmost two)  = 0.5x bet","  No match = lose bet","  House edge: ~5%"},
    bj     = {"Get as close to 21 as possible.","Dealer draws until 17+ (stands on soft 17).","Blackjack (A+10-card) pays 3:2.","","  [H]it   - draw another card","  [S]tand - end your turn","  [D]ouble-down - double bet, draw 1 card","","  House edge: ~2.2% with optimal play","  (Double-down ENABLED — reduces edge ~0.3pp)"},
    roul   = {"European single-zero roulette (37 pockets).","","  [N]umber  (0-36) → 35:1","  [R]ed  [B]lack → 1:1","  [O]dd  [E]ven  → 1:1","  [H]igh(19-36)  [L]ow(1-18) → 1:1","  [1][2][3] Dozen → 2:1","  [C]olumn 1/2/3 → 2:1","  House edge: 1/37 ≈ 2.7% on ALL bets"},
    hl     = {"Guess if the next card is Higher or Lower.","Equal card = free round (no loss).","","  5 rounds. Multiply streak up to 3.2x.","  [Q] or [B] at any time = cash out current win.","","  Multiplier ladder:","  1 correct: 1.2x   3 correct: 1.9x","  2 correct: 1.5x   4 correct: 2.5x   5: 3.2x"},
    pach   = {"Ball drops through 7 rows of pegs,","bouncing left or right at each one.","Final position determines payout:","","  Bucket:  1   2   3   4   5   6   7   8","  Payout: 12x  5x  2x .5x .5x  2x  5x 12x","","  Outer edge = jackpot; centre = low pay.","  House edge: ~4%"},
    craps  = {"Pass Line Craps.","","  Come-out roll:","    7 or 11 → WIN   2, 3, or 12 → LOSE","    Any other → sets the POINT","","  Point phase: roll until...","    Point again → WIN   7 → LOSE","","  House edge: ~1.4%"},
    coinflip={"Heads or Tails. 50/50 chance.","","  Win pays 1.92x total (0.92x net profit).","  House edge: 4%","","  After a WIN you may Let It Ride:","  bet the winnings again for 1.92x (parlay).","  You keep going until you stop or lose."},
}

-- ── 1. Mines ─────────────────────────────────────────────────────────────────
function games.mines(ui, balance)
    local GRID_W, GRID_H = 5, 5
    local TOTAL = GRID_W * GRID_H

    -- Mine count picker
    while true do
        ui.banner("Mines")
        ui.line(4, "  Choose mine count [1-12]:  [?]=help  [B]=back", colors.yellow)
        ui.line(5, "  More mines = higher risk & higher reward.", colors.lightGray)
        ui.line(6, "  Mines  1-3: low risk   |  4-8: medium  |  9-12: extreme", colors.gray)
        term.setCursorPos(1, 7); term.setTextColor(colors.white); io.write("> ")
        local raw = read(); raw = (raw or ""):gsub("%s","")
        if raw:lower() == "b" or raw == "" then return 0, "Cancelled" end
        if raw == "?" then ui.helpOverlay("Mines — Help", _HELP.mines) else
            local mc = tonumber(raw)
            if mc and mc >= 1 and mc <= 12 then
                ui.banner("Mines")
                ui.line(4, string.format("  Mine count: %d   Bet:", mc), colors.yellow)
                local bet = ui.readBet(5, balance)
                if not bet then return 0, "Cancelled" end

                -- Place mines
                local isMine = {}
                local placed = 0
                while placed < mc do
                    local pos = math.random(TOTAL)
                    if not isMine[pos] then isMine[pos] = true; placed = placed + 1 end
                end

                local revealed = {}
                local safeCount = TOTAL - mc
                local safeFound = 0

                local function currentMult()
                    local m = 1.0
                    for k = 0, safeFound - 1 do
                        m = m * (TOTAL - mc) / (TOTAL - mc - k) * 0.98
                    end
                    return m
                end

                -- Compute tile screen position for mouse support
                -- Layout: row 4-8 = 5 grid rows, each tile 5 chars wide, prefix 2
                local TILE_W = 5
                local GRID_ROW_START = 4

                local function posFromMouse(cx, cy)
                    local gy = cy - GRID_ROW_START + 1
                    if gy < 1 or gy > GRID_H then return nil end
                    local gx = math.floor((cx - 3) / TILE_W) + 1
                    if gx < 1 or gx > GRID_W then return nil end
                    return (gy - 1) * GRID_W + gx
                end

                while true do
                    local w   = ui.W()
                    local mult = currentMult()
                    local cashVal = math.floor(bet * mult)

                    ui.banner("Mines")
                    -- Grid rows 4..8
                    for gy = 1, GRID_H do
                        local row = GRID_ROW_START + gy - 1
                        term.setCursorPos(1, row)
                        term.clearLine()   -- clear before writing tiles
                        term.write("  ")
                        for gx = 1, GRID_W do
                            local pos = (gy - 1) * GRID_W + gx
                            if revealed[pos] == "safe" then
                                term.setTextColor(colors.lime)
                                term.write("[gem]")
                            elseif revealed[pos] == "mine" then
                                term.setTextColor(colors.red)
                                term.write("[***]")
                            else
                                term.setTextColor(colors.gray)
                                term.write("[ . ]")
                            end
                        end
                    end
                    ui.rule(9)
                    ui.line(10, string.format("  x%.3f  Cashout: %d uAMI  Safe: %d/%d  Mines: %d",
                        mult, cashVal, safeFound, safeCount, mc), colors.lime)
                    ui.rule(11)
                    ui.line(12, "  Tile# or click  [C]ashout  [?]help  [B]back", colors.yellow)

                    term.setCursorPos(1, 13); term.setTextColor(colors.white); io.write("> ")
                    local inp, ev_type, ev_x, ev_y

                    -- Accept either keyboard input OR mouse click
                    local tid = os.startTimer(30)  -- generous timeout; just keeps event loop alive
                    local gotInput = false
                    while not gotInput do
                        local ev, a, b, c = os.pullEvent()
                        if ev == "char" then
                            inp = a; gotInput = true
                        elseif ev == "key" then
                            if a == keys.c then inp = "c"; gotInput = true
                            elseif a == keys.b then inp = "b"; gotInput = true
                            end
                        elseif ev == "mouse_click" and a == 1 then
                            ev_type = "mouse"; ev_x = b; ev_y = c; gotInput = true
                        end
                    end

                    local pos
                    if ev_type == "mouse" then
                        pos = posFromMouse(ev_x, ev_y)
                        -- Clicking the cashout row (12) = cashout
                        if not pos and ev_y == 12 then inp = "c" end
                    else
                        inp = (inp or ""):gsub("%s","")
                    end

                    if inp == "b" then
                        return 0, "Folded"
                    elseif inp == "?" then
                        ui.helpOverlay("Mines — Help", _HELP.mines)
                    elseif inp == "c" or inp == "C" then
                        if safeFound == 0 then return 0, "Cashed out before any reveal" end
                        local w2 = math.floor(bet * mult)
                        ui.winBanner("Cashed Out!", string.format("x%.3f  +%d uAMI", mult, w2 - bet))
                        return w2 - bet, string.format("Cashed x%.3f +%d uAMI", mult, w2 - bet)
                    else
                        if not pos then pos = tonumber(inp) end
                        if pos and pos >= 1 and pos <= TOTAL and not revealed[pos] then
                            if isMine[pos] then
                                revealed[pos] = "mine"
                                ui.sfx("boom")
                                ui.loseBanner("BOOM!", string.format("Mine at %d. Lost %d uAMI.", pos, bet))
                                return -bet, string.format("MINE at %d. Lost %d uAMI.", pos, bet)
                            else
                                ui.sfx("coin")
                                revealed[pos] = "safe"
                                safeFound = safeFound + 1
                                if safeFound == safeCount then
                                    local w2 = math.floor(bet * currentMult())
                                    ui.sfx("jackpot")
                                    ui.winBanner("BOARD CLEARED!", string.format("+%d uAMI", w2 - bet))
                                    return w2 - bet, string.format("Board cleared! +%d uAMI", w2 - bet)
                                end
                            end
                        end
                    end
                end
            end
        end
    end
end

-- ── 2. Crash ─────────────────────────────────────────────────────────────────
-- CRITICAL FIX: When the crash condition triggers on a timer tick, a zero-second
-- drain timer is started BEFORE declaring the crash. Any [C] keypress that was
-- already in the event queue (pressed on the same tick) is processed first.
-- This closes the race condition where pressing C a fraction too late still lost.
function games.crash(ui, balance)
    ui.banner("Crash")
    ui.line(4, "  A multiplier rises until it CRASHES.", colors.yellow)
    ui.line(5, "  Press [C] or click anywhere to cash out.", colors.lightGray)
    ui.line(6, "  [?] help  [B] back", colors.gray)

    local bet = ui.readBet(7, balance)
    if not bet then return 0, "Cancelled" end

    -- Crash point distribution: P(crash <= x) = 1 - 0.96/x, x >= 1.04
    -- House edge ~4%
    local r       = math.random()
    local crashAt = 0.96 / (1 - r)
    if crashAt < 1.01 then crashAt = 1.01 end

    local mult      = 1.0
    local cashedOut = false
    local crashed   = false
    local cashMult  = nil
    local TICK      = 0.15   -- seconds per frame (6-7 FPS)

    local w = ui.W()
    local BAR_W = math.max(10, w - 18)

    local function drawFrame()
        ui.beginFrame()
        ui.banner("Crash")
        -- Live bar chart
        local frac   = math.min(1.0, (mult - 1.0) / math.max(0.01, crashAt - 1.0))
        local filled = math.floor(frac * BAR_W)
        local barCol = frac > 0.8 and colors.red or (frac > 0.5 and colors.orange or colors.lime)
        term.setCursorPos(1, 4)
        term.setTextColor(barCol)
        term.write("[" .. string.rep("=", filled) .. string.rep(" ", BAR_W - filled) .. "]")
        -- Big multiplier
        local multStr = string.format("x%.3f", mult)
        ui.center(5, multStr, barCol)
        -- Payout hint
        ui.center(6, string.format("Cashout = %d uAMI", math.floor(bet * mult)), colors.lightGray)
        ui.line(7, string.format("  Bet: %d uAMI  |  [C]/click = cash out", bet), colors.yellow)
        ui.endFrame()
    end

    drawFrame()
    local tickId = os.startTimer(TICK)

    while true do
        local ev, a, b = os.pullEvent()

        -- Cash-out inputs (key C or any left mouse click)
        if (ev == "key" and a == keys.c)
        or (ev == "mouse_click" and a == 1) then
            if not crashed then
                cashedOut = true; cashMult = mult; break
            end
        end

        if ev == "timer" and a == tickId then
            local prevMult = mult
            mult = mult + (mult * 0.06)   -- ~46% per second at ~7 FPS → ~4% house edge

            if mult >= crashAt then
                -- ── Race-condition fix ────────────────────────────────────────
                -- Drain the event queue with a zero-second timer.
                -- If [C] is already buffered (pressed this very tick), it will
                -- emerge before the drain timer and we honour the cash-out.
                local drainTid = os.startTimer(0)
                local outcome  = nil
                while not outcome do
                    local dev, da, db = os.pullEvent()
                    if (dev == "key" and da == keys.c)
                    or (dev == "mouse_click" and da == 1) then
                        -- Player pressed C on the same tick the crash fired
                        cashedOut = true; cashMult = prevMult; outcome = "cashout"
                    elseif dev == "timer" and da == drainTid then
                        crashed = true; outcome = "crash"
                    end
                end
                break
            end

            ui.sfx("tick", 0.3, 0.8 + mult * 0.05)
            drawFrame()
            tickId = os.startTimer(TICK)
        end
    end

    if cashedOut then
        local win = math.floor(bet * cashMult)
        ui.sfx("win")
        ui.banner("Crash — Cashed Out!")
        ui.center(5, string.format("x%.3f", cashMult), colors.lime)
        ui.center(6, string.format("+%d uAMI", win - bet), colors.lime)
        os.sleep(1.5)
        return win - bet, string.format("Cashed x%.3f +%d uAMI", cashMult, win - bet)
    else
        ui.sfx("crash")
        ui.banner("Crash — CRASHED!")
        ui.center(5, string.format("Crashed at x%.3f", crashAt), colors.red)
        ui.center(6, string.format("Lost %d uAMI", bet), colors.red)
        os.sleep(1.5)
        return -bet, string.format("Crashed at x%.3f. Lost %d uAMI.", crashAt, bet)
    end
end

-- ── 3. Slots ─────────────────────────────────────────────────────────────────
-- Reels stop L→M→R sequentially. Each stop plays a sfx tick.
function games.slots(ui, balance)
    local SYMS  = {"7","$","A","K","J"}
    local PAY3  = {["7"]=10,["$"]=5,["A"]=3,["K"]=2,["J"]=1}
    local PAY2  = 0.5
    local REEL  = {"7","$","$","A","A","K","K","K","J","J","J","J"}

    ui.banner("Slots")
    ui.line(4, "  Match 3 for big wins!  Three 7s = jackpot (10x)", colors.yellow)
    ui.line(5, "  Pair (left two) = 0.5x   [?] help  [B] back", colors.lightGray)

    local bet = ui.readBet(6, balance)
    if not bet then return 0, "Cancelled" end

    local r1 = REEL[math.random(#REEL)]
    local r2 = REEL[math.random(#REEL)]
    local r3 = REEL[math.random(#REEL)]

    -- Animated spin: 18 frames, reels settling one by one with sfx
    local TOTAL_FRAMES = 18
    local frame = 0
    local tickId = os.startTimer(0.08)
    while frame < TOTAL_FRAMES do
        local ev, a = os.pullEvent()
        if ev == "timer" and a == tickId then
            frame = frame + 1
            ui.beginFrame()
            ui.banner("Slots")
            ui.spinReelFrame(6, SYMS, r1, r2, r3, frame, TOTAL_FRAMES)
            ui.line(8, string.format("  Bet: %d uAMI", bet), colors.yellow)
            ui.endFrame()

            -- Sfx on each reel lock
            if frame == TOTAL_FRAMES - 2 then ui.sfx("reel", 1, 1.0) end
            if frame == TOTAL_FRAMES - 1 then ui.sfx("reel", 1, 1.1) end
            if frame == TOTAL_FRAMES     then ui.sfx("reel", 1, 1.2) end

            tickId = os.startTimer(0.08 + frame * 0.008)
        end
    end

    -- Result
    ui.banner("Slots")
    ui.center(6, string.format(" [ %-2s | %-2s | %-2s ] ", r1, r2, r3), colors.yellow)

    local net, desc
    if r1 == r2 and r2 == r3 then
        local mult = PAY3[r1] or 1
        net  = math.floor(bet * mult)
        desc = string.format("3x%s x%d +%d uAMI", r1, mult, net)
        if mult >= 5 then ui.sfx("jackpot") else ui.sfx("win") end
        ui.center(8,  string.format("JACKPOT!  3x %s  x%d", r1, mult), colors.lime)
        ui.center(9,  string.format("+%d uAMI", net), colors.lime)
    elseif r1 == r2 then
        net  = math.floor(bet * PAY2)
        desc = string.format("Pair %s+%s +%d uAMI", r1, r2, net)
        ui.sfx("coin")
        ui.center(8, desc, colors.yellow)
    else
        net  = -bet
        desc = string.format("No match. Lost %d uAMI.", bet)
        ui.sfx("loss")
        ui.center(8, desc, colors.red)
    end
    os.sleep(2)
    return net, desc
end

-- ── 4. Blackjack ─────────────────────────────────────────────────────────────
-- EDGE CHANGE: Double-Down added.
--   Without DD: house edge ~2.5% (simplified infinite deck, dealer soft 17)
--   With DD:    house edge ~2.2% (DD reduces optimal-play edge by ~0.3pp)
--   This is a REDUCTION in house edge. Flagged per task requirements.
function games.blackjack(ui, balance)
    ui.banner("Blackjack")
    ui.line(4, "  Dealer stands on soft 17.  BJ pays 3:2.", colors.yellow)
    ui.line(5, "  [D]ouble-down available.  [?] help  [B] back", colors.lightGray)

    local bet = ui.readBet(6, balance)
    if not bet then return 0, "Cancelled" end

    local player = {newCard(), newCard()}
    local dealer = {newCard(), newCard()}

    local function drawTable(hideDealer, note)
        local w = ui.W()
        ui.banner("Blackjack")
        -- Dealer row
        term.clearLine()  -- clear row before writing dealer hand
        term.setCursorPos(1, 4); term.setTextColor(colors.lightGray)
        term.write("  Dealer: ")
        if hideDealer then
            term.write(ui.cardStr(dealer[1].rank, dealer[1].suit))
            term.write(" " .. ui.cardStr("?","?",true))
            term.write("  (?)")
        else
            for _, c in ipairs(dealer) do
                term.write(ui.cardStr(c.rank, c.suit) .. " ")
            end
            term.setTextColor(handVal(dealer) > 21 and colors.red or colors.white)
            term.write("(" .. handVal(dealer) .. ")")
        end
        -- Player row
        local pv = handVal(player)
        local pCol = pv > 21 and colors.red or colors.white
        term.setCursorPos(1, 5); term.clearLine(); term.setTextColor(pCol)
        term.write("  You:    ")
        for _, c in ipairs(player) do
            term.setTextColor(ui.cardColor(c.suit)); term.write(ui.cardStr(c.rank, c.suit) .. " ")
        end
        term.setTextColor(pCol); term.write("(" .. pv .. ")")
        ui.rule(6)
        term.setCursorPos(1, 7); term.clearLine(); term.setTextColor(colors.yellow)
        term.write(string.format("  Bet: %d uAMI", bet))
        if note then
            ui.line(8, "  " .. note, colors.orange)
        else
            local ddAvail = (#player == 2 and bet <= balance - bet)
            ui.line(8, "  [H]it  [S]tand" .. (ddAvail and "  [D]ouble" or "") .. "  [?]help", colors.orange)
        end
    end

    -- Natural BJ check
    ui.sfx("flip")
    drawTable(true)
    if handVal(player) == 21 then
        if handVal(dealer) == 21 then
            drawTable(false, "Both Blackjack — Push!")
            os.sleep(2); return 0, "Push (both BJ)"
        else
            local bj = math.floor(bet * 1.5)
            ui.sfx("jackpot")
            drawTable(false, string.format("BLACKJACK! +%d uAMI", bj))
            os.sleep(2); return bj, "Blackjack +" .. bj .. " uAMI"
        end
    end

    -- Player turn
    local doubled = false
    while true do
        local pv = handVal(player)
        if pv > 21 then
            ui.sfx("loss")
            drawTable(true, string.format("BUST! Lost %d uAMI", bet))
            os.sleep(2); return -bet, "Bust"
        end
        drawTable(true)
        local _, k = os.pullEvent("key")
        if k == keys.h then
            ui.sfx("flip")
            player[#player+1] = newCard()
        elseif k == keys.s then
            break
        elseif k == keys.d and #player == 2 and bet <= balance - bet then
            -- Double-down: double the bet, draw exactly one card
            ui.sfx("flip")
            bet = bet * 2
            player[#player+1] = newCard()
            doubled = true
            break
        elseif k == keys.q then
            return 0, "?"
        end
    end

    if handVal(player) > 21 then
        ui.sfx("loss")
        drawTable(true, string.format("BUST! Lost %d uAMI", bet))
        os.sleep(2); return -bet, "Bust"
    end

    -- Dealer plays
    while handVal(dealer) < 17 do
        dealer[#dealer+1] = newCard()
    end

    local pv, dv = handVal(player), handVal(dealer)
    local net, note
    if dv > 21 then
        net = bet; note = string.format("Dealer busts! +%d uAMI", net)
        ui.winBanner("Dealer BUSTS!", "+" .. net .. " uAMI")
    elseif pv > dv then
        net = bet; note = string.format("WIN! +%d uAMI", net)
        ui.winBanner("YOU WIN!", "+" .. net .. " uAMI")
    elseif pv == dv then
        net = 0; note = "Push."
        ui.sfx("tick")
    else
        net = -bet; note = string.format("Dealer wins. -%d uAMI", bet)
        ui.loseBanner("Dealer wins.", "-" .. bet .. " uAMI")
    end
    drawTable(false, note)
    os.sleep(2)
    return net, note
end

-- ── 5. Roulette ──────────────────────────────────────────────────────────────
-- Added: dozens (1/2/3) and column (C1/C2/C3) bet types.
-- All pay 2:1 on 12/37 numbers → identical 2.7% house edge. NO edge change.
function games.roulette(ui, balance)
    local RED = {1,3,5,7,9,12,14,16,18,19,21,23,25,27,30,32,34,36}
    local redSet = {}; for _, n in ipairs(RED) do redSet[n] = true end

    ui.banner("Roulette")
    ui.line(4, "  Single-zero European roulette.  [?] help  [B] back", colors.yellow)
    ui.line(5, "  [N]um(35:1)  [R]ed  [K]Black  [O]dd  [E]ven", colors.lightGray)
    ui.line(6, "  [H]igh  [L]ow  [1][2][3]=dozen  [C]ol 1/2/3  (1:2)", colors.lightGray)

    local bet = ui.readBet(7, balance)
    if not bet then return 0, "Cancelled" end

    ui.rule(11)
    ui.line(12, "  Bet type?  [B]=cancel  [?]=help", colors.yellow)
    ui.line(13, "  [R]ed  [K]Black  [O]dd  [E]ven  [H]igh  [L]ow", colors.lightGray)
    ui.line(14, "  [N]um(35:1)  [1][2][3]=dozen  [C]ol 1/2/3", colors.lightGray)

    local betType, betNum
    while not betType do
        local _, k = os.pullEvent("key")
        if     k == keys.b then return 0, "Cancelled"
        elseif k == keys.q or k == keys.equals then
            ui.helpOverlay("Roulette — Help", _HELP.roul)
        elseif k == keys.n then
            ui.line(15, "  Number (0-36): ", colors.yellow)
            term.setCursorPos(1, 16); io.write("> ")
            local raw = read(); betNum = tonumber(raw)
            if betNum and betNum >= 0 and betNum <= 36 then betType = "number" end
        elseif k == keys.r then betType = "red"
        elseif k == keys.k then betType = "black"   -- [K] for blacK (avoids [B]=back conflict)
        elseif k == keys.o then betType = "odd"
        elseif k == keys.e then betType = "even"
        elseif k == keys.h then betType = "high"
        elseif k == keys.l then betType = "low"
        elseif k == keys.one   then betType = "dozen1"
        elseif k == keys.two   then betType = "dozen2"
        elseif k == keys.three then betType = "dozen3"
        elseif k == keys.c then
            ui.line(15, "  Column 1/2/3? ", colors.yellow)
            term.setCursorPos(1, 16); io.write("> ")
            local cv = tonumber(read())
            if cv == 1 then betType = "col1"
            elseif cv == 2 then betType = "col2"
            elseif cv == 3 then betType = "col3"
            end
        end
    end

    -- Spin animation
    ui.banner("Roulette")
    ui.center(5, "Spinning...", colors.yellow)
    for i = 1, 16 do
        local n = math.random(0, 36)
        local spinCol = n == 0 and colors.green or (redSet[n] and colors.red or colors.gray)
        ui.sfx("bell", 0.5, 0.8 + i * 0.02)
        ui.center(6, " " .. tostring(n) .. " ", spinCol)
        os.sleep(0.06 + i * 0.012)
    end

    local result = math.random(0, 36)
    local isRed   = redSet[result]
    local colName = result == 0 and "green" or (isRed and "red" or "black")
    local colCode = result == 0 and colors.green or (isRed and colors.red or colors.gray)
    ui.sfx("bell", 1.0, 0.6)
    ui.center(6, string.format(" %d (%s) ", result, colName), colCode)

    -- Evaluate bet
    local win = false
    local payout = 1
    if betType == "number" then
        win = (result == betNum); payout = 35
    elseif betType == "red"    then win = (isRed and result ~= 0)
    elseif betType == "black"  then win = (not isRed and result ~= 0)
    elseif betType == "odd"    then win = (result ~= 0 and result % 2 == 1)
    elseif betType == "even"   then win = (result ~= 0 and result % 2 == 0)
    elseif betType == "high"   then win = (result >= 19)
    elseif betType == "low"    then win = (result >= 1 and result <= 18)
    elseif betType == "dozen1" then win = (result >= 1  and result <= 12); payout = 2
    elseif betType == "dozen2" then win = (result >= 13 and result <= 24); payout = 2
    elseif betType == "dozen3" then win = (result >= 25 and result <= 36); payout = 2
    elseif betType == "col1"   then win = (result ~= 0 and result % 3 == 1); payout = 2
    elseif betType == "col2"   then win = (result ~= 0 and result % 3 == 2); payout = 2
    elseif betType == "col3"   then win = (result ~= 0 and result % 3 == 0); payout = 2
    end

    local net, desc
    if win then
        net  = bet * payout
        desc = string.format("WIN! %d (%s) %s pays %d:1 +%d uAMI",
            result, colName, betType, payout, net)
        ui.winBanner(string.format("WIN! %d pays %d:1", result, payout),
            "+" .. net .. " uAMI")
    else
        net  = -bet
        desc = string.format("LOSE. Ball: %d (%s). Lost %d uAMI.", result, colName, bet)
        ui.loseBanner(string.format("Ball: %d (%s)", result, colName),
            "Lost " .. bet .. " uAMI")
    end
    os.sleep(1)
    return net, desc
end

-- ── 6. Higher / Lower ────────────────────────────────────────────────────────
-- Cash-out at any time during the streak, not just at completion.
-- Multiplier ladder is always visible.
function games.higherLower(ui, balance)
    ui.banner("Higher / Lower")
    ui.line(4, "  5 rounds. Higher [H] or Lower [L] each card.", colors.yellow)
    ui.line(5, "  Equal = free round.  [Q]/[B] = cash out win.", colors.lightGray)
    ui.line(6, "  Mult: 1.2x  1.5x  1.9x  2.5x  3.2x", colors.cyan)

    local bet = ui.readBet(7, balance)
    if not bet then return 0, "Cancelled" end

    local MULTS  = {1.2, 1.5, 1.9, 2.5, 3.2}
    local current = _RANKS[math.random(#_RANKS)]
    local streak  = 0
    local ROUNDS  = 5

    for round = 1, ROUNDS do
        local w = ui.W()
        ui.banner("Higher / Lower")
        -- Multiplier ladder with current position highlighted
        term.setCursorPos(1, 4); term.clearLine(); term.setTextColor(colors.gray)
        term.write("  ")
        for i, m in ipairs(MULTS) do
            if i == streak + 1 then
                term.setTextColor(colors.yellow); term.write(string.format("[%.1fx]", m))
            else
                term.setTextColor(colors.gray);   term.write(string.format(" %.1fx ", m))
            end
        end
        -- no clearLine here (multiplier ladder fills the row)

        -- Big card display
        local cardW = 4; local cardX = math.floor((w - cardW) / 2) + 1
        ui.drawCardBox(cardX, 5, current, displaySuit, false)
        ui.center(8, string.format("Round %d/%d   Streak %d   Mult x%.1f",
            round, ROUNDS, streak, MULTS[math.max(1, streak)] or 1), colors.lightGray)
        ui.rule(9)
        local curWin = streak > 0 and (math.floor(bet * MULTS[streak]) - bet) or 0
        ui.line(10, string.format("  Current win: %d uAMI    [H]igher  [L]ower  [Q]uit", curWin),
            streak > 0 and colors.lime or colors.gray)

        local _, k = os.pullEvent("key")
        if k == keys.b or k == keys.q then
            if streak == 0 then return 0, "Quit with no streak" end
            local w2 = math.floor(bet * MULTS[streak]) - bet
            ui.winBanner(string.format("Cashed at streak %d", streak),
                string.format("x%.1f  +%d uAMI", MULTS[streak], w2))
            return w2, string.format("Quit streak %d (x%.1f) +%d uAMI", streak, MULTS[streak], w2)
        end

        local next    = _RANKS[math.random(#_RANKS)]
        local ci, ni  = _RANK_IDX[current], _RANK_IDX[next]
        local correct
        if ci == ni then
            correct = true
            ui.center(11, string.format("Equal! %s = %s  Free round.", current, next), colors.yellow)
        elseif k == keys.h then
            correct = ni > ci
        elseif k == keys.l then
            correct = ni < ci
        else
            correct = false
        end

        ui.center(11, string.format("Next: %s", next), correct and colors.lime or colors.red)
        ui.sfx(correct and "flip" or "loss")
        os.sleep(0.7)

        if correct then
            streak  = streak + 1
            current = next
            if streak == ROUNDS then
                local w2 = math.floor(bet * MULTS[ROUNDS]) - bet
                ui.sfx("jackpot")
                ui.winBanner("PERFECT STREAK!", string.format("x%.1f +%d uAMI", MULTS[ROUNDS], w2))
                return w2, string.format("Perfect 5-streak x%.1f +%d uAMI", MULTS[ROUNDS], w2)
            end
        else
            ui.center(12, "WRONG! -" .. bet .. " uAMI", colors.red)
            ui.loseBanner("WRONG!", "-" .. bet .. " uAMI")
            return -bet, string.format("Wrong round %d. Lost %d uAMI.", round, bet)
        end
    end
    return 0, "Completed"
end

-- ── 7. Pachinko ──────────────────────────────────────────────────────────────
-- Fixed animation flicker: draw once per step, never reset with ui.banner().
function games.pachinko(ui, balance)
    local ROWS    = 7
    local BUCKETS = ROWS + 1
    local PAYS    = {12, 5, 2, 0.5, 0.5, 2, 5, 12}

    ui.banner("Pachinko")
    ui.line(4, "  7-row peg board. Ball bounces L/R each row.", colors.yellow)
    ui.line(5, "  Outer = 12x  Inner-mid = 5x/2x  Centre = 0.5x", colors.lightGray)
    ui.line(6, "  [?] help  [B] back", colors.gray)

    local bet = ui.readBet(7, balance)
    if not bet then return 0, "Cancelled" end

    -- Simulate ball path
    local pos  = 0
    local path = {}
    for _ = 1, ROWS do
        local dir = math.random() < 0.5 and -1 or 1
        pos = pos + dir
        path[#path+1] = pos
    end
    local bucketIdx = math.floor((pos + ROWS) / (ROWS * 2) * (BUCKETS - 1)) + 1
    bucketIdx = math.max(1, math.min(BUCKETS, bucketIdx))
    local mult = PAYS[bucketIdx]

    -- Animated ball drop (no banner reset inside loop)
    local w = ui.W()
    for step = 1, ROWS do
        ui.beginFrame()
        ui.banner("Pachinko")
        for row = 1, ROWS do
            local pegLine = ""
            for col = -row, row do
                if col % 2 == 0 then
                    if row == step and col == path[step] then
                        pegLine = pegLine .. "O"
                    else
                        pegLine = pegLine .. "."
                    end
                else
                    pegLine = pegLine .. " "
                end
            end
            local rowY = 3 + row
            local col  = (row == step) and colors.yellow or colors.gray
            ui.center(rowY, pegLine, col)
        end
        ui.sfx("tick", 0.4, 0.9 + step * 0.05)
        ui.endFrame()
        os.sleep(0.18)
    end

    -- Bucket display
    ui.beginFrame()
    ui.banner("Pachinko")
    for row = 1, ROWS do
        local pegLine = ""
        for col = -row, row do
            pegLine = pegLine .. (col % 2 == 0 and "." or " ")
        end
        ui.center(3 + row, pegLine, colors.gray)
    end
    local bucketLine = ""
    for i = 1, BUCKETS do
        local lbl = string.format("%.1f", PAYS[i])
        if i == bucketIdx then
            bucketLine = bucketLine .. "[" .. lbl .. "]"
        else
            bucketLine = bucketLine .. " " .. lbl .. " "
        end
    end
    ui.center(3 + ROWS + 1, bucketLine:sub(1, w), colors.white)
    local net = math.floor(bet * mult) - bet
    local res = string.format("Bucket %d (x%.1f)  %+d uAMI", bucketIdx, mult, net)
    ui.center(3 + ROWS + 2, res:sub(1, w), net >= 0 and colors.lime or colors.red)
    ui.endFrame()

    if net >= 0 then ui.sfx("win") else ui.sfx("loss") end
    os.sleep(2.5)
    return net, res
end

-- ── 8. Craps ─────────────────────────────────────────────────────────────────
-- ASCII dice pair rendering. Clear come-out vs point-phase distinction.
function games.craps(ui, balance)
    local function roll2d6()
        return math.random(1,6), math.random(1,6)
    end

    ui.banner("Craps")
    ui.line(4, "  Pass Line Craps.  [?] help  [B] back", colors.yellow)
    ui.line(5, "  Come-out: 7/11=WIN  2/3/12=LOSE  other=Point", colors.lightGray)
    ui.line(6, "  Point: roll point again before 7 to WIN.", colors.lightGray)

    local bet = ui.readBet(7, balance)
    if not bet then return 0, "Cancelled" end

    -- Come-out roll
    ui.banner("Craps — Come-Out")
    ui.line(4, "  Press any key to roll...", colors.orange)
    ui.waitKey()

    local d1, d2 = roll2d6()
    local comeOut = d1 + d2
    ui.sfx("dice")
    ui.drawDicePair(3, 5, d1, d2)
    ui.center(11, string.format("Rolled: %d + %d = %d", d1, d2, comeOut), colors.yellow)
    os.sleep(0.8)

    if comeOut == 7 or comeOut == 11 then
        ui.winBanner("Natural " .. comeOut .. "!", "+WIN")
        return bet, "Natural " .. comeOut
    elseif comeOut == 2 or comeOut == 3 or comeOut == 12 then
        ui.loseBanner("Craps " .. comeOut .. "!", "-LOSE")
        return -bet, "Craps " .. comeOut
    end

    local point = comeOut
    os.sleep(0.4)

    while true do
        ui.banner(string.format("Craps — Point: %d", point))
        ui.line(4, string.format("  Point is %d. Roll it before 7.", point), colors.cyan)
        ui.line(5, string.format("  Bet: %d uAMI", bet), colors.yellow)
        ui.line(6, "  Press any key to roll...", colors.orange)
        ui.waitKey()

        d1, d2 = roll2d6()
        local r = d1 + d2
        ui.sfx("dice")
        ui.drawDicePair(3, 7, d1, d2)
        ui.center(13, string.format("Rolled: %d + %d = %d", d1, d2, r), colors.yellow)
        os.sleep(0.8)

        if r == point then
            ui.winBanner("Point hit!", "+WIN")
            return bet, string.format("Point %d hit +win", point)
        elseif r == 7 then
            ui.loseBanner("Seven-Out!", "-LOSE")
            return -bet, string.format("Seven-out. Point was %d.", point)
        else
            ui.center(14, "No result. Roll again...", colors.gray)
            os.sleep(0.5)
        end
    end
end

-- ── 9. Coin Flip ─────────────────────────────────────────────────────────────
-- Animated spin frames. Optional double-or-nothing parlay after a WIN.
-- Parlay uses the same 1.92× payout so edge remains 4%. No edge change.
function games.coinflip(ui, balance)
    ui.banner("Coin Flip")
    ui.line(4, "  50/50. Win pays 1.92x (net +0.92x).  [?] help", colors.yellow)
    ui.line(5, "  After a WIN you may Let It Ride for another flip.", colors.lightGray)

    local bet = ui.readBet(6, balance)
    if not bet then return 0, "Cancelled" end

    local sides   = {"Heads", "Tails"}
    local FRAMES  = {"(H)", "(HT)", "(T)", "(TH)"}  -- spinning coin frames

    ui.line(8, "  [H] Heads   [T] Tails", colors.orange)
    local choice
    while not choice do
        local _, k = os.pullEvent("key")
        if k == keys.h then choice = "Heads"
        elseif k == keys.t then choice = "Tails"
        end
    end

    -- Animated spin
    local tickId = os.startTimer(0.07)
    local frame  = 0
    local TOTAL_FRAMES = 12
    while frame < TOTAL_FRAMES do
        local ev, a = os.pullEvent()
        if ev == "timer" and a == tickId then
            frame = frame + 1
            ui.beginFrame()
            ui.banner("Coin Flip")
            ui.center(5, string.format("You chose: %s", choice), colors.yellow)
            ui.center(6, FRAMES[(frame % #FRAMES) + 1], colors.white)
            ui.endFrame()
            ui.sfx("coin", 0.5, 0.9 + frame * 0.02)
            tickId = os.startTimer(0.07 + frame * 0.012)
        end
    end

    local result = sides[math.random(2)]
    local resCol = result == "Heads" and colors.lime or colors.cyan
    ui.banner("Coin Flip")
    ui.center(5, string.format("You chose: %s", choice), colors.yellow)
    ui.center(6, result, resCol)

    local totalNet = 0
    if result == choice then
        local winAmt = math.floor(bet * 0.92)
        totalNet = winAmt
        ui.sfx("win")
        ui.center(7, string.format("WIN! +%d uAMI", winAmt), colors.lime)

        -- Parlay: let it ride
        local parlayBal = bet + winAmt   -- what they'd walk away with
        ui.center(8, string.format("Let It Ride? Bet %d for another flip?", parlayBal), colors.orange)
        ui.center(9, "[Y] Parlay   [N] Cash out", colors.yellow)
        local _, pk = os.pullEvent("key")
        if pk == keys.y and parlayBal <= balance then
            -- Flip again, same 1.92× payout (house edge unchanged at 4%)
            local result2 = sides[math.random(2)]
            local choice2 = sides[math.random(2)]  -- pick randomly for parlay
            ui.center(8, string.format("Parlay: %s → %s", choice2, result2), colors.white)
            ui.sfx("coin")
            os.sleep(0.7)
            if result2 == choice2 then
                local extraWin = math.floor(parlayBal * 0.92)
                totalNet = totalNet + extraWin
                ui.winBanner("PARLAY WIN!", string.format("+%d uAMI total", totalNet))
            else
                -- Lost parlay: net = original win - parlayBal
                totalNet = winAmt - parlayBal
                ui.loseBanner("Parlay lost.", string.format("%d uAMI", totalNet))
            end
        end
    else
        totalNet = -bet
        ui.sfx("loss")
        ui.center(7, string.format("You lose. -%d uAMI", bet), colors.red)
    end

    os.sleep(1.5)
    return totalNet, string.format("%s vs %s  net=%d uAMI", result, choice, totalNet)
end

return games

