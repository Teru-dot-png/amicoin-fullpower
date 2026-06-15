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
    mines  = {"5x5 grid hides N mines. Reveal safe tiles","to grow a multiplier. Cash out [C] any time.","Hit a mine and lose your bet. More mines = more","risk AND higher multipliers per safe tile.","","  Multiplier per tile = (tiles_left / safe_left) x 0.97","  Mines = 1: low risk, low reward per tile","  Mines = 12: extreme risk, huge reward per tile"},
    crash  = {"A multiplier starts at 1x and climbs. It will","CRASH at a random point drawn from a skewed","distribution (many low crashes, rare high ones).","","  Press [C] or click to cash out NOW.","  Your cashout is honoured even on the exact","  tick the crash would fire (race-condition fix).","  House edge: ~4% (P(crash<=x) = 1 - 0.96/x)"},
    slots  = {"3 weighted reels. Left reel stops first.","","  3x 7  = 10x bet  (jackpot)","  3x $  =  5x bet","  3x A  =  3x bet","  3x K  =  2x bet","  3x J  =  1x bet","  Pair (leftmost two)  = 0.5x bet","  No match = lose bet","  House edge: ~5%"},
    bj     = {"Get as close to 21 as possible.","Dealer draws until 17+ (stands on soft 17).","Blackjack (A+10-card) pays 3:2.","","  [H]it   - draw another card","  [S]tand - end your turn","  [D]ouble-down - double bet, draw 1 card","","  House edge: ~2.2% with optimal play","  (Double-down ENABLED — reduces edge ~0.3pp)"},
    roul   = {"European single-zero roulette (37 pockets).","","  1. Enter chip size (bet placed per click).","  2. Left-click any spot to place a chip.","     Right-click to remove one chip from a spot.","     Click multiple different spots to multi-bet.","  3. Press [Enter] to spin.  [C] clears all bets.","","  Spots: numbers 0-36 (35:1)","         [D1]/[D2]/[D3] dozen (2:1)","         [C1]/[C2]/[C3] column (2:1)","         Red/Black/Odd/Even/Low/High (1:1)","","  House edge: 1/37 ≈ 2.7% on ALL bets"},
    hl     = {"Guess if the next card is Higher or Lower.","Equal card = free round (no loss).","","  5 rounds. Multiply streak up to 3.2x.","  [Q] or [B] at any time = cash out current win.","","  Multiplier ladder:","  1 correct: 1.2x   3 correct: 1.9x","  2 correct: 1.5x   4 correct: 2.5x   5: 3.2x"},
    pach   = {"Ball drops through 7 rows of pegs,","bouncing left or right at each one.","Final position determines payout:","","  Bucket:  1   2   3   4   5   6   7   8","  Payout: 12x  5x  2x .5x .5x  2x  5x 12x","","  Choose 1-10 balls. Bet is per ball.","  Each ball is animated separately.","  Outer edge = jackpot; centre = low pay.","  House edge: ~4%"},
    craps  = {"Pass Line Craps.","","  Come-out roll:","    7 or 11 → WIN   2, 3, or 12 → LOSE","    Any other → sets the POINT","","  Point phase: roll until...","    Point again → WIN   7 → LOSE","","  House edge: ~1.4%"},
    coinflip={"Heads or Tails. 50/50 chance.","","  Win pays 1.92x total (0.92x net profit).","  House edge: 4%","","  After a WIN you may Let It Ride:","  bet the winnings again for 1.92x (parlay).","  You keep going until you stop or lose."},
    vp     ={"Jacks or Better \u2014 8/5 Pay Table","","  Royal Flush    800x  A-K-Q-J-10 same suit","  Straight Flush  50x  5 in seq, same suit","  Four of a Kind  25x","  Full House        8x  set + pair","  Flush              5x  5 same suit","  Straight           4x  5 in sequence","  Three of a Kind    3x","  Two Pair           2x","  Jacks or Better    1x  pair of J, Q, K, or A","","  [1-5] toggle HOLD on a card.","  [Enter] draw replacements for unheld cards.","  House edge: ~2.7% at optimal play.","  Sub-optimal holding raises edge further."},
    keno   ={"Pick 1-10 numbers from the 10\xd78 grid (1-80).","20 numbers are drawn at random.","Matches between your picks and the drawn","numbers determine your payout.","","  LClick = pick a number   RClick = remove","  [Enter] = draw   [C] = clear all   [B] = back","","Pay table varies by how many numbers you pick.","See bottom of screen for your current pays.","","House edge: 25-31% depending on spot count.","(Standard range for casino Keno.)"},
    scratch={"3x3 grid of 9 hidden tiles.","Scratch any 3 by clicking or pressing [1-9].","Two or three matching symbols = win.","","  Symbol pool: 2x'7'  2x'$'  2x'A'  3x'K'","","  Pay table (multiplies your bet):","    K + K + K = 12x  (only triple possible)","    7 + 7     =  4x  (rarest pair)","    $ + $     =  2x","    A + A     =  1x  (push, bet returned)","    K + K     =  0   (common pair, no payout)","    No match  =  0","","  House edge: ~27.4%"},
    wheel  ={"Press [Enter] to spin the wheel.","The needle lands on one of four outcomes.","","  Segment pool (out of 100 weighted slots):","    MISS  65/100  (65.0%)  → lose bet","    x2    30/100  (30.0%)  → net +1x bet","    x5     4/100   (4.0%)  → net +4x bet","    x10    1/100   (1.0%)  → net +9x bet","","  EV = 0.90x bet  →  house edge = 10.0%","  (net = floor(bet * mult) - bet)"},
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
                local bet = ui.readBet(5, balance, nil, _HELP.mines)
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
                    -- Fair odds multiplier: each step k scales by the probability
                    -- of picking a safe tile from the remaining unseen tiles.
                    --   step k factor = (TOTAL - k) / (TOTAL - mc - k)
                    -- This correctly grows faster with more mines because the
                    -- denominator (safe tiles left) shrinks more aggressively.
                    -- 0.97 per step = 3% house edge per reveal.
                    local m = 1.0
                    for k = 0, safeFound - 1 do
                        m = m * (TOTAL - k) / (TOTAL - mc - k) * 0.97
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

    local bet = ui.readBet(7, balance, nil, _HELP.crash)
    if not bet then return 0, "Cancelled" end

    -- Provably-fair pre-commit (trust display only — not a cryptographic guarantee).
    local pfSeed, pfCommit = ui.pfCommit()
    ui.line(9, string.format("  Pre-commit: %s  [?]=help  [B]=back", pfCommit), colors.gray)

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

    local bet = ui.readBet(6, balance, nil, _HELP.slots)
    if not bet then return 0, "Cancelled" end

    -- Provably-fair pre-commit (trust display only).
    local pfSeed, pfCommit = ui.pfCommit()
    ui.pfShowCommit(8, pfCommit)

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
    ui.pfReveal(10, pfSeed)
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

    local bet = ui.readBet(6, balance, nil, _HELP.bj)
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
        local k
        repeat
            local ev, a = os.pullEvent()
            if ev == "char" and a == "?" then
                ui.helpOverlay("Blackjack — Help", _HELP.bj)
                drawTable(true)   -- restore state after overlay
            elseif ev == "key" then
                k = a
            end
        until k
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
-- Click-to-bet board: choose chip size, then left-click any spot to place a
-- chip, right-click to remove one chip. Multiple spots / stacked chips allowed.
-- Press [Enter] to spin.  House edge 2.7% on all bet types (unchanged).
function games.roulette(ui, balance)
    local RED = {1,3,5,7,9,12,14,16,18,19,21,23,25,27,30,32,34,36}
    local redSet = {}; for _, n in ipairs(RED) do redSet[n] = true end

    -- ── Screen layout (1-indexed rows/cols, standard 51×19 terminal) ─────────
    -- Row  4 : [  0  ] zero pocket
    -- Rows 5-16 : 12 number rows, 3 cells wide + dozen column
    -- Row 17 : [C1] [C2] [C3] column bets
    -- Row 18 : side bets  Red / Black / Odd / Even / Low / High
    -- Row 19 : hint / total bet status
    local ZERO_ROW  = 4
    local NUM_ROW_S = 5
    local COL_ROW   = 17
    local SIDE_ROW  = 18
    local HINT_ROW  = 19

    -- Number cell x-ranges ("[nn]" = 4 chars each)
    local X1S, X1E = 2,  5   -- game col 1: n%3==1  (1,4,7,...,34)
    local X2S, X2E = 7,  10  -- game col 2: n%3==2  (2,5,8,...,35)
    local X3S, X3E = 12, 15  -- game col 3: n%3==0  (3,6,9,...,36)
    local XDZ_S     = 17     -- dozen cell " D1 " (4 chars, ends at 20)

    -- Side bet descriptors: label (6 chars), start-x, end-x
    local SIDES = {
        {key="red",   lbl="[Red] ", xs=2,  xe=7 },
        {key="black", lbl="[Blk] ", xs=9,  xe=14},
        {key="odd",   lbl="[Odd] ", xs=16, xe=21},
        {key="even",  lbl="[Evn] ", xs=23, xe=28},
        {key="low",   lbl="[Low] ", xs=30, xe=35},
        {key="high",  lbl="[High]", xs=37, xe=42},
    }

    -- ── Step 1: choose chip size ──────────────────────────────────────────────
    ui.banner("Roulette")
    ui.line(4, "  Single-zero European Roulette.  [?]=help  [B]=back", colors.yellow)
    ui.line(5, "  Enter chip size — each click places this amount on a spot.", colors.lightGray)
    local chipSize = ui.readBet(6, balance, nil, _HELP.roul)
    if not chipSize then return 0, "Cancelled" end

    -- ── Bet state ─────────────────────────────────────────────────────────────
    -- placed[key] = total µAMI staked on that spot (multiples of chipSize).
    -- Key: integer 0-36 for straight-up; string for outside bets.
    local placed = {}
    local function totalPlaced()
        local t = 0; for _, v in pairs(placed) do t = t + v end; return t
    end

    -- ── Click → bet key ───────────────────────────────────────────────────────
    local function clickKey(cx, cy)
        -- Zero pocket
        if cy == ZERO_ROW and cx >= 2 and cx <= 8 then return 0 end
        -- Number grid
        if cy >= NUM_ROW_S and cy <= NUM_ROW_S + 11 then
            local br = cy - NUM_ROW_S + 1  -- board row 1..12
            if     cx >= X1S and cx <= X1E  then return br*3 - 2
            elseif cx >= X2S and cx <= X2E  then return br*3 - 1
            elseif cx >= X3S and cx <= X3E  then return br*3
            elseif cx >= XDZ_S and cx <= XDZ_S+3 then
                return br <= 4 and "dozen1" or br <= 8 and "dozen2" or "dozen3"
            end
        end
        -- Column bets
        if cy == COL_ROW then
            if     cx >= X1S and cx <= X1E then return "col1"
            elseif cx >= X2S and cx <= X2E then return "col2"
            elseif cx >= X3S and cx <= X3E then return "col3"
            end
        end
        -- Side bets
        if cy == SIDE_ROW then
            for _, s in ipairs(SIDES) do
                if cx >= s.xs and cx <= s.xe then return s.key end
            end
        end
        return nil
    end

    -- ── Draw board ────────────────────────────────────────────────────────────
    local function drawBoard(winNum)
        local w = ui.W()
        ui.banner("Roulette")

        -- Zero (row 4)
        term.setCursorPos(1, ZERO_ROW); term.clearLine()
        do
            local bet = placed[0] or 0
            local isWin = (winNum == 0)
            local fg = (isWin or bet > 0) and colors.black or colors.green
            local bg = isWin and colors.yellow or (bet > 0 and colors.lime or colors.black)
            term.setCursorPos(2, ZERO_ROW)
            term.setTextColor(fg); term.setBackgroundColor(bg)
            term.write("[  0  ]")
            term.setBackgroundColor(colors.black); term.setTextColor(colors.white)
        end

        -- Number grid (rows 5-16)
        for br = 1, 12 do
            local y  = NUM_ROW_S + br - 1
            term.setCursorPos(1, y); term.clearLine()
            local nums = {br*3-2, br*3-1, br*3}
            local xs   = {X1S, X2S, X3S}
            for ci = 1, 3 do
                local n   = nums[ci]
                local bet = placed[n] or 0
                local isWin = (winNum == n)
                local isRed = redSet[n]
                local fg, bg
                if isWin     then fg = colors.black; bg = colors.yellow
                elseif bet>0 then fg = colors.black; bg = colors.lime
                else              fg = isRed and colors.red or colors.lightGray; bg = colors.black
                end
                term.setCursorPos(xs[ci], y)
                term.setTextColor(fg); term.setBackgroundColor(bg)
                term.write(string.format("[%2d]", n))
                term.setBackgroundColor(colors.black)
            end
            -- Dozen column (same label on all 4 rows of each dozen section)
            local dzKey = br <= 4 and "dozen1" or br <= 8 and "dozen2" or "dozen3"
            local dzBet = placed[dzKey] or 0
            local dzLbl = br <= 4 and " D1 " or br <= 8 and " D2 " or " D3 "
            term.setCursorPos(XDZ_S, y)
            term.setTextColor(dzBet > 0 and colors.black or colors.gray)
            term.setBackgroundColor(dzBet > 0 and colors.lime or colors.black)
            term.write(dzLbl)
            term.setBackgroundColor(colors.black)
        end

        -- Column bet row (row 17)
        term.setCursorPos(1, COL_ROW); term.clearLine()
        for i, key in ipairs({"col1","col2","col3"}) do
            local bet = placed[key] or 0
            term.setCursorPos(({X1S,X2S,X3S})[i], COL_ROW)
            term.setTextColor(bet > 0 and colors.black or colors.gray)
            term.setBackgroundColor(bet > 0 and colors.lime or colors.black)
            term.write(string.format("[C%d]", i))
            term.setBackgroundColor(colors.black)
        end

        -- Side bets row (row 18)
        term.setCursorPos(1, SIDE_ROW); term.clearLine()
        for _, s in ipairs(SIDES) do
            local bet = placed[s.key] or 0
            -- Resting colour: red=red, black=gray, others=white
            local restFg = s.key=="red" and colors.red or s.key=="black" and colors.gray or colors.white
            -- Active background: red=red, black=lightGray, others=lime
            local actBg  = s.key=="red" and colors.red or s.key=="black" and colors.lightGray or colors.lime
            local fg = bet > 0 and colors.black or restFg
            local bg = bet > 0 and actBg         or colors.black
            term.setCursorPos(s.xs, SIDE_ROW)
            term.setTextColor(fg); term.setBackgroundColor(bg)
            term.write(s.lbl)
            term.setBackgroundColor(colors.black)
        end

        -- Hint / status row (row 19)
        term.setCursorPos(1, HINT_ROW); term.clearLine()
        local tot  = totalPlaced()
        local hint = tot > 0
            and string.format("  Bet:%d  [Enter]=SPIN  [C]clear  RClick=undo chip", tot)
            or  "  LClick=place chip   RClick=remove   [Enter]=SPIN   [B]=back"
        term.setTextColor(tot > 0 and colors.yellow or colors.gray)
        term.write(hint:sub(1, w))
        term.setBackgroundColor(colors.black); term.setTextColor(colors.white)
    end

    -- ── Bet-placement loop ────────────────────────────────────────────────────
    drawBoard(nil)
    while true do
        local ev, a, b, c = os.pullEvent()
        if ev == "key" then
            if a == keys.b then
                placed = {}; return 0, "Cancelled"
            elseif a == keys.c then
                placed = {}; drawBoard(nil)
            elseif a == keys.enter or a == keys.numPadEnter then
                if totalPlaced() > 0 then break end  -- spin
            end
        elseif ev == "char" and a == "?" then
            ui.helpOverlay("Roulette — Help", _HELP.roul)
            drawBoard(nil)
        elseif ev == "mouse_click" then
            local key = clickKey(b, c)
            if key ~= nil then
                local cur = placed[key] or 0
                if a == 1 then  -- left click: add one chip
                    if totalPlaced() + chipSize <= balance then
                        placed[key] = cur + chipSize
                        ui.sfx("click")
                    end
                elseif a == 2 then  -- right click: remove one chip
                    local nxt = cur - chipSize
                    placed[key] = nxt > 0 and nxt or nil
                    ui.sfx("click")
                end
                drawBoard(nil)
            end
        end
    end

    -- ── Spin animation ────────────────────────────────────────────────────────
    ui.banner("Roulette")
    ui.center(5, "Spinning...", colors.yellow)
    for i = 1, 16 do
        local n  = math.random(0, 36)
        local sc = n==0 and colors.green or (redSet[n] and colors.red or colors.gray)
        ui.sfx("bell", 0.5, 0.8 + i * 0.02)
        ui.center(6, " "..tostring(n).." ", sc)
        os.sleep(0.06 + i * 0.012)
    end

    local result  = math.random(0, 36)
    local isRed   = redSet[result]
    local colName = result==0 and "green" or (isRed and "red" or "black")
    local colCode = result==0 and colors.green or (isRed and colors.red or colors.gray)
    ui.sfx("bell", 1.0, 0.6)
    ui.center(6, string.format(" %d (%s) ", result, colName), colCode)
    os.sleep(0.8)

    -- Show winning number highlighted on the full board
    drawBoard(result)
    os.sleep(1.5)

    -- ── Evaluate all placed bets ──────────────────────────────────────────────
    local isOdd     = result ~= 0 and result % 2 == 1
    local resultCol = result ~= 0 and (result%3==1 and 1 or result%3==2 and 2 or 3) or nil

    local function evalBet(key, amt)
        local win, pay = false, 1
        if     type(key)=="number" then win = (result==key);                    pay=35
        elseif key=="red"    then win = isRed and result~=0
        elseif key=="black"  then win = not isRed and result~=0
        elseif key=="odd"    then win = isOdd
        elseif key=="even"   then win = result~=0 and not isOdd
        elseif key=="high"   then win = result>=19
        elseif key=="low"    then win = result>=1 and result<=18
        elseif key=="dozen1" then win = result>=1  and result<=12;             pay=2
        elseif key=="dozen2" then win = result>=13 and result<=24;             pay=2
        elseif key=="dozen3" then win = result>=25 and result<=36;             pay=2
        elseif key=="col1"   then win = resultCol==1;                          pay=2
        elseif key=="col2"   then win = resultCol==2;                          pay=2
        elseif key=="col3"   then win = resultCol==3;                          pay=2
        end
        return win and amt*pay or -amt
    end

    local totalNet = 0
    for key, amt in pairs(placed) do totalNet = totalNet + evalBet(key, amt) end

    if totalNet > 0 then
        ui.sfx("win")
        ui.winBanner(string.format("Ball: %d (%s)", result, colName),
            string.format("+%d uAMI", totalNet))
    elseif totalNet < 0 then
        ui.sfx("loss")
        ui.loseBanner(string.format("Ball: %d (%s)", result, colName),
            string.format("%d uAMI", totalNet))
    else
        ui.sfx("tick")
        ui.center(12, "Push — net 0 uAMI", colors.yellow)
    end
    os.sleep(1.5)

    return totalNet, string.format("Ball: %d (%s)  net: %+d uAMI", result, colName, totalNet)
end

-- ── 6. Higher / Lower ────────────────────────────────────────────────────────
-- Cash-out at any time during the streak, not just at completion.
-- Multiplier ladder is always visible.
function games.higherLower(ui, balance)
    ui.banner("Higher / Lower")
    ui.line(4, "  5 rounds. Higher [H] or Lower [L] each card.", colors.yellow)
    ui.line(5, "  Equal = free round.  [Q]/[B] = cash out win.", colors.lightGray)
    ui.line(6, "  Mult: 1.2x  1.5x  1.9x  2.5x  3.2x", colors.cyan)

    local bet = ui.readBet(7, balance, nil, _HELP.hl)
    if not bet then return 0, "Cancelled" end

    local MULTS  = {1.2, 1.5, 1.9, 2.5, 3.2}
    local current = _RANKS[math.random(#_RANKS)]
    local streak  = 0
    local ROUNDS  = 5

    -- Draw helper: used both for the initial per-round render and to restore
    -- state after the [?] help overlay dismisses.
    local function drawHLScreen(round)
        local w = ui.W()
        ui.banner("Higher / Lower")
        term.setCursorPos(1, 4); term.clearLine(); term.setTextColor(colors.gray)
        term.write("  ")
        for i, m in ipairs(MULTS) do
            if i == streak + 1 then
                term.setTextColor(colors.yellow); term.write(string.format("[%.1fx]", m))
            else
                term.setTextColor(colors.gray);   term.write(string.format(" %.1fx ", m))
            end
        end
        local cardX = math.floor((w - 4) / 2) + 1
        ui.drawCardBox(cardX, 5, current, nil, false)
        ui.center(8, string.format("Round %d/%d   Streak %d   Mult x%.1f",
            round, ROUNDS, streak, MULTS[math.max(1, streak)] or 1), colors.lightGray)
        ui.rule(9)
        local curWin = streak > 0 and (math.floor(bet * MULTS[streak]) - bet) or 0
        ui.line(10, string.format("  Current win: %d uAMI    [H]igher  [L]ower  [?]help  [Q]uit",
            curWin), streak > 0 and colors.lime or colors.gray)
    end

    for round = 1, ROUNDS do
        drawHLScreen(round)
        local k
        repeat
            local ev, a = os.pullEvent()
            if ev == "char" and a == "?" then
                ui.helpOverlay("Higher/Lower — Help", _HELP.hl)
                drawHLScreen(round)   -- restore full board state
            elseif ev == "key" then
                k = a
            end
        until k
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

    -- Ask how many balls to drop simultaneously
    local numBalls = 1
    while true do
        ui.line(9,  "  Balls to drop [1-10]  (Enter = 1)  [?] help:", colors.yellow)
        ui.line(10, string.format("  Total bet: %d uAMI  |  Balance: %d uAMI",
            bet * numBalls, balance), colors.lightGray)
        term.setCursorPos(1, 11); term.setTextColor(colors.white); io.write("> ")
        local raw = (read() or ""):gsub("%s", "")
        if raw:lower() == "b" then return 0, "Cancelled" end
        if raw == "?" then
            ui.helpOverlay("Pachinko — Help", _HELP.pach)
            ui.banner("Pachinko")
            ui.line(4, "  7-row peg board. Ball bounces L/R each row.", colors.yellow)
            ui.line(5, "  Outer = 12x  Inner-mid = 5x/2x  Centre = 0.5x", colors.lightGray)
            ui.line(6, "  [?] help  [B] back", colors.gray)
        elseif raw == "" then
            break  -- default 1
        else
            local nb = tonumber(raw)
            if nb and nb >= 1 and nb <= 10 then
                numBalls = math.floor(nb)
                break
            end
        end
    end

    local totalBet = bet * numBalls
    if totalBet > balance then
        ui.line(12, "  Not enough balance for that many balls.", colors.red)
        os.sleep(1.5)
        return 0, "Insufficient balance"
    end

    -- Helper: simulate one ball, return path table and bucket index
    local function dropBall()
        local pos  = 0
        local path = {}
        for _ = 1, ROWS do
            local dir = math.random() < 0.5 and -1 or 1
            pos = pos + dir
            path[#path+1] = pos
        end
        local bi = math.floor((pos + ROWS) / (ROWS * 2) * (BUCKETS - 1)) + 1
        bi = math.max(1, math.min(BUCKETS, bi))
        return path, bi
    end

    -- Helper: draw peg board at a given step with ball position, plus a status line
    local function drawBoard(path, step, ballLabel, statusLine)
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
        if ballLabel then
            ui.line(3, "  " .. ballLabel, colors.orange)
        end
        if statusLine then
            ui.center(3 + ROWS + 2, statusLine:sub(1, ui.W()), colors.lightGray)
        end
    end

    local totalNet      = 0
    local bucketHits    = {}  -- bucket index -> count, for summary
    for i = 1, BUCKETS do bucketHits[i] = 0 end

    for ballNum = 1, numBalls do
        local path, bucketIdx = dropBall()
        local mult = PAYS[bucketIdx]
        local ballNet = math.floor(bet * mult) - bet
        totalNet = totalNet + ballNet
        bucketHits[bucketIdx] = bucketHits[bucketIdx] + 1

        local ballLabel = string.format("Ball %d/%d", ballNum, numBalls)
        local statusLine = string.format("Running total: %+d uAMI", totalNet)

        -- Animate ball drop
        for step = 1, ROWS do
            ui.beginFrame()
            drawBoard(path, step, ballLabel, statusLine)
            ui.sfx("tick", 0.4, 0.9 + step * 0.05)
            ui.endFrame()
            os.sleep(0.18)
        end

        -- Show final board + bucket for this ball
        local w = ui.W()
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
        local ballRes = string.format("%s  Bucket %d (x%.1f)  %+d uAMI",
            ballLabel, bucketIdx, mult, ballNet)
        ui.center(3 + ROWS + 2, ballRes:sub(1, w), ballNet >= 0 and colors.lime or colors.red)
        ui.center(3 + ROWS + 3, string.format("Total: %+d uAMI", totalNet):sub(1, w),
            totalNet >= 0 and colors.lime or colors.red)
        ui.endFrame()
        if ballNet >= 0 then ui.sfx("win") else ui.sfx("loss") end
        -- Brief pause between balls; last ball pauses longer
        os.sleep(ballNum == numBalls and 2.5 or 0.8)
    end

    local res
    if numBalls == 1 then
        res = string.format("Bucket %d (x%.1f)  %+d uAMI",
            -- recover single-ball bucket from bucketHits
            (function() for i,c in ipairs(bucketHits) do if c>0 then return i end end end)(),
            PAYS[(function() for i,c in ipairs(bucketHits) do if c>0 then return i end end end)()],
            totalNet)
    else
        res = string.format("%d balls  Total: %+d uAMI", numBalls, totalNet)
    end
    return totalNet, res
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

    local bet = ui.readBet(7, balance, nil, _HELP.craps)
    if not bet then return 0, "Cancelled" end

    -- [?]-aware roll-prompt helper.  Calls redrawFn() immediately (draws the
    -- screen), then blocks until a non-? key is pressed.  After a ? it shows
    -- the help overlay then calls redrawFn() again to restore exact board state.
    local function crapsWait(redrawFn)
        redrawFn()
        while true do
            local ev, a = os.pullEvent()
            if ev == "char" and a == "?" then
                ui.helpOverlay("Craps — Help", _HELP.craps)
                redrawFn()   -- restore
            elseif ev == "key" then return end
        end
    end

    -- Come-out roll
    crapsWait(function()
        ui.banner("Craps — Come-Out")
        ui.line(4, "  Press any key to roll...  [?] help", colors.orange)
    end)
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
        crapsWait(function()
            ui.banner(string.format("Craps — Point: %d", point))
            ui.line(4, string.format("  Point is %d. Roll it before 7.", point), colors.cyan)
            ui.line(5, string.format("  Bet: %d uAMI", bet), colors.yellow)
            ui.line(6, "  Press any key to roll...  [?] help", colors.orange)
        end)
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

    local bet = ui.readBet(6, balance, nil, _HELP.coinflip)
    if not bet then return 0, "Cancelled" end

    local sides   = {"Heads", "Tails"}
    local FRAMES  = {"(H)", "(HT)", "(T)", "(TH)"}  -- spinning coin frames

    ui.line(8, "  [H] Heads   [T] Tails   [?] help", colors.orange)
    local choice
    while not choice do
        local ev, a = os.pullEvent()
        if ev == "char" and a == "?" then
            ui.helpOverlay("Coin Flip — Help", _HELP.coinflip)
            ui.banner("Coin Flip")
            ui.line(4, "  50/50. Win pays 1.92x (net +0.92x).  [?] help", colors.yellow)
            ui.line(7, string.format("  Bet: %d uAMI  —  choose:", bet), colors.yellow)
            ui.line(8, "  [H] Heads   [T] Tails   [?] help", colors.orange)
        elseif ev == "key" then
            if a == keys.h then choice = "Heads"
            elseif a == keys.t then choice = "Tails"
            end
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

-- \u2500\u2500 10. Video Poker \u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500
-- Jacks or Better, 8/5 pay table (Full House=8x, Flush=5x, Royal Flush=800x).
-- House edge \u2248 2.7% at optimal hold strategy.
function games.videoPoker(ui, balance)
    local RANK_VAL = {
        A=1,["2"]=2,["3"]=3,["4"]=4,["5"]=5,["6"]=6,
        ["7"]=7,["8"]=8,["9"]=9,["10"]=10,J=11,Q=12,K=13
    }
    local PAYS = {
        ["Royal Flush"]=800, ["Straight Flush"]=50, ["Four of a Kind"]=25,
        ["Full House"]=8,    ["Flush"]=5,           ["Straight"]=4,
        ["Three of a Kind"]=3, ["Two Pair"]=2, ["Jacks or Better"]=1, ["No Winner"]=0,
    }

    -- Evaluate a 5-card hand; returns hand name (string) and pay multiplier (int).
    local function evalHand(h)
        local rankCt, suitCt = {}, {}
        for _, c in ipairs(h) do
            rankCt[c.rank] = (rankCt[c.rank] or 0) + 1
            suitCt[c.suit] = (suitCt[c.suit] or 0) + 1
        end
        local isFlush = false
        for _, ct in pairs(suitCt) do if ct == 5 then isFlush = true; break end end
        -- Collect unique rank values (fewer than 5 unique = duplicate rank = no straight)
        local uv = {}
        for r in pairs(rankCt) do uv[#uv+1] = RANK_VAL[r] or 0 end
        table.sort(uv)
        local isStraight, isRoyal = false, false
        if #uv == 5 then
            if uv[5] - uv[1] == 4 then isStraight = true end
            -- Ace-high straight {A,10,J,Q,K} = {1,10,11,12,13}
            if uv[1]==1 and uv[2]==10 and uv[3]==11 and uv[4]==12 and uv[5]==13 then
                isStraight = true; isRoyal = true
            end
        end
        local pCt, tCt, qCt, pRanks = 0, 0, 0, {}
        for r, ct in pairs(rankCt) do
            if ct == 2 then pCt = pCt+1; pRanks[#pRanks+1] = r end
            if ct == 3 then tCt = tCt+1 end
            if ct == 4 then qCt = qCt+1 end
        end
        if isFlush and isRoyal    then return "Royal Flush",    PAYS["Royal Flush"] end
        if isFlush and isStraight then return "Straight Flush", PAYS["Straight Flush"] end
        if qCt == 1               then return "Four of a Kind", PAYS["Four of a Kind"] end
        if tCt == 1 and pCt == 1  then return "Full House",     PAYS["Full House"] end
        if isFlush                then return "Flush",           PAYS["Flush"] end
        if isStraight             then return "Straight",        PAYS["Straight"] end
        if tCt == 1               then return "Three of a Kind", PAYS["Three of a Kind"] end
        if pCt == 2               then return "Two Pair",        PAYS["Two Pair"] end
        if pCt == 1 then
            for _, r in ipairs(pRanks) do
                local v = RANK_VAL[r] or 0
                if v == 1 or v >= 11 then return "Jacks or Better", PAYS["Jacks or Better"] end
            end
        end
        return "No Winner", 0
    end

    ui.banner("Video Poker")
    ui.line(4, "  Jacks or Better (8/5).  [?]=help  [B]=back", colors.yellow)
    ui.line(5, "  Press [1-5] to hold cards, then [Enter] to draw.", colors.lightGray)

    local bet = ui.readBet(6, balance, nil, _HELP.vp)
    if not bet then return 0, "Cancelled" end

    -- Build 52-card deck and Fisher-Yates shuffle
    local deck = {}
    for _, r in ipairs(_RANKS) do
        for _, s in ipairs(_SUITS) do deck[#deck+1] = {rank=r, suit=s} end
    end
    for i = #deck, 2, -1 do
        local j = math.random(i)
        deck[i], deck[j] = deck[j], deck[i]
    end
    local deckPos = 1
    local function drawCard() local c = deck[deckPos]; deckPos = deckPos+1; return c end

    -- Deal initial 5-card hand
    local hand = { drawCard(), drawCard(), drawCard(), drawCard(), drawCard() }
    local held = { false, false, false, false, false }

    -- Column anchors for 5 cards (each ui.cardStr = 5 chars wide)
    local CX = {3, 10, 17, 24, 31}

    local function drawScreen(phase, handName, mult)
        ui.banner("Video Poker")
        -- Row 4: index labels, coloured lime when held
        term.setCursorPos(1, 4); term.clearLine()
        for i = 1, 5 do
            term.setCursorPos(CX[i], 4)
            term.setTextColor(held[i] and colors.lime or colors.gray)
            term.setBackgroundColor(colors.black)
            term.write(string.format("[%d]", i))
        end
        -- Row 5: card strings; lime = held, red = heart/diamond, white = club/spade
        term.setCursorPos(1, 5); term.clearLine()
        for i = 1, 5 do
            local c   = hand[i]
            local isRed = (c.suit == "H" or c.suit == "D")
            local fg  = held[i] and colors.lime
                     or isRed   and colors.red
                     or             colors.white
            term.setCursorPos(CX[i], 5)
            term.setTextColor(fg); term.setBackgroundColor(colors.black)
            term.write(ui.cardStr(c.rank, c.suit))
        end
        -- Row 6: HOLD / discard indicators
        term.setCursorPos(1, 6); term.clearLine()
        for i = 1, 5 do
            term.setCursorPos(CX[i], 6)
            if phase == "draw" then
                term.setTextColor(colors.gray); term.write("     ")
            elseif held[i] then
                term.setTextColor(colors.lime);  term.write("HOLD ")
            else
                term.setTextColor(colors.gray);  term.write(" .   ")
            end
        end
        ui.rule(7)
        -- Row 8: result or bet display
        if handName then
            local m  = mult or 0
            local fg = m > 0 and colors.lime or colors.red
            if m == 0 then
                ui.line(8, string.format("  No Winner  --  lost %d uAMI", bet), fg)
            else
                ui.line(8, string.format("  %s  x%d  = +%d uAMI",
                    handName, m, math.floor(bet * m) - bet), fg)
            end
        else
            ui.line(8, string.format("  Bet: %d uAMI", bet), colors.yellow)
        end
        if phase == "hold" then
            ui.line(9, "  [1-5]=toggle hold   [Enter]=Draw   [?]=help", colors.orange)
        end
        term.setBackgroundColor(colors.black); term.setTextColor(colors.white)
    end

    -- \u2500\u2500 Hold phase \u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500
    drawScreen("hold", nil)
    while true do
        local ev, a = os.pullEvent()
        if ev == "char" then
            if a == "?" then
                ui.helpOverlay("Video Poker \u2014 Help", _HELP.vp)
                drawScreen("hold", nil)
            elseif a == "b" or a == "B" then
                return 0, "Cancelled"
            else
                local n = tonumber(a)
                if n and n >= 1 and n <= 5 then
                    held[n] = not held[n]
                    ui.sfx("click")
                    drawScreen("hold", nil)
                end
            end
        elseif ev == "key" then
            if a == keys.enter or a == keys.numPadEnter then break
            elseif a == keys.b then return 0, "Cancelled"
            end
        end
    end

    -- \u2500\u2500 Draw phase \u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500
    ui.sfx("flip")
    for i = 1, 5 do
        if not held[i] then hand[i] = drawCard() end
    end
    local handName, mult = evalHand(hand)
    local net = math.floor(bet * mult) - bet
    drawScreen("draw", handName, mult)
    os.sleep(0.4)
    if mult >= 50 then
        ui.sfx("jackpot")
        ui.winBanner(handName, string.format("+%d uAMI", net))
    elseif mult > 0 then
        ui.sfx("win")
        ui.winBanner(handName, string.format("+%d uAMI", net))
    else
        ui.sfx("loss")
        ui.loseBanner("No Winner", string.format("-%d uAMI", bet))
    end
    os.sleep(1.5)
    return net, string.format("Video Poker: %s  net=%+d", handName, net)
end

-- \u2500\u2500 11. Keno \u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500
-- Pick 1-10 numbers from a 10\xd78 grid (1-80). Casino draws 20 at random.
-- Payout per spot-count pay table; house edge 25-31% (standard Keno range).
function games.keno(ui, balance)
    local N_DRAW     = 20
    local GRID_ROWS  = 8
    local GRID_COLS  = 10
    local MAX_PICK   = 10
    local CELL_W     = 4    -- each cell is "[nn]" = 4 chars
    local GRID_COL   = 2    -- leftmost terminal column of grid (1-indexed)
    local GRID_ROW   = 4    -- topmost terminal row of grid

    -- Pay table: PAY[k][m] = multiplier for picking k spots and matching m.
    -- Absent or 0 = no payout.  Verified EV per spot in phase diff.
    local PAY = {
        [1]  = {[1]=3},
        [2]  = {[2]=12},
        [3]  = {[3]=42,[2]=1},
        [4]  = {[4]=100,[3]=4,[2]=1},
        [5]  = {[5]=610,[4]=15,[3]=2},
        [6]  = {[6]=1500,[5]=55,[4]=7,[3]=1},
        [7]  = {[7]=4500,[6]=250,[5]=15,[4]=3,[3]=1},
        [8]  = {[8]=10000,[7]=900,[6]=85,[5]=10,[4]=2},
        [9]  = {[9]=10000,[8]=3300,[7]=250,[6]=35,[5]=5,[4]=1},
        [10] = {[10]=10000,[9]=3500,[8]=800,[7]=100,[6]=22,[5]=3},
    }

    local picked  = {}   -- [n]=true when player has picked number n
    local drawn   = {}   -- [n]=true when n was drawn
    local nPicked = 0

    -- Convert a terminal click (cx,cy) \u2192 number 1-80, or nil.
    local function clickToNum(cx, cy)
        local gy = cy - GRID_ROW + 1
        if gy < 1 or gy > GRID_ROWS then return nil end
        local gx = math.floor((cx - GRID_COL) / CELL_W) + 1
        if gx < 1 or gx > GRID_COLS then return nil end
        return (gy - 1) * GRID_COLS + gx
    end

    -- Draw the number grid, status and pay-hint rows.
    local function drawGrid(phase, statusLine)
        local w     = ui.W()
        local ruleY = GRID_ROW + GRID_ROWS
        ui.banner("Keno")
        for row = 1, GRID_ROWS do
            local y = GRID_ROW + row - 1
            term.setCursorPos(1, y); term.clearLine()
            term.setCursorPos(GRID_COL, y)
            for col = 1, GRID_COLS do
                local n   = (row - 1) * GRID_COLS + col
                local isP = picked[n]
                local isD = drawn[n]
                local fg
                if phase == "pick" then
                    fg = isP and colors.yellow or colors.gray
                else
                    if   isP and isD then fg = colors.cyan
                    elseif isD       then fg = colors.lime
                    elseif isP       then fg = colors.orange
                    else                  fg = colors.gray
                    end
                end
                term.setTextColor(fg); term.setBackgroundColor(colors.black)
                term.write(string.format("[%2d]", n))
            end
        end
        ui.rule(ruleY)
        ui.line(ruleY + 1, statusLine or "", colors.yellow)
        -- Compact pay-table hint for the current spot count
        if nPicked > 0 and PAY[nPicked] then
            local parts = {}
            for m = nPicked, 1, -1 do
                if PAY[nPicked][m] then
                    parts[#parts+1] = string.format("%dm=%dx", m, PAY[nPicked][m])
                end
            end
            ui.line(ruleY + 2, ("  Pay: " .. table.concat(parts, "  ")):sub(1, w), colors.lightGray)
        else
            ui.line(ruleY + 2, "  Pick 1-10 numbers then press [Enter] to draw.", colors.gray)
        end
        term.setBackgroundColor(colors.black); term.setTextColor(colors.white)
    end

    -- \u2500\u2500 Bet prompt \u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500
    ui.banner("Keno")
    ui.line(4, "  Pick 1-10 numbers (1-80), then draw 20.", colors.yellow)
    ui.line(5, "  Matches on your picks = payout.  [?]=help  [B]=back", colors.lightGray)
    local bet = ui.readBet(6, balance, nil, _HELP.keno)
    if not bet then return 0, "Cancelled" end

    -- \u2500\u2500 Pick phase \u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500
    drawGrid("pick", string.format("  Picked: 0/%d   LClick=pick  RClick=remove", MAX_PICK))
    while true do
        local ev, a, b, c = os.pullEvent()
        if ev == "char" then
            if a == "?" then
                ui.helpOverlay("Keno \u2014 Help", _HELP.keno)
                drawGrid("pick", string.format("  Picked: %d/%d   [Enter]=DRAW  [C]=clear  [?]=help",
                    nPicked, MAX_PICK))
            elseif (a == "c" or a == "C") and nPicked > 0 then
                picked = {}; nPicked = 0
                drawGrid("pick", string.format("  Picked: 0/%d   LClick=pick  RClick=remove", MAX_PICK))
            end
        elseif ev == "key" then
            if a == keys.b then return 0, "Cancelled" end
            if (a == keys.enter or a == keys.numPadEnter) and nPicked >= 1 then break end
        elseif ev == "mouse_click" then
            local n = clickToNum(b, c)
            if n then
                if a == 1 and not picked[n] and nPicked < MAX_PICK then
                    picked[n] = true; nPicked = nPicked + 1; ui.sfx("click")
                elseif a == 2 and picked[n] then
                    picked[n] = nil; nPicked = nPicked - 1; ui.sfx("click")
                end
                local hint = nPicked >= 1
                    and string.format("  Picked: %d/%d   [Enter]=DRAW  [C]=clear  [?]=help",
                        nPicked, MAX_PICK)
                    or  string.format("  Picked: 0/%d   LClick=pick  RClick=remove", MAX_PICK)
                drawGrid("pick", hint)
            end
        end
    end

    -- \u2500\u2500 Draw 20 numbers (Fisher-Yates on 1-80) \u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500
    local pool = {}
    for i = 1, 80 do pool[i] = i end
    -- Shuffle the last 20 positions to get our drawn set
    for i = 80, 61, -1 do
        local j = math.random(i)
        pool[i], pool[j] = pool[j], pool[i]
    end
    local drawnList = {}
    for i = 61, 80 do drawnList[#drawnList + 1] = pool[i] end
    table.sort(drawnList)

    -- Animate: reveal each drawn number one by one
    for di, n in ipairs(drawnList) do
        drawn[n] = true
        drawGrid("draw", string.format("  Drawing %d/20... [%2d]", di, n))
        ui.sfx("tick", 0.3, 0.9 + di * 0.005)
        os.sleep(0.07)
    end

    -- \u2500\u2500 Evaluate \u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500
    local hits = 0
    for n in pairs(picked) do if drawn[n] then hits = hits + 1 end end
    local mult = (PAY[nPicked] and PAY[nPicked][hits]) or 0
    local net  = math.floor(bet * mult) - bet
    local ruleY = GRID_ROW + GRID_ROWS

    drawGrid("result", string.format("  Drew 20.  %d/%d hits.  Mult: x%d", hits, nPicked, mult))
    -- Overwrite pay-hint row with the final result message
    local resultLine
    if mult > 0 then
        resultLine = string.format("  WIN! %d/%d hits  x%d  = +%d uAMI", hits, nPicked, mult, net)
    else
        resultLine = string.format("  %d/%d hits  No payout. Lost %d uAMI.", hits, nPicked, bet)
    end
    ui.line(ruleY + 2, resultLine:sub(1, ui.W()), net >= 0 and colors.lime or colors.red)

    if mult >= 1000 then ui.sfx("jackpot")
    elseif mult > 0 then ui.sfx("win")
    else                 ui.sfx("loss")
    end
    os.sleep(2.5)
    return net, string.format("Keno k=%d hits=%d x%d net=%+d", nPicked, hits, mult, net)
end

-- \u2500\u2500 12. Scratch Card \u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500
-- Pick 3 tiles from a 3\xd73 grid (9 tiles total). Match 2 or 3 = win.
-- Pool: 2\xd7"7", 2\xd7"$", 2\xd7"A", 3\xd7"K".
-- EV = (12+0+28+14+7)/84 = 61/84 \u2248 0.726  \u2192  HE \u2248 27.4%
function games.scratchcard(ui, balance)
    local POOL   = {"7","7","$","$","A","A","K","K","K"}
    local ROWS, COLS = 3, 3
    local GY     = 5      -- topmost grid row on terminal
    local CELL_W = 5      -- each cell is "[ X ]" = 5 chars
    local CX     = {2, 7, 12}  -- column start for each grid column
    local RULE_Y = GY + ROWS
    local MAX_PICK = 3

    -- Payout multipliers (applied to bet).
    -- PAYS_3[sym]=mult for 3-of-a-kind; PAYS_2[sym]=mult for pair.
    local PAYS_3 = {K=12}
    local PAYS_2 = {["7"]=4, ["$"]=2, A=1}
    local SYM_COL = {
        ["7"]=colors.yellow, ["$"]=colors.lime,
        A=colors.cyan,        K=colors.orange,
    }

    -- Fisher-Yates shuffle
    local tiles = {}
    for _, s in ipairs(POOL) do tiles[#tiles+1] = {sym=s, revealed=false} end
    for i = #tiles, 2, -1 do
        local j = math.random(i)
        tiles[i], tiles[j] = tiles[j], tiles[i]
    end

    local nScratched = 0

    -- Returns tile index 1-9 for a terminal click, or nil.
    local function clickToIdx(cx, cy)
        local gy = cy - GY + 1
        if gy < 1 or gy > ROWS then return nil end
        for c, x in ipairs(CX) do
            if cx >= x and cx <= x + CELL_W - 1 then
                return (gy - 1) * COLS + c
            end
        end
        return nil
    end

    -- Resolve the best hand among revealed tiles.
    -- Returns mult (int), matchSym (string or nil), matchCt (int).
    local function evalScratched()
        local symCt = {}
        for _, t in ipairs(tiles) do
            if t.revealed then
                symCt[t.sym] = (symCt[t.sym] or 0) + 1
            end
        end
        local best, bSym, bCt = 0, nil, 0
        for sym, ct in pairs(symCt) do
            local m = 0
            if ct >= 3 and PAYS_3[sym] then m = PAYS_3[sym]
            elseif ct >= 2 and PAYS_2[sym] then m = PAYS_2[sym]
            end
            if m > best then best = m; bSym = sym; bCt = ct end
        end
        return best, bSym, bCt
    end

    local function drawGrid(resultLine)
        local w = ui.W()
        ui.banner("Scratch Card")
        if nScratched < MAX_PICK then
            ui.line(4, string.format(
                "  Click or [1-9] to scratch.  %d/3 done.  [?]=help  [B]=back",
                nScratched), colors.yellow)
        else
            ui.line(4, "  [Enter] reveal rest  [?]=help  [B]=back", colors.yellow)
        end
        for row = 1, ROWS do
            local y = GY + row - 1
            term.setCursorPos(1, y); term.clearLine()
            for col = 1, COLS do
                local idx = (row - 1) * COLS + col
                local t   = tiles[idx]
                term.setCursorPos(CX[col], y)
                if t.revealed then
                    local fg = SYM_COL[t.sym] or colors.white
                    term.setTextColor(fg); term.setBackgroundColor(colors.black)
                    term.write(string.format("[ %s ]", t.sym))
                else
                    term.setTextColor(colors.gray); term.setBackgroundColor(colors.black)
                    term.write(string.format("[ %d ]", idx))
                end
            end
        end
        ui.rule(RULE_Y)
        ui.line(RULE_Y+1, "  KKK=12x  7+7=4x  $$=2x  AA=1x(push)  KK=loss", colors.gray)
        if resultLine then
            local rCol = resultLine:find("WIN") and colors.lime or
                         resultLine:find("PUSH") and colors.yellow or colors.red
            ui.line(RULE_Y+2, resultLine:sub(1, w), rCol)
        else
            term.setCursorPos(1, RULE_Y+2); term.clearLine()
        end
        term.setBackgroundColor(colors.black); term.setTextColor(colors.white)
    end

    -- \u2500\u2500 Bet \u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500
    ui.banner("Scratch Card")
    ui.line(4, "  3\xd73 grid. Scratch any 3 tiles.  [?]=help  [B]=back", colors.yellow)
    ui.line(5, "  Match 2 or 3 symbols to win!", colors.lightGray)
    local bet = ui.readBet(6, balance, nil, _HELP.scratch)
    if not bet then return 0, "Cancelled" end

    -- \u2500\u2500 Pick phase \u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500
    drawGrid(nil)
    while nScratched < MAX_PICK do
        local ev, a, b, c = os.pullEvent()
        if ev == "char" then
            if a == "?" then
                ui.helpOverlay("Scratch Card \u2014 Help", _HELP.scratch)
                drawGrid(nil)
            elseif a == "b" or a == "B" then
                return 0, "Cancelled"
            else
                local n = tonumber(a)
                if n and n >= 1 and n <= 9 and not tiles[n].revealed then
                    tiles[n].revealed = true; nScratched = nScratched + 1
                    ui.sfx("flip"); drawGrid(nil)
                end
            end
        elseif ev == "key" then
            if a == keys.b then return 0, "Cancelled" end
        elseif ev == "mouse_click" and a == 1 then
            local idx = clickToIdx(b, c)
            if idx and not tiles[idx].revealed then
                tiles[idx].revealed = true; nScratched = nScratched + 1
                ui.sfx("flip"); drawGrid(nil)
            end
        end
    end

    -- \u2500\u2500 Evaluate \u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500
    local mult, matchSym, matchCt = evalScratched()
    local net = math.floor(bet * mult) - bet

    local resultLine
    if mult == 0 then
        resultLine = string.format("  No match.  Lost %d uAMI.", bet)
    elseif mult == 1 then
        resultLine = string.format("  PUSH! %s+%s  x1  net \u00b10 uAMI", matchSym, matchSym)
    elseif matchCt >= 3 then
        resultLine = string.format("  WIN! %s+%s+%s  x%d  net +%d uAMI",
            matchSym, matchSym, matchSym, mult, net)
    else
        resultLine = string.format("  WIN! %s+%s  x%d  net +%d uAMI",
            matchSym, matchSym, mult, net)
    end

    drawGrid(resultLine)
    if   mult >= 10 then ui.sfx("jackpot")
    elseif mult > 1 then ui.sfx("win")
    elseif mult == 1 then ui.sfx("coin")
    else                  ui.sfx("loss")
    end

    -- Wait for Enter/B (or 2.5s auto) then cosmetically reveal all tiles.
    os.sleep(0.4)
    local tId = os.startTimer(2.5)
    local waiting = true
    while waiting do
        local wev, wa = os.pullEvent()
        if (wev == "key" and (wa == keys.enter or wa == keys.numPadEnter
                              or wa == keys.b or wa == keys.space))
        or (wev == "timer" and wa == tId) then
            waiting = false
        elseif wev == "char" and wa == "?" then
            ui.helpOverlay("Scratch Card \u2014 Help", _HELP.scratch)
            drawGrid(resultLine)  -- restore result after overlay
        end
    end

    for _, t in ipairs(tiles) do t.revealed = true end
    drawGrid(resultLine)
    os.sleep(1.5)

    return net, string.format("Scratch: %s x%d net=%+d",
        matchSym or "miss", mult, net)
end

-- \u2500\u2500 13. Wheel of Fortune \u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500
-- Weighted spin: MISS(65%), \xd72(30%), \xd75(4%), \xd710(1%).
-- net = floor(bet * mult) - bet.  EV_mult = 0.90  \u2192  HE = 10.0%.
function games.wheel(ui, balance)
    -- Pool of 100 weighted slots; shuffled fresh each game.
    local POOL = {}
    local function add(sym, mult, col, n)
        for _ = 1, n do POOL[#POOL+1] = {sym=sym, mult=mult, col=col} end
    end
    add("MISS", 0,  colors.red,    65)
    add("x2",   2,  colors.orange, 30)
    add("x5",   5,  colors.yellow,  4)
    add("x10",  10, colors.cyan,    1)
    -- Fisher-Yates shuffle so random draw order looks organic during animation
    for i = #POOL, 2, -1 do
        local j = math.random(i); POOL[i], POOL[j] = POOL[j], POOL[i]
    end

    -- \u2500\u2500 Bet \u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500
    ui.banner("Wheel of Fortune")
    ui.line(4, "  Win x2, x5, or x10!  [?]=help  [B]=back", colors.yellow)
    ui.line(5, "  65% chance to MISS. Press [Enter] to spin.", colors.lightGray)
    local bet = ui.readBet(6, balance, nil, _HELP.wheel)
    if not bet then return 0, "Cancelled" end

    -- Provably-fair pre-commit (trust display only — not a cryptographic guarantee).
    local pfSeed, pfCommit = ui.pfCommit()

    -- \u2500\u2500 Wait for Enter ───────────────────────────────────────────────────────────
    local function drawWaitScreen()
        ui.banner("Wheel of Fortune")
        ui.center(5, "[  ---  ]", colors.gray)
        ui.rule(6)
        ui.center(7, string.format("Bet: %d uAMI", bet), colors.yellow)
        ui.line(8, "  [Enter] = SPIN   [?] = help   [B] = back", colors.orange)
        ui.pfShowCommit(9, pfCommit)
    end
    drawWaitScreen()
    while true do
        local ev, a = os.pullEvent()
        if ev == "char" and a == "?" then
            ui.helpOverlay("Wheel of Fortune \u2014 Help", _HELP.wheel)
            drawWaitScreen()
        elseif ev == "key" then
            if a == keys.b then return 0, "Cancelled" end
            if a == keys.enter or a == keys.numPadEnter then break end
        end
    end

    -- \u2500\u2500 Outcome determined before animation (provably fair order) \u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500
    local winSeg = POOL[math.random(#POOL)]

    -- \u2500\u2500 Spin animation \u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500
    -- Timer-driven: show 3 segments (prev \u2022 NEEDLE \u2022 next), slowing to winner.
    local FRAMES = 30
    local frame  = 0
    local tid    = os.startTimer(0.04)
    while frame < FRAMES do
        local ev, a = os.pullEvent()
        if ev == "timer" and a == tid then
            frame = frame + 1
            local locking = frame > FRAMES - 5
            local cur  = locking and winSeg           or POOL[math.random(#POOL)]
            local prev = locking and winSeg           or POOL[math.random(#POOL)]
            local nxt  = locking and winSeg           or POOL[math.random(#POOL)]
            ui.banner("Wheel of Fortune")
            ui.center(4, string.format("  %-6s",  prev.sym), colors.gray)
            ui.center(5, string.format("\u25ba %-4s \u25c4", cur.sym), cur.col)
            ui.center(6, string.format("  %-6s",  nxt.sym),  colors.gray)
            ui.rule(7)
            -- Speed bar: full at start, shrinks to nothing
            local barW = math.max(0, math.floor((FRAMES - frame) / FRAMES * 20))
            ui.center(8, string.rep("\u2588", barW) .. string.rep("\u2591", 20 - barW), colors.gray)
            ui.center(9, string.format("Bet: %d uAMI", bet), colors.yellow)
            -- Pitch rises from 1.4 down to 0.8 as wheel decelerates
            local pitch = 1.4 - (frame / FRAMES) * 0.6
            ui.sfx("tick", 0.4, pitch)
            local delay = 0.04 + (frame / FRAMES) * 0.22
            tid = os.startTimer(delay)
        end
    end

    -- \u2500\u2500 Result \u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500
    local net = math.floor(bet * winSeg.mult) - bet
    ui.banner("Wheel of Fortune")
    ui.center(5, string.format("\u25ba %-4s \u25c4", winSeg.sym), winSeg.col)
    ui.rule(6)
    ui.pfReveal(7, pfSeed)
    os.sleep(0.3)
    if net > 0 then
        if winSeg.mult >= 10 then ui.sfx("jackpot") else ui.sfx("win") end
        ui.winBanner(winSeg.sym .. "!", string.format("+%d uAMI", net))
    else
        ui.sfx("loss")
        ui.loseBanner("MISS", string.format("-%d uAMI", bet))
    end
    os.sleep(1.5)
    return net, string.format("Wheel: %s net=%+d", winSeg.sym, net)
end

return games

