-- ami/casino/ui.lua
-- AmiCasino — shared terminal drawing helpers.

local ui = {}

local W, H = term.getSize()

function ui.W() return W end
function ui.H() return H end

function ui.cls()
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
    term.clear()
    term.setCursorPos(1, 1)
end

-- Gold/black casino banner
function ui.banner(title)
    ui.cls()
    term.setBackgroundColor(colors.yellow)
    term.setTextColor(colors.black)
    term.setCursorPos(1, 1); term.clearLine()
    local hdr = "  AmiCasino  "
    term.setCursorPos(math.floor((W - #hdr) / 2) + 1, 1)
    term.write(hdr)
    term.setBackgroundColor(colors.black)
    if title then
        term.setTextColor(colors.yellow)
        term.setCursorPos(math.floor((W - #title) / 2) + 1, 3)
        term.write(title)
    end
end

function ui.rule(y, col)
    term.setCursorPos(1, y)
    term.setTextColor(col or colors.gray)
    term.write(string.rep("-", W))
end

function ui.line(y, text, col, bg)
    term.setCursorPos(1, y)
    term.setTextColor(col or colors.white)
    term.setBackgroundColor(bg or colors.black)
    if #text > W then text = text:sub(1, W) end
    term.write(text)
end

function ui.center(y, text, col, bg)
    term.setTextColor(col or colors.white)
    term.setBackgroundColor(bg or colors.black)
    local x = math.floor((W - #text) / 2) + 1
    term.setCursorPos(x, y)
    if #text > W then text = text:sub(1, W) end
    term.write(text)
end

-- Print coloured AMI/uAMI string at (1,y)
function ui.amtLine(y, label, uami, col)
    term.setCursorPos(1, y)
    term.setTextColor(col or colors.white)
    local ami = string.format("%.4f AMI", uami / 1000000)
    term.write((label .. ami .. "  (" .. uami .. " uAMI)"):sub(1, W))
end

-- Wait for a key; returns the key code
function ui.waitKey()
    local _, k = os.pullEvent("key")
    return k
end

-- Wait for Y or N; returns true/false
function ui.yesNo(y, msg)
    ui.line(y, (msg or "[Y] Yes   [N] No"):sub(1, W), colors.orange)
    while true do
        local _, k = os.pullEvent("key")
        if k == keys.y then return true  end
        if k == keys.n then return false end
    end
end

-- Read an AMI amount (accepts decimal like "1.5" → 1500000 µAMI)
-- Returns integer µAMI, or nil on cancel/invalid.
function ui.readBet(y, balance)
    ui.line(y,   "Bet in AMI (e.g. 1.5):  [B]=back", colors.yellow)
    ui.line(y+1, "Bal: " .. string.format("%.4f AMI", balance / 1000000), colors.lightGray)
    term.setCursorPos(1, y+2); term.setTextColor(colors.white)
    io.write("> ")
    local raw = read()
    raw = raw:gsub("%s", "")
    if raw:lower() == "b" or raw == "" then return nil end
    local n = tonumber(raw)
    if not n or n <= 0 then return nil end
    local uami = math.floor(n * 1000000)
    if uami < 1      then return nil end
    if uami > balance then
        ui.line(y+3, "Not enough balance!", colors.red)
        os.sleep(1.2)
        return nil
    end
    return uami
end

-- Animated countdown bar (uses term width)
function ui.countdownBar(y, label, seconds)
    local full = W - #label - 3
    for i = seconds, 0, -0.5 do
        local filled = math.floor(full * i / seconds)
        term.setCursorPos(1, y)
        term.setTextColor(colors.cyan)
        term.write(label .. " [")
        term.setTextColor(colors.lime)
        term.write(string.rep("=", filled))
        term.setTextColor(colors.gray)
        term.write(string.rep(" ", full - filled))
        term.setTextColor(colors.cyan)
        term.write("]")
        os.sleep(0.5)
    end
end

-- Slot reel spin animation
function ui.spinReels(y, symbols, finalL, finalM, finalR)
    local SPIN_FRAMES = 14
    for f = 1, SPIN_FRAMES do
        local l = symbols[math.random(#symbols)]
        local m = symbols[math.random(#symbols)]
        local r = symbols[math.random(#symbols)]
        if f > SPIN_FRAMES - 3 then l = finalL end
        if f > SPIN_FRAMES - 2 then m = finalM end
        if f > SPIN_FRAMES - 1 then r = finalR end
        local disp = string.format("  [ %s | %s | %s ]", l, m, r)
        ui.center(y, disp, colors.yellow)
        os.sleep(0.08 + f * 0.01)
    end
end

return ui
