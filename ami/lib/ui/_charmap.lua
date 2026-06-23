-- Character Map Browser for CC:Tweaked
-- Displays all 256 glyphs in the CC font
-- This is a dev tool to verify the glyph map for UI development

local function drawCharMap()
    local w, h = term.getSize()
    term.clear()
    term.setCursorPos(1, 1)
    
    -- Title
    term.setTextColor(colors.yellow)
    print("CC:Tweaked Character Map")
    print(string.rep("-", w))
    term.setTextColor(colors.white)
    
    local startRow = 3
    local charsPerRow = 16
    local currentChar = 0
    
    -- Draw 16x16 grid of characters
    for row = 0, 15 do
        term.setCursorPos(1, startRow + row * 2)
        
        -- Character row
        term.setTextColor(colors.gray)
        term.write(string.format("%02X: ", row * 16))
        term.setTextColor(colors.white)
        
        for col = 0, 15 do
            local charCode = row * 16 + col
            term.write(string.char(charCode) .. " ")
        end
        
        -- Hex codes row
        term.setCursorPos(1, startRow + row * 2 + 1)
        term.write("    ")
        term.setTextColor(colors.lightGray)
        for col = 0, 15 do
            local charCode = row * 16 + col
            term.write(string.format("%02X", charCode))
        end
        term.setTextColor(colors.white)
    end
    
    -- Instructions
    term.setCursorPos(1, h - 1)
    term.setTextColor(colors.lime)
    print("\nPress any key to exit...")
    term.setTextColor(colors.white)
end

-- Main
local function main()
    if not term.isColor() then
        print("This program requires an Advanced Computer/Monitor")
        return
    end
    
    drawCharMap()
    os.pullEvent("key")
    term.clear()
    term.setCursorPos(1, 1)
end

main()
