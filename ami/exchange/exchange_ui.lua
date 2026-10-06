-- /ami/exchange/exchange_ui.lua
-- The Great Ami Exchange v1.0 — status board
-- Renders onto the Advanced Monitor attached to TOP (any size).
-- All drawing calls are gated: if no monitor is attached, functions no-op.
--
-- Exported API:
--   ui.init(monitor)
--   ui.draw(state)   — state = { name, rate, reserve, open, reason, status }

local ui = {}

-- ── Owned state ───────────────────────────────────────────────────────────────
local mon  = nil
local W, H = 51, 19   -- updated after init

-- ── Colour palette (red / orange / gray theme, matches AmiStore) ──────────────
local BG      = colors.black
local HDR_BG  = colors.gray
local TITLE   = colors.orange
local PRICE_C = colors.yellow
local DIM     = colors.lightGray
local GOOD    = colors.green
local BAD     = colors.red

-- ── Primitives ────────────────────────────────────────────────────────────────
local function center(y, text, fg, bg)
    if not mon or y < 1 or y > H then return end
    text = text:sub(1, W)
    mon.setBackgroundColor(bg or BG)
    mon.setTextColor(fg or colors.white)
    mon.setCursorPos(math.floor((W - #text) / 2) + 1, y)
    mon.write(text)
end

function ui.init(monitor)
    mon = monitor
    if not mon then return end
    mon.setTextScale(1)
    W, H = mon.getSize()
end

function ui.draw(state)
    if not mon then return end
    W, H = mon.getSize()
    mon.setBackgroundColor(BG)
    mon.clear()

    mon.setBackgroundColor(HDR_BG)
    mon.setCursorPos(1, 1); mon.write(string.rep(" ", W))
    center(1, state.name, TITLE, HDR_BG)

    center(3, string.format("1 coin = %d uAMI", state.rate), PRICE_C)
    center(4, string.format("(%.6f AMI)", state.rate / 1000000), DIM)
    center(6, string.format("Reserve: %.4f AMI", state.reserve / 1000000), colors.white)

    if state.open then
        center(8, "OPEN", GOOD)
        center(9, "Buy and sell at the terminal", DIM)
    else
        center(8, "CLOSED", BAD)
        center(9, state.reason or "", DIM)
    end
    if state.status then
        center(11, state.status, PRICE_C)
    end
end

return ui
