-- ami/casino/games.lua
-- AmiCasino — All 9 game implementations.
--
-- Each public function receives:
--   ui       : the ui module
--   balance  : player's current µAMI balance (read-only; used to cap bets)
--
-- Each returns:
--   net (integer µAMI)  — positive = winnings, negative = loss, 0 = push
--   desc (string)       — human-readable outcome
--
-- Games never touch the ledger; startup.lua applies the net change.

local games = {}

-- ── Shared RNG seed (call once at startup) ────────────────────────────────────
math.randomseed(os.epoch("utc") + os.getComputerID() * 7919)

-- ── Helpers ───────────────────────────────────────────────────────────────────
local function card()
    local ranks = {"A","2","3","4","5","6","7","8","9","10","J","Q","K"}
    return ranks[math.random(#ranks)]
end

local function cardVal(r)
    if r == "A" then return 11 end
    if tonumber(r) then return tonumber(r) end
    return 10
end

local function handVal(hand)
    local total, aces = 0, 0
    for _, r in ipairs(hand) do
        total = total + cardVal(r)
        if r == "A" then aces = aces + 1 end
    end
    while total > 21 and aces > 0 do
        total = total - 10; aces = aces - 1
    end
    return total
end

local function handStr(hand)
    return table.concat(hand, " ") .. "  (" .. handVal(hand) .. ")"
end

-- ── 1. Mines ──────────────────────────────────────────────────────────────────
-- 5×5 grid, N hidden mines. Player reveals tiles to grow a multiplier,
-- can cash out any time. Hitting a mine loses the bet.
function games.mines(ui, balance)
    local GRID_W, GRID_H = 5, 5
    local TOTAL = GRID_W * GRID_H   -- 25 tiles

    ui.banner("Mines")
    ui.rule(4)
    ui.line(5, "Choose mine count [1-12]:", colors.yellow)
    ui.line(6, "More mines = higher risk & reward.", colors.lightGray)
    ui.line(7, "B = back", colors.gray)
    term.setCursorPos(1, 8); term.setTextColor(colors.white); io.write("> ")
    local mineRaw = read()
    mineRaw = mineRaw:gsub("%s", "")
    if mineRaw:lower() == "b" then return 0, "Cancelled" end
    local mineCount = tonumber(mineRaw)
    if not mineCount or mineCount < 1 or mineCount > 12 then
        return 0, "Invalid mine count"
    end

    local bet = ui.readBet(9, balance)
    if not bet then return 0, "Cancelled" end

    -- Place mines randomly
    local mines = {}
    while #mines < mineCount do
        local pos = math.random(TOTAL)
        local dup = false
        for _, m in ipairs(mines) do if m == pos then dup = true; break end end
        if not dup then mines[#mines + 1] = pos end
    end
    local isMine = {}
    for _, m in ipairs(mines) do isMine[m] = true end

    local revealed = {}
    local safeCount = TOTAL - mineCount
    local safeFound = 0
    -- Multiplier per safe tile revealed: grows geometrically
    -- mult(n) = product_{k=0}^{n-1} (TOTAL - mineCount) / (TOTAL - mineCount - k)
    -- simplified: House edge ~2%
    local function currentMult()
        local m = 1.0
        for k = 0, safeFound - 1 do
            m = m * (TOTAL - mineCount) / (TOTAL - mineCount - k) * 0.98
        end
        return m
    end

    while true do
        ui.banner("Mines")
        -- Draw grid
        local row = 4
        for gy = 1, GRID_H do
            local line = "  "
            for gx = 1, GRID_W do
                local pos = (gy - 1) * GRID_W + gx
                if revealed[pos] == "safe" then
                    line = line .. "[" .. string.format("%2d", pos) .. "] "
                elseif revealed[pos] == "mine" then
                    line = line .. "[ X ] "
                else
                    line = line .. "[  . ] "
                end
            end
            ui.line(row, line:sub(1, ui.W()), colors.white)
            row = row + 1
        end

        local mult   = currentMult()
        local profit = math.floor(bet * mult) - bet
        ui.rule(row); row = row + 1
        ui.line(row, string.format("Mult: x%.3f  Profit: +%d uAMI", mult, profit), colors.lime); row = row + 1
        ui.line(row, string.format("Safe found: %d / %d   Mines: %d", safeFound, safeCount, mineCount), colors.lightGray); row = row + 1
        ui.rule(row); row = row + 1
        ui.line(row, "Enter tile# to reveal  [C]ashout  [B]ack", colors.yellow)

        term.setCursorPos(1, row + 1); term.setTextColor(colors.white); io.write("> ")
        local inp = read(); inp = inp:gsub("%s", "")

        if inp:lower() == "b" then return 0, "Folded (no bet placed)"
        elseif inp:lower() == "c" then
            if safeFound == 0 then return 0, "Cashed out before any reveal" end
            local winnings = math.floor(bet * mult)
            return winnings - bet, string.format("Cashed out x%.3f  +%d uAMI", mult, winnings - bet)
        else
            local pos = tonumber(inp)
            if not pos or pos < 1 or pos > TOTAL or revealed[pos] then
                -- invalid input — just redraw
            elseif isMine[pos] then
                revealed[pos] = "mine"
                ui.banner("Mines")
                ui.center(6, "  BOOM! You hit a mine!  ", colors.red)
                ui.center(7, string.format("Lost %d uAMI", bet), colors.red)
                os.sleep(2.5)
                return -bet, string.format("MINE at tile %d. Lost %d uAMI.", pos, bet)
            else
                revealed[pos] = "safe"
                safeFound = safeFound + 1
                if safeFound == safeCount then
                    -- Cleared the board
                    local winnings = math.floor(bet * currentMult())
                    ui.banner("Mines")
                    ui.center(6, "BOARD CLEARED! Amazing!", colors.lime)
                    ui.center(7, string.format("+%d uAMI", winnings - bet), colors.lime)
                    os.sleep(2.5)
                    return winnings - bet, string.format("Board cleared! +%d uAMI", winnings - bet)
                end
            end
        end
    end
end

-- ── 2. Crash ──────────────────────────────────────────────────────────────────
-- Multiplier grows from 1.0 upward. It will crash at a random point.
-- Player must press [C] to cash out before the crash.
function games.crash(ui, balance)
    ui.banner("Crash")
    ui.rule(4)
    ui.line(5, "The multiplier rises until it CRASHES.", colors.yellow)
    ui.line(6, "Press [C] to cash out before it does!", colors.lightGray)

    local bet = ui.readBet(7, balance)
    if not bet then return 0, "Cancelled" end

    -- Crash point: house edge ~4%, skewed toward low crashes
    -- P(crash <= x) = 1 - 0.96/x   for x >= 1.04
    local r = math.random()
    local crashAt = 0.96 / (1 - r)
    if crashAt < 1.01 then crashAt = 1.01 end

    local mult     = 1.0
    local crashed  = false
    local cashedOut = false
    local cashMult  = nil

    -- We drive the loop with os.startTimer so the player can press C
    ui.banner("Crash")
    ui.rule(4)
    ui.line(5, string.format("Bet: %d uAMI", bet), colors.yellow)
    ui.line(7, "[C] Cash out now", colors.orange)

    local tickId = os.startTimer(0.2)
    while true do
        local ev, a = os.pullEvent()
        if ev == "timer" and a == tickId then
            mult = mult + (mult * 0.07)   -- ~40% per second at 5 ticks/s
            if mult >= crashAt then
                crashed = true; break
            end
            ui.center(6, string.format("x%.3f", mult), colors.lime)
            ui.line(8,  string.format("Cash out now: +%d uAMI",
                math.floor(bet * mult) - bet), colors.lightGray)
            tickId = os.startTimer(0.2)
        elseif ev == "key" and a == keys.c then
            if not crashed then
                cashedOut = true; cashMult = mult; break
            end
        end
    end

    if cashedOut then
        local winnings = math.floor(bet * cashMult)
        ui.banner("Crash")
        ui.center(5, string.format("Cashed out at x%.3f!", cashMult), colors.lime)
        ui.center(6, string.format("+%d uAMI", winnings - bet), colors.lime)
        os.sleep(2)
        return winnings - bet, string.format("Cashed x%.3f  +%d uAMI", cashMult, winnings - bet)
    else
        ui.banner("Crash")
        ui.center(5, string.format("CRASHED at x%.3f!", crashAt), colors.red)
        ui.center(6, string.format("Lost %d uAMI", bet), colors.red)
        os.sleep(2)
        return -bet, string.format("Crashed at x%.3f. Lost %d uAMI.", crashAt, bet)
    end
end

-- ── 3. Slots ──────────────────────────────────────────────────────────────────
-- 3-reel slot machine. Five symbol types with different payout tables.
function games.slots(ui, balance)
    local SYMS = { "7", "$", "A", "K", "J" }
    -- Payout multipliers for 3-of-a-kind (net, on top of returned bet)
    local PAY3 = { ["7"]=10, ["$"]=5, ["A"]=3, ["K"]=2, ["J"]=1 }
    -- Two of same leftmost pair pays 0.5x
    local PAY2 = 0.5

    ui.banner("Slots")
    ui.rule(4)
    ui.line(5, "Match 3 for big wins!", colors.yellow)
    ui.line(6, "Three 7s = 10x your bet.", colors.lightGray)

    local bet = ui.readBet(7, balance)
    if not bet then return 0, "Cancelled" end

    -- Weighted reel: 7 is rare
    local reel = {"7","$","$","A","A","K","K","K","J","J","J","J"}
    local r1 = reel[math.random(#reel)]
    local r2 = reel[math.random(#reel)]
    local r3 = reel[math.random(#reel)]

    ui.banner("Slots")
    ui.spinReels(6, SYMS, r1, r2, r3)
    ui.center(6, string.format("  [ %s | %s | %s ]", r1, r2, r3), colors.yellow)

    local net, desc
    if r1 == r2 and r2 == r3 then
        local mult = PAY3[r1] or 1
        net  = math.floor(bet * mult)
        desc = string.format("3x %s! x%d  +%d uAMI", r1, mult, net)
        ui.center(8, "JACKPOT! " .. desc, colors.lime)
    elseif r1 == r2 then
        net  = math.floor(bet * PAY2)
        desc = string.format("Pair %s+%s  +%d uAMI", r1, r2, net)
        ui.center(8, desc, colors.yellow)
    else
        net  = -bet
        desc = string.format("No match. Lost %d uAMI.", bet)
        ui.center(8, desc, colors.red)
    end

    os.sleep(2)
    return net, desc
end

-- ── 4. Blackjack ─────────────────────────────────────────────────────────────
-- Standard rules: dealer stands on soft 17, 3:2 blackjack, no split/double.
function games.blackjack(ui, balance)
    ui.banner("Blackjack")
    ui.rule(4)
    ui.line(5, "Get as close to 21 as possible.", colors.yellow)
    ui.line(6, "Dealer stands on soft 17. BJ pays 3:2.", colors.lightGray)

    local bet = ui.readBet(7, balance)
    if not bet then return 0, "Cancelled" end

    local player = { card(), card() }
    local dealer = { card(), card() }

    local function redraw(hideDealer)
        ui.banner("Blackjack")
        ui.rule(4)
        if hideDealer then
            ui.line(5, "Dealer: " .. dealer[1] .. " [?]", colors.lightGray)
        else
            ui.line(5, "Dealer: " .. handStr(dealer), colors.lightGray)
        end
        ui.line(6, "You:    " .. handStr(player), colors.white)
        ui.rule(7)
        ui.line(8, string.format("Bet: %d uAMI", bet), colors.yellow)
    end

    redraw(true)

    -- Check natural blackjack
    if handVal(player) == 21 then
        if handVal(dealer) == 21 then
            ui.center(10, "Both Blackjack — Push!", colors.yellow)
            os.sleep(2); return 0, "Push (both BJ)"
        else
            local bj = math.floor(bet * 1.5)
            ui.center(10, "BLACKJACK! +" .. bj .. " uAMI", colors.lime)
            os.sleep(2); return bj, "Blackjack +" .. bj .. " uAMI"
        end
    end

    -- Player turn
    while true do
        local pv = handVal(player)
        redraw(true)
        if pv > 21 then
            ui.center(10, "BUST! Lost " .. bet .. " uAMI", colors.red)
            os.sleep(2); return -bet, "Bust"
        end
        ui.line(9, "[H]it  [S]tand", colors.orange)
        local _, k = os.pullEvent("key")
        if k == keys.h then
            player[#player + 1] = card()
        elseif k == keys.s then
            break
        end
    end

    if handVal(player) > 21 then
        redraw(false)
        ui.center(10, "BUST! Lost " .. bet .. " uAMI", colors.red)
        os.sleep(2); return -bet, "Bust"
    end

    -- Dealer turn (stands on 17+)
    while handVal(dealer) < 17 do
        dealer[#dealer + 1] = card()
    end

    redraw(false)
    local pv, dv = handVal(player), handVal(dealer)
    local net, desc
    if dv > 21 then
        net = bet; desc = "Dealer bust! +" .. bet .. " uAMI"
        ui.center(10, "Dealer BUSTS!  +" .. bet .. " uAMI", colors.lime)
    elseif pv > dv then
        net = bet; desc = "Win! +" .. bet .. " uAMI"
        ui.center(10, "YOU WIN!  +" .. bet .. " uAMI", colors.lime)
    elseif pv == dv then
        net = 0; desc = "Push"
        ui.center(10, "Push.", colors.yellow)
    else
        net = -bet; desc = "Dealer wins. -" .. bet .. " uAMI"
        ui.center(10, "Dealer wins.  -" .. bet .. " uAMI", colors.red)
    end

    os.sleep(2.5)
    return net, desc
end

-- ── 5. Roulette ───────────────────────────────────────────────────────────────
-- European single-zero roulette. Supports: number, red/black, odd/even, high/low.
function games.roulette(ui, balance)
    local RED = {1,3,5,7,9,12,14,16,18,19,21,23,25,27,30,32,34,36}
    local redSet = {}; for _, n in ipairs(RED) do redSet[n] = true end

    ui.banner("Roulette")
    ui.rule(4)
    ui.line(5, "Single-zero European roulette.", colors.yellow)
    ui.line(6, "Bets: number(35:1) red/black odd/even hi/lo(1:1)", colors.lightGray)

    local bet = ui.readBet(7, balance)
    if not bet then return 0, "Cancelled" end

    ui.rule(9)
    ui.line(10, "Your bet type:", colors.yellow)
    ui.line(11, "[N] Number (0-36)  [R] Red  [B] Black", colors.white)
    ui.line(12, "[O] Odd  [E] Even  [H] High(19-36)  [L] Low(1-18)", colors.white)

    local betType, betNum
    while true do
        local _, k = os.pullEvent("key")
        if k == keys.n then
            ui.line(13, "Which number (0-36)?", colors.yellow)
            term.setCursorPos(1, 14); io.write("> ")
            local raw = read()
            betNum = tonumber(raw)
            if betNum and betNum >= 0 and betNum <= 36 then
                betType = "number"; break
            end
        elseif k == keys.r then betType = "red";   break
        elseif k == keys.b then betType = "black"; break
        elseif k == keys.o then betType = "odd";   break
        elseif k == keys.e then betType = "even";  break
        elseif k == keys.h then betType = "high";  break
        elseif k == keys.l then betType = "low";   break
        end
    end

    -- Spin
    ui.banner("Roulette")
    ui.center(5, "Spinning the wheel...", colors.yellow)
    for _ = 1, 12 do
        ui.center(6, tostring(math.random(0, 36)), colors.white)
        os.sleep(0.12)
    end
    local result = math.random(0, 36)
    local isRed  = redSet[result]
    local color  = result == 0 and "green" or (isRed and "red" or "black")
    local colCode = result == 0 and colors.green or (isRed and colors.red or colors.gray)
    ui.center(6, string.format("  %d  (%s)  ", result, color), colCode)

    local win = false
    if betType == "number" then
        win = (result == betNum)
    elseif betType == "red"   then win = (isRed and result ~= 0)
    elseif betType == "black" then win = (not isRed and result ~= 0)
    elseif betType == "odd"   then win = (result ~= 0 and result % 2 == 1)
    elseif betType == "even"  then win = (result ~= 0 and result % 2 == 0)
    elseif betType == "high"  then win = (result >= 19)
    elseif betType == "low"   then win = (result >= 1 and result <= 18)
    end

    local payout = (betType == "number") and 35 or 1
    local net, desc
    if win then
        net = bet * payout
        desc = string.format("WIN! %d %s pays %d:1  +%d uAMI", result, color, payout, net)
        ui.center(8, desc:sub(1, ui.W()), colors.lime)
    else
        net = -bet
        desc = string.format("LOSE. Ball: %d (%s). Lost %d uAMI.", result, color, bet)
        ui.center(8, desc:sub(1, ui.W()), colors.red)
    end

    os.sleep(2.5)
    return net, desc
end

-- ── 6. Higher / Lower ─────────────────────────────────────────────────────────
-- 5 cards drawn one at a time. Guess if the next card is higher or lower.
-- Win streak multiplies the payout. Getting it wrong ends the game.
function games.higherLower(ui, balance)
    ui.banner("Higher / Lower")
    ui.rule(4)
    ui.line(5, "5 rounds. Guess Higher [H] or Lower [L].", colors.yellow)
    ui.line(6, "Win all 5 to multiply your bet by 3.2x.", colors.lightGray)
    ui.line(7, "Equal card = push (free round).", colors.lightGray)

    local bet = ui.readBet(8, balance)
    if not bet then return 0, "Cancelled" end

    local RANKS = {"2","3","4","5","6","7","8","9","10","J","Q","K","A"}
    local rankIdx = {}
    for i, r in ipairs(RANKS) do rankIdx[r] = i end

    local current = RANKS[math.random(#RANKS)]
    local streak  = 0
    local ROUNDS  = 5
    -- Multipliers per correct guess: 1→1.2→1.5→1.9→2.5→3.2
    local MULTS   = {1.2, 1.5, 1.9, 2.5, 3.2}

    for round = 1, ROUNDS do
        ui.banner("Higher / Lower")
        ui.rule(4)
        ui.line(5, string.format("Round %d / %d", round, ROUNDS), colors.lightGray)
        ui.line(6, "Current card: " .. current, colors.yellow)
        ui.line(7, string.format("Streak: %d  Mult: x%.1f", streak, MULTS[math.max(1, streak)] or 1), colors.cyan)
        ui.rule(8)
        ui.line(9, "[H] Higher  [L] Lower  [Q] Quit (take current win)", colors.orange)

        local _, k = os.pullEvent("key")
        if k == keys.q then
            if streak == 0 then return 0, "Quit with no streak" end
            local m = MULTS[streak] or 1
            local w = math.floor(bet * m) - bet
            return w, string.format("Quit at streak %d (x%.1f) +%d uAMI", streak, m, w)
        end

        local next = RANKS[math.random(#RANKS)]
        local ci, ni = rankIdx[current], rankIdx[next]

        ui.line(10, "Next card: " .. next, colors.white)

        local correct
        if ci == ni then
            correct = true  -- push, free round
            ui.center(11, "Equal! Free round.", colors.yellow)
        elseif k == keys.h then
            correct = ni > ci
        elseif k == keys.l then
            correct = ni < ci
        else
            correct = false
        end

        os.sleep(0.8)

        if correct then
            streak = streak + 1
            current = next
            if streak == ROUNDS then
                local m = MULTS[ROUNDS]
                local w = math.floor(bet * m) - bet
                ui.center(12, string.format("PERFECT! x%.1f  +%d uAMI", m, w), colors.lime)
                os.sleep(2)
                return w, string.format("Perfect 5-streak x%.1f +%d uAMI", m, w)
            end
        else
            ui.center(11, "WRONG!  -" .. bet .. " uAMI", colors.red)
            os.sleep(1.5)
            return -bet, string.format("Wrong on round %d. Lost %d uAMI.", round, bet)
        end
    end
    return 0, "Completed"
end

-- ── 7. Pachinko ──────────────────────────────────────────────────────────────
-- Simulated 7-row peg board. Ball falls left/right at each peg (biased
-- slightly toward center). Final bucket determines payout multiplier.
function games.pachinko(ui, balance)
    local ROWS    = 7
    local BUCKETS = ROWS + 1   -- 8 buckets
    -- Payout multipliers (outer = high, center = low — classic pachinko shape)
    local PAYS = {12, 5, 2, 0.5, 0.5, 2, 5, 12}

    ui.banner("Pachinko")
    ui.rule(4)
    ui.line(5, "7 rows of pegs. Ball bounces L/R.", colors.yellow)
    ui.line(6, "Outer buckets: 12x. Centre: 0.5x.", colors.lightGray)

    local bet = ui.readBet(7, balance)
    if not bet then return 0, "Cancelled" end

    -- Simulate ball path
    local pos = 0    -- starts centered, range: -ROWS..+ROWS in steps of 2
    local path = {}
    for _ = 1, ROWS do
        local dir = math.random() < 0.5 and -1 or 1
        pos = pos + dir
        path[#path + 1] = pos
    end
    -- pos is now in range [-ROWS, +ROWS], step 1
    -- Map to bucket index 1..8
    local bucketIdx = math.floor((pos + ROWS) / (ROWS * 2) * (BUCKETS - 1)) + 1
    bucketIdx = math.max(1, math.min(BUCKETS, bucketIdx))
    local mult = PAYS[bucketIdx]

    -- Animate the path row by row
    ui.banner("Pachinko")
    local boardW = ROWS * 2 + 5
    for step, p in ipairs(path) do
        ui.banner("Pachinko")
        for row = 1, ROWS do
            local peg = ""
            for col = -row, row do
                if col % 2 == 0 then
                    if row == step and col == p then
                        peg = peg .. "O"
                    else
                        peg = peg .. "."
                    end
                else
                    peg = peg .. " "
                end
            end
            ui.center(3 + row, peg, row == step and colors.yellow or colors.gray)
        end
        os.sleep(0.18)
    end

    -- Show buckets
    local bucketLine = ""
    for i = 1, BUCKETS do
        local lbl = tostring(PAYS[i]):sub(1,4)
        if i == bucketIdx then
            bucketLine = bucketLine .. "[" .. lbl .. "]"
        else
            bucketLine = bucketLine .. " " .. lbl .. " "
        end
    end
    ui.center(3 + ROWS + 2, bucketLine:sub(1, ui.W()), colors.white)

    local net, desc
    if mult >= 1 then
        net = math.floor(bet * mult) - bet
        desc = string.format("Bucket %d (x%.1f) +%d uAMI", bucketIdx, mult, net)
        ui.center(3 + ROWS + 3, "WIN! " .. desc:sub(1, ui.W() - 5), colors.lime)
    else
        net = math.floor(bet * mult) - bet  -- negative when mult < 1
        desc = string.format("Bucket %d (x%.1f) %d uAMI", bucketIdx, mult, net)
        ui.center(3 + ROWS + 3, desc:sub(1, ui.W()), colors.red)
    end

    os.sleep(2.5)
    return net, desc
end

-- ── 8. Craps ─────────────────────────────────────────────────────────────────
-- Pass line craps. Come-out roll; 7/11 win, 2/3/12 lose, else set point.
-- Once point is set, roll until point (win) or 7 (lose).
function games.craps(ui, balance)
    local function roll2d6()
        return math.random(1, 6) + math.random(1, 6)
    end

    ui.banner("Craps")
    ui.rule(4)
    ui.line(5, "Pass Line Craps.", colors.yellow)
    ui.line(6, "Come-out: 7/11=WIN  2/3/12=LOSE  else=Point", colors.lightGray)
    ui.line(7, "Point set: roll point before 7 to WIN.", colors.lightGray)

    local bet = ui.readBet(8, balance)
    if not bet then return 0, "Cancelled" end

    -- Come-out roll
    ui.banner("Craps")
    ui.line(5, "Press any key to roll come-out...", colors.orange)
    ui.waitKey()

    local comeOut = roll2d6()
    ui.center(6, string.format("Come-out roll: %d", comeOut), colors.yellow)
    os.sleep(0.8)

    if comeOut == 7 or comeOut == 11 then
        ui.center(7, "Natural! WIN +" .. bet .. " uAMI", colors.lime)
        os.sleep(1.5)
        return bet, "Natural " .. comeOut .. " +win"
    elseif comeOut == 2 or comeOut == 3 or comeOut == 12 then
        ui.center(7, "Craps! LOSE -" .. bet .. " uAMI", colors.red)
        os.sleep(1.5)
        return -bet, "Craps " .. comeOut .. " -lose"
    end

    local point = comeOut
    ui.center(7, string.format("Point set: %d", point), colors.cyan)
    os.sleep(0.8)

    while true do
        ui.rule(8)
        ui.line(9, string.format("Point: %d — Press any key to roll...", point), colors.orange)
        ui.waitKey()

        local r = roll2d6()
        ui.center(10, string.format("Rolled: %d", r), colors.yellow)
        os.sleep(0.8)

        if r == point then
            ui.center(11, "Hit the point! WIN +" .. bet .. " uAMI", colors.lime)
            os.sleep(1.5)
            return bet, string.format("Point %d hit +win", point)
        elseif r == 7 then
            ui.center(11, "Seven-out! LOSE -" .. bet .. " uAMI", colors.red)
            os.sleep(1.5)
            return -bet, string.format("Seven-out. Point was %d.", point)
        end

        ui.center(11, "No result. Rolling again...", colors.gray)
        os.sleep(0.5)
    end
end

-- ── 9. Coin Flip ─────────────────────────────────────────────────────────────
-- 50/50. Pays 1.92x (house edge ~4%). Choose heads or tails.
function games.coinflip(ui, balance)
    ui.banner("Coin Flip")
    ui.rule(4)
    ui.line(5, "50/50. Win pays 1.92x (house edge 4%).", colors.yellow)

    local bet = ui.readBet(6, balance)
    if not bet then return 0, "Cancelled" end

    ui.line(8, "[H] Heads   [T] Tails", colors.orange)
    local choice
    while not choice do
        local _, k = os.pullEvent("key")
        if k == keys.h then choice = "Heads"
        elseif k == keys.t then choice = "Tails"
        end
    end

    -- Flip animation
    local sides = {"Heads", "Tails"}
    ui.banner("Coin Flip")
    for _ = 1, 10 do
        ui.center(6, sides[math.random(2)], colors.yellow)
        os.sleep(0.08)
    end

    local result = sides[math.random(2)]
    ui.center(6, result, result == "Heads" and colors.lime or colors.cyan)

    local net, desc
    if result == choice then
        net  = math.floor(bet * 0.92)   -- 1.92x total return → 0.92x net profit
        desc = string.format("%s! WIN +%d uAMI", result, net)
        ui.center(7, "YOU WIN!  +" .. net .. " uAMI", colors.lime)
    else
        net  = -bet
        desc = string.format("%s vs %s. LOSE -%d uAMI", result, choice, bet)
        ui.center(7, "You lose.  -" .. bet .. " uAMI", colors.red)
    end

    os.sleep(2)
    return net, desc
end

return games
