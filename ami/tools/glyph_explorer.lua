-- ami/tools/glyph_explorer.lua
-- CC:Tweaked on-computer glyph explorer.
--
-- Browse all 256 font characters live on the terminal so you can SEE which
-- glyphs actually render (CC's font is NOT CP437) and screenshot them to share.
-- Big sample of the highlighted glyph, plus its decimal/hex code and 2x3
-- teletext bit breakdown when applicable.
--
-- Install/run on a CC computer:
--   pastebin or wget this file, then: glyph_explorer
--
-- Controls:
--   Arrow keys / WASD : move the cursor in the 16x16 grid
--   PageUp / PageDown : jump 16 (a full row)
--   G                 : type a code (0-255) to jump to it
--   T                 : toggle teletext-only filter (128-159)
--   Q / Escape        : quit

local W, H = term.getSize()

local function clamp(v, lo, hi) return math.max(lo, math.min(hi, v)) end

-- Draw a large preview of one glyph by sampling -- we can't scale the font, so
-- instead we show the single char big-ish by surrounding it and listing facts.
local function teletextBits(code)
    if code < 128 or code > 159 then return nil end
    local b = code - 128
    return {
        TL = (b % 2 >= 1),
        TR = (math.floor(b / 2) % 2 >= 1),
        ML = (math.floor(b / 4) % 2 >= 1),
        MR = (math.floor(b / 8) % 2 >= 1),
        BL = (math.floor(b / 16) % 2 >= 1),
        -- BR via colour swap, not encodable
    }
end

local sel = 65          -- start on 'A'
local teletextOnly = false

local function draw()
    term.setBackgroundColor(colors.black)
    term.clear()

    -- Title bar
    term.setBackgroundColor(colors.red)
    term.setTextColor(colors.white)
    term.setCursorPos(1, 1)
    term.clearLine()
    term.setCursorPos(2, 1)
    term.write("CC Glyph Explorer")
    term.setBackgroundColor(colors.black)

    -- 16x16 grid of all glyphs (each cell shows the raw char).
    local gx, gy = 2, 3
    for code = 0, 255 do
        local col = code % 16
        local row = math.floor(code / 16)
        local x = gx + col * 2
        local y = gy + row
        local dim = teletextOnly and not (code >= 128 and code <= 159)
        if code == sel then
            term.setBackgroundColor(colors.white)
            term.setTextColor(colors.black)
        elseif dim then
            term.setBackgroundColor(colors.black)
            term.setTextColor(colors.gray)
        else
            term.setBackgroundColor(colors.black)
            term.setTextColor(colors.lime)
        end
        term.setCursorPos(x, y)
        -- code 32 is space; show it as a dot placeholder unless selected
        if code == 0 then
            term.write(" ")
        else
            term.write(string.char(code))
        end
    end

    -- Right-hand info panel.
    local px = gx + 16 * 2 + 2
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
    term.setCursorPos(px, 3); term.write("Code: " .. sel)
    term.setCursorPos(px, 4); term.write(string.format("Hex : 0x%02X", sel))
    term.setCursorPos(px, 5)
    term.setTextColor(colors.yellow)
    term.write("Char: [")
    term.write(sel == 0 and " " or string.char(sel))
    term.write("]")

    -- Big-ish preview: repeat the glyph in a small block so it's screenshot-clear.
    term.setTextColor(colors.lime)
    for i = 0, 2 do
        term.setCursorPos(px, 7 + i)
        term.write(string.rep(sel == 0 and " " or string.char(sel), 6))
    end

    -- Teletext breakdown if applicable.
    local tb = teletextBits(sel)
    term.setTextColor(colors.lightGray)
    if tb then
        term.setCursorPos(px, 11); term.write("2x3 teletext:")
        local function cell(on) return on and string.char(159) or "." end
        term.setCursorPos(px, 12); term.write(" " .. cell(tb.TL) .. cell(tb.TR))
        term.setCursorPos(px, 13); term.write(" " .. cell(tb.ML) .. cell(tb.MR))
        term.setCursorPos(px, 14); term.write(" " .. cell(tb.BL) .. "?")
        term.setCursorPos(px, 15); term.write("(? = BR via")
        term.setCursorPos(px, 16); term.write(" colour swap)")
    else
        term.setCursorPos(px, 11)
        if sel >= 32 and sel < 127 then
            term.write("ASCII printable")
        elseif sel < 32 then
            term.write("Special (0-31)")
        else
            term.write("Extended glyph")
        end
    end

    -- Footer help.
    term.setBackgroundColor(colors.red)
    term.setTextColor(colors.white)
    term.setCursorPos(1, H)
    term.clearLine()
    term.setCursorPos(2, H)
    local mode = teletextOnly and "[T]ele:ON" or "[T]ele:off"
    term.write("Move:WASD/Arrows  [G]oto  " .. mode .. "  [Q]uit")
    term.setBackgroundColor(colors.black)
end

local function run()
    draw()
    while true do
        local ev, key = os.pullEvent()
        if ev == "key" then
            if key == keys.q or key == keys.escape then
                break
            elseif key == keys.left or key == keys.a then
                sel = clamp(sel - 1, 0, 255)
            elseif key == keys.right or key == keys.d then
                sel = clamp(sel + 1, 0, 255)
            elseif key == keys.up or key == keys.w then
                sel = clamp(sel - 16, 0, 255)
            elseif key == keys.down or key == keys.s then
                sel = clamp(sel + 16, 0, 255)
            elseif key == keys.pageUp then
                sel = clamp(sel - 16, 0, 255)
            elseif key == keys.pageDown then
                sel = clamp(sel + 16, 0, 255)
            elseif key == keys.t then
                teletextOnly = not teletextOnly
            elseif key == keys.g then
                -- prompt for a code
                term.setBackgroundColor(colors.black)
                term.setTextColor(colors.white)
                term.setCursorPos(2, H - 1)
                term.clearLine()
                term.write("Goto code (0-255): ")
                local input = read()
                local n = tonumber(input)
                if n then sel = clamp(math.floor(n), 0, 255) end
            end
            draw()
        end
    end
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
    term.clear()
    term.setCursorPos(1, 1)
    print("Glyph explorer closed. Selected code was " .. sel ..
          " (char '" .. (sel == 0 and " " or string.char(sel)) .. "').")
end

run()
