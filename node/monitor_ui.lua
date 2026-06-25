-- node/monitor_ui.lua
-- Opus-styled stats panel for an attached CC monitor.
-- Draws directly to the monitor peripheral; no Opus UI singleton needed.
-- Call MonitorUI.drawStats(mon, W, data) on each stats refresh cycle.

local colors = _G.colors
local math   = _G.math

local FRAMES
pcall(function() FRAMES = require('ami.lib.ui.widgets.fan_frames') end)

local MonitorUI = {}

-- Columns the fan occupies when the monitor is wide enough; 0 if unavailable.
MonitorUI.FAN_COLS = FRAMES and FRAMES.cols or 0

local _upgTick = 0  -- auto-scroll counter for upgrades list

local THEME_COLORS = {
    green_phosphor = { fg = colors.lime,     hdr = colors.green     },
    amber          = { fg = colors.orange,   hdr = colors.brown     },
    ice_blue       = { fg = colors.cyan,     hdr = colors.lightBlue },
    deep_violet    = { fg = colors.purple,   hdr = colors.purple    },
    neon_pink      = { fg = colors.pink,     hdr = colors.pink      },
    solar_orange   = { fg = colors.orange,   hdr = colors.red       },
    arctic_white   = { fg = colors.white,    hdr = colors.lightGray },
    spectrum       = { fg = colors.white,    hdr = colors.blue      },
    void_red       = { fg = colors.red,      hdr = colors.red       },
    genesis_gold   = { fg = colors.yellow,   hdr = colors.yellow    },
    crown_gold     = { fg = colors.yellow,   hdr = colors.yellow    },
}

-- Fill w cells starting at (x, y) with background color bg.
local function fill(mon, x, y, w, bg)
    if w <= 0 then return end
    mon.setBackgroundColor(bg)
    mon.setCursorPos(x, y)
    mon.write(string.rep(' ', w))
end

-- Write text at (x, y); clip to maxW chars if given.
local function put(mon, x, y, text, bg, tc, maxW)
    if maxW and maxW <= 0 then return end
    if maxW then text = text:sub(1, maxW) end
    if bg then mon.setBackgroundColor(bg) end
    if tc then mon.setTextColor(tc) end
    mon.setCursorPos(x, y)
    mon.write(text)
end

-- Clear row y across columns 1..W.
local function row0(mon, y, W, bg)
    fill(mon, 1, y, W, bg)
end

-- Progress bar using colored background spaces.
local function bar(mon, x, y, w, v01, fillBg, emptyBg)
    local n = math.floor(w * math.max(0, math.min(1.0, v01)) + 0.5)
    fill(mon, x,     y, n,     fillBg)
    fill(mon, x + n, y, w - n, emptyBg)
end

-- Draw stats panel into columns 1..W of the monitor.
--
-- data = {
--   version, theme, nodeKey (full hex), fingerprint (8-hex), channel,
--   activeWallets, totalSupply (uAMI), effRate (int),
--   lagFactor (0-1), netTemp, thermalShutoff (bool), coolingLevel,
--   mintProgress (0-1), mintRemaining (s),
--   upgrades: { {name, level}, ... },
--   crownLevel, casinoRakeLevel, priorityPing (bool), totalTicks,
-- }
function MonitorUI.drawStats(mon, W, data)
    local _, mh = mon.getSize()
    local tc  = (data.theme and THEME_COLORS[data.theme])
                or { fg = colors.white, hdr = colors.red }
    local bBg = colors.black
    local gBg = colors.gray
    local r   = 1

    -- ── TitleBar ──────────────────────────────────────────────────────────────
    local title = 'AmiCoin Node v' .. tostring(data.version or '?')
    local tx = math.max(1, math.floor((W - #title) / 2) + 1)
    row0(mon, r, W, tc.hdr)
    put(mon, tx, r, title, tc.hdr, colors.white, W - tx + 1)
    r = r + 1

    -- ── Identity panel (gray) ─────────────────────────────────────────────────
    -- Row: Key (truncated)
    local keyDisp = tostring(data.nodeKey or '?'):sub(1, math.max(4, W - 7)) .. '..'
    row0(mon, r, W, gBg)
    put(mon, 1, r, ' Key ', gBg, colors.lightGray)
    put(mon, 6, r, keyDisp, gBg, tc.fg, W - 5)
    r = r + 1

    -- Row: Fingerprint + Channel inline
    local fpStr = 'FP:' .. tostring(data.fingerprint or '?'):sub(1, 8)
    local chStr = '  Ch:' .. tostring(data.channel or '?')
    row0(mon, r, W, gBg)
    put(mon, 1, r, ' ' .. fpStr, gBg, colors.cyan)
    put(mon, 1 + #fpStr + 1, r, chStr, gBg, tc.fg, W - #fpStr - 1)
    r = r + 1

    -- ── Network/Economy panel (black) ─────────────────────────────────────────
    -- Row: Wallets | TPS
    local wStr = 'Wallets:' .. tostring(data.activeWallets or 0)
    local tpsStr, tpsCol
    if (data.lagFactor or 1) < 0.7 then
        tpsStr = string.format('LAG~%.0f%%', (data.lagFactor or 0) * 100)
        tpsCol = colors.red
    else
        tpsStr = 'TPS:OK'
        tpsCol = colors.lime
    end
    row0(mon, r, W, bBg)
    put(mon, 1, r, ' ' .. wStr, bBg, tc.fg)
    if W - #wStr - 2 >= #tpsStr then
        put(mon, W - #tpsStr + 1, r, tpsStr, bBg, tpsCol)
    end
    r = r + 1

    -- Row: Supply (uAMI), and AMI right-aligned if it fits
    local uamiStr = tostring(data.totalSupply or 0) .. ' uAMI'
    local amiStr  = string.format('%.6f AMI', (data.totalSupply or 0) / 1e6)
    row0(mon, r, W, bBg)
    put(mon, 1, r, ' Supply ', bBg, colors.lightGray)
    put(mon, 9, r, uamiStr, bBg, tc.fg)
    local amiFits = W >= 9 + #uamiStr + 2 + #amiStr
    if amiFits then
        put(mon, W - #amiStr + 1, r, amiStr, bBg, colors.yellow)
    end
    r = r + 1
    if not amiFits then
        row0(mon, r, W, bBg)
        put(mon, 9, r, amiStr, bBg, colors.yellow, W - 8)
        r = r + 1
    end

    -- Row: Rate (uAMI/tk), and AMI/hr right-aligned if it fits
    local effRate = data.effRate or 0
    local rateStr = string.format('%d uAMI/tk', effRate)
    local hrStr   = string.format('%.4f AMI/hr', effRate * 120 / 1e6)
    row0(mon, r, W, bBg)
    put(mon, 1, r, ' Rate   ', bBg, colors.lightGray)
    put(mon, 9, r, rateStr, bBg, tc.fg)
    local hrFits = W >= 9 + #rateStr + 2 + #hrStr
    if hrFits then
        put(mon, W - #hrStr + 1, r, hrStr, bBg, colors.yellow)
    end
    r = r + 1
    if not hrFits then
        row0(mon, r, W, bBg)
        put(mon, 9, r, hrStr, bBg, colors.yellow, W - 8)
        r = r + 1
    end

    -- Row: Total ticks (if non-zero and there's room)
    if (data.totalTicks or 0) > 0 and r <= mh - 5 then
        row0(mon, r, W, bBg)
        put(mon, 1, r, ' Ticks  ', bBg, colors.lightGray)
        put(mon, 9, r, string.format('%d', data.totalTicks), bBg, tc.fg)
        r = r + 1
    end

    -- ── Thermal + Mint panel (gray) ───────────────────────────────────────────
    local tempCol, tempStr
    local nt = data.netTemp or 0
    if data.thermalShutoff then
        tempCol, tempStr = colors.red,    string.format('%dC THROTTLED', nt)
    elseif nt >= 200 then
        tempCol, tempStr = colors.orange, string.format('%dC HOT', nt)
    elseif nt >= 100 then
        tempCol, tempStr = colors.yellow, string.format('%dC WARM', nt)
    else
        tempCol, tempStr = colors.lime,   string.format('%dC OK', nt)
    end
    local coolLv   = data.coolingLevel or 0
    local coolBadge = coolLv > 0 and string.format('|CoolLv%d', coolLv) or ''

    row0(mon, r, W, gBg)
    put(mon, 1, r, ' Temp  ', gBg, colors.lightGray)
    put(mon, 8, r, tempStr .. (coolBadge ~= '' and (' ' .. coolBadge) or ''), gBg, tempCol, W - 7)
    r = r + 1

    -- Row: Mint progress bar + countdown
    local mp, mr = data.mintProgress, data.mintRemaining
    if mp ~= nil and mr ~= nil and r <= mh then
        local remStr = string.format('%ds', math.ceil(mr))
        row0(mon, r, W, gBg)
        put(mon, 1, r, ' Mint  ', gBg, colors.lightGray)
        local bx = 8
        local bw = W - bx - #remStr - 1
        if bw >= 3 then
            bar(mon, bx, r, bw, mp, colors.cyan, colors.gray)
            put(mon, bx + bw + 1, r, remStr, gBg, colors.cyan)
        else
            put(mon, bx, r, remStr, gBg, colors.cyan, W - bx + 1)
        end
        r = r + 1
    end

    -- Row: Special feature flags
    local flags = {}
    if data.priorityPing              then flags[#flags+1] = 'PPing'                           end
    if (data.crownLevel or 0) > 0    then flags[#flags+1] = 'Crown'..data.crownLevel          end
    if (data.casinoRakeLevel or 0) > 0 then flags[#flags+1] = 'Casino'..data.casinoRakeLevel  end
    if #flags > 0 and r <= mh then
        row0(mon, r, W, gBg)
        put(mon, 1, r, ' ' .. table.concat(flags, '  '), gBg, colors.yellow, W)
        r = r + 1
    end

    -- ── Upgrades panel (black) ────────────────────────────────────────────────
    _upgTick = _upgTick + 1
    local upgs = data.upgrades or {}

    if r <= mh then
        -- compute scroll window before drawing header
        local availRows = mh - r        -- rows available for entries (excludes header)
        local scrollOff = 0
        if #upgs > availRows and availRows > 0 then
            scrollOff = math.floor(_upgTick / 30) % (#upgs - availRows + 1)
        end

        local hdrSuffix = (#upgs > availRows)
            and string.format(' [%d/%d]', scrollOff + 1, #upgs)
            or ''
        row0(mon, r, W, bBg)
        put(mon, 1, r, ' Active Upgrades' .. hdrSuffix, bBg, colors.yellow, W)
        r = r + 1

        if #upgs == 0 and r <= mh then
            row0(mon, r, W, bBg)
            put(mon, 2, r, '(none)', bBg, colors.gray)
            r = r + 1
        else
            local twoCol = W >= 38
            local colW   = twoCol and math.floor(W / 2) or W
            local i = scrollOff + 1
            while i <= #upgs and r <= mh do
                row0(mon, r, W, bBg)
                local u1 = upgs[i]
                local n1 = tostring(u1.name  or '?'):sub(1, colW - 5)
                local l1 = tostring(u1.level or '')
                put(mon, 1, r, ' ' .. n1, bBg, tc.fg)
                if #l1 > 0 then
                    put(mon, colW - #l1, r, l1, bBg, colors.yellow)
                end
                if twoCol and upgs[i + 1] then
                    local u2 = upgs[i + 1]
                    local n2 = tostring(u2.name  or '?'):sub(1, colW - 5)
                    local l2 = tostring(u2.level or '')
                    put(mon, colW + 1, r, ' ' .. n2, bBg, tc.fg)
                    if #l2 > 0 then
                        put(mon, W - #l2 + 1, r, l2, bBg, colors.yellow)
                    end
                    i = i + 2
                else
                    i = i + 1
                end
                r = r + 1
            end
        end
    end

    -- Fill any remaining rows with black
    while r <= mh do
        row0(mon, r, W, colors.black)
        r = r + 1
    end
end

-- Draw the animated cooling fan frame onto the monitor.
-- Call this every animation tick (independent of drawStats).
-- data fields: coolingLevel (int), netTemp (int), thermalShutoff (bool), theme (str|nil)
-- Returns the next fanIdx to pass on the following call.
function MonitorUI.drawFan(mon, mw, mh, data, fanIdx)
    if not FRAMES then return fanIdx end
    local fCols, fRows = FRAMES.cols, FRAMES.rows
    local n          = #FRAMES.frames
    local coolLv     = data.coolingLevel or 0
    local hasCooling = coolLv > 0
    local nt         = data.netTemp or 0
    local shutoff    = data.thermalShutoff or false
    local tc         = (data.theme and THEME_COLORS[data.theme])
                       or { fg = colors.white, hdr = colors.red }

    -- Temperature-mapped colour (mirrors the Opus UI.Fan widget palette)
    local fanCol
    if not hasCooling then
        fanCol = colors.gray
    elseif shutoff or nt >= 280 then
        fanCol = colors.red
    elseif nt >= 220 then
        fanCol = colors.orange
    elseif nt >= 160 then
        fanCol = colors.yellow
    elseif nt >= 110 then
        fanCol = colors.lime
    elseif nt >= 70 then
        fanCol = colors.cyan
    elseif nt >= 40 then
        fanCol = colors.lightBlue
    else
        fanCol = colors.white
    end

    -- Always bottom-right corner; bail if monitor too narrow to fit side-by-side
    if mw <= fCols + 6 then return fanIdx end
    local ox = mw - fCols + 1
    local oy = mh - fRows - 1  -- header at oy, frames oy+1..oy+fRows, badge oy+fRows+1

    -- Opus-style header strip (matches the panel headers in drawStats)
    fill(mon, ox, oy, fCols, tc.hdr)
    local hdrText = hasCooling and ' COOLING FAN ' or '     FAN     '
    local hx = ox + math.max(0, math.floor((fCols - #hdrText) / 2))
    put(mon, hx, oy, hdrText, tc.hdr, colors.white, fCols - (hx - ox))
    oy = oy + 1

    -- Fan frame (teletext block characters, single foreground colour)
    local frame = FRAMES.frames[fanIdx]
    mon.setBackgroundColor(colors.black)
    mon.setTextColor(fanCol)
    for r = 1, #frame do
        local row = oy + r - 1
        if row <= mh then
            mon.setCursorPos(ox, row)
            mon.write(frame[r])
        end
    end

    -- Status badge below the frame
    local labelY = oy + fRows
    if labelY <= mh then
        local badge = hasCooling
            and string.format(' Lv%-2d SPINNING ', coolLv)
            or  '      IDLE      '
        badge = badge:sub(1, fCols)
        if #badge < fCols then badge = badge .. string.rep(' ', fCols - #badge) end
        fill(mon, ox, labelY, fCols, colors.gray)
        put(mon, ox, labelY, badge, colors.gray, fanCol, fCols)
    end

    if hasCooling then
        fanIdx = fanIdx % n + 1
    end
    return fanIdx
end

return MonitorUI
