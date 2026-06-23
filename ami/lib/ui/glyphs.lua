-- AmiCoin Named Glyph Map
-- Comprehensive reference for CC:Tweaked's 256-character font
-- CRITICAL: Always use string.char(code) - never literal high-byte characters

local colors = _G.colors

local Glyphs = {}

-------------------------------------------
-- BOX DRAWING (192-218)
-------------------------------------------
Glyphs.BOX_TL         = string.char(218)  -- ┌ Top-left corner
Glyphs.BOX_TR         = string.char(191)  -- ┐ Top-right corner
Glyphs.BOX_BL         = string.char(192)  -- └ Bottom-left corner
Glyphs.BOX_BR         = string.char(217)  -- ┘ Bottom-right corner
Glyphs.BOX_H          = string.char(196)  -- ─ Horizontal line
Glyphs.BOX_V          = string.char(179)  -- │ Vertical line
Glyphs.BOX_CROSS      = string.char(197)  -- ┼ Four-way intersection
Glyphs.BOX_T_DOWN     = string.char(194)  -- ┬ T pointing down
Glyphs.BOX_T_UP       = string.char(193)  -- ┴ T pointing up
Glyphs.BOX_T_RIGHT    = string.char(195)  -- ├ T pointing right
Glyphs.BOX_T_LEFT     = string.char(180)  -- ┤ T pointing left

-- Double-line box drawing
Glyphs.BOX_DOUBLE_TL  = string.char(201)  -- ╔
Glyphs.BOX_DOUBLE_TR  = string.char(187)  -- ╗
Glyphs.BOX_DOUBLE_BL  = string.char(200)  -- ╚
Glyphs.BOX_DOUBLE_BR  = string.char(188)  -- ╝
Glyphs.BOX_DOUBLE_H   = string.char(205)  -- ═
Glyphs.BOX_DOUBLE_V   = string.char(186)  -- ║

-- Single vertical + double horizontal
Glyphs.BOX_MIX_TL     = string.char(214)  -- ╓
Glyphs.BOX_MIX_TR     = string.char(183)  -- ╖
Glyphs.BOX_MIX_BL     = string.char(211)  -- ╙
Glyphs.BOX_MIX_BR     = string.char(189)  -- ╜

-------------------------------------------
-- BLOCKS (176-178, 219-223)
-------------------------------------------
Glyphs.SHADE_LIGHT    = string.char(176)  -- ░ Light shade
Glyphs.SHADE_MEDIUM   = string.char(177)  -- ▒ Medium shade
Glyphs.SHADE_DARK     = string.char(178)  -- ▓ Dark shade
Glyphs.BLOCK_FULL     = string.char(219)  -- █ Full block
Glyphs.BLOCK_BOTTOM   = string.char(220)  -- ▄ Bottom half
Glyphs.BLOCK_LEFT     = string.char(221)  -- ▌ Left half
Glyphs.BLOCK_RIGHT    = string.char(222)  -- ▐ Right half
Glyphs.BLOCK_TOP      = string.char(223)  -- ▀ Top half

-------------------------------------------
-- 2x3 TELETEXT BLOCKS (128-159)
-- Each glyph represents a 2x3 grid of subpixels
-- Bit pattern: top-left, top-right, mid-left, mid-right, bot-left, bot-right
-- (6th subpixel achieved via fg/bg color swap)
-------------------------------------------
Glyphs.TELETEXT = {}
-- Helper to build 2x3 block map (bit pattern to char code)
-- Bit order: 0x01=TL, 0x02=TR, 0x04=ML, 0x08=MR, 0x10=BL, 0x20=BR
local function buildTeletextMap()
    local map = {}
    for i = 0, 63 do
        -- Teletext block codes start at 128
        map[i] = string.char(128 + i)
    end
    return map
end
Glyphs.TELETEXT.map = buildTeletextMap()

-- Common 2x3 patterns
Glyphs.TELETEXT_EMPTY      = Glyphs.TELETEXT.map[0]      -- All off
Glyphs.TELETEXT_FULL       = Glyphs.TELETEXT.map[63]     -- All on (0x3F)
Glyphs.TELETEXT_TOP_LEFT   = Glyphs.TELETEXT.map[1]      -- 0x01
Glyphs.TELETEXT_TOP_RIGHT  = Glyphs.TELETEXT.map[2]      -- 0x02
Glyphs.TELETEXT_TOP_HALF   = Glyphs.TELETEXT.map[3]      -- 0x03
Glyphs.TELETEXT_BOT_LEFT   = Glyphs.TELETEXT.map[16]     -- 0x10
Glyphs.TELETEXT_BOT_RIGHT  = Glyphs.TELETEXT.map[32]     -- 0x20
Glyphs.TELETEXT_BOT_HALF   = Glyphs.TELETEXT.map[48]     -- 0x30
Glyphs.TELETEXT_LEFT_FULL  = Glyphs.TELETEXT.map[21]     -- 0x15 (TL+ML+BL)
Glyphs.TELETEXT_RIGHT_FULL = Glyphs.TELETEXT.map[42]     -- 0x2A (TR+MR+BR)

-------------------------------------------
-- ARROWS (16-31)
-------------------------------------------
Glyphs.ARROW_RIGHT    = string.char(16)   -- ►
Glyphs.ARROW_LEFT     = string.char(17)   -- ◄
Glyphs.ARROW_UP       = string.char(24)   -- ↑
Glyphs.ARROW_DOWN     = string.char(25)   -- ↓
Glyphs.ARROW_UD       = string.char(18)   -- ↕ Up-down
Glyphs.ARROW_LR       = string.char(29)   -- ↔ Left-right
Glyphs.TRIANGLE_UP    = string.char(30)   -- ▲
Glyphs.TRIANGLE_DOWN  = string.char(31)   -- ▼
Glyphs.TRIANGLE_RIGHT = string.char(16)   -- Same as ARROW_RIGHT
Glyphs.TRIANGLE_LEFT  = string.char(17)   -- Same as ARROW_LEFT

-------------------------------------------
-- CARD SUITS (3-6)
-------------------------------------------
Glyphs.HEART          = string.char(3)    -- ♥
Glyphs.DIAMOND        = string.char(4)    -- ♦
Glyphs.CLUB           = string.char(5)    -- ♣
Glyphs.SPADE          = string.char(6)    -- ♠

-------------------------------------------
-- SYMBOLS (misc)
-------------------------------------------
Glyphs.DOT            = string.char(7)    -- • Small bullet
Glyphs.BULLET         = string.char(8)    -- ∙ Middle dot
Glyphs.CIRCLE_OPEN    = string.char(9)    -- ○ Open circle
Glyphs.DEGREE         = string.char(248)  -- °
Glyphs.PLUS_MINUS     = string.char(241)  -- ±
Glyphs.SECTION        = string.char(21)   -- §
Glyphs.PILCROW        = string.char(20)   -- ¶
Glyphs.NOTE_SINGLE    = string.char(13)   -- ♪
Glyphs.NOTE_DOUBLE    = string.char(14)   -- ♫
Glyphs.SUN            = string.char(15)   -- ☼
Glyphs.FEMALE         = string.char(12)   -- ♀
Glyphs.MALE           = string.char(11)   -- ♂
Glyphs.SMILEY         = string.char(1)    -- ☺
Glyphs.SMILEY_INV     = string.char(2)    -- ☻
Glyphs.SQUARE         = string.char(254)  -- ■ Small square
Glyphs.CHECKMARK      = string.char(251)  -- √
Glyphs.MULTIPLY       = string.char(158)  -- × Multiplication sign
Glyphs.DIVIDE         = string.char(246)  -- ÷

-------------------------------------------
-- CASINO-SPECIFIC GLYPHS
-------------------------------------------
Glyphs.DICE_1         = Glyphs.DOT        -- Reuse dot for single pip
Glyphs.DICE_2         = string.char(58)   -- : Two vertical pips
Glyphs.DICE_3         = string.char(133)  -- ‥ Three (use teletext)
Glyphs.DICE_4         = string.char(134)  -- Four pips (use teletext)
Glyphs.DICE_5         = string.char(135)  -- Five pips (use teletext)
Glyphs.DICE_6         = string.char(136)  -- Six pips (use teletext)

-- Coin/Currency
Glyphs.COIN           = string.char(9)    -- ○ Circle for coin
Glyphs.CROWN          = string.char(127)  -- ⌂ House/crown-like

-- Card ranks (ASCII)
Glyphs.CARD_A         = "A"
Glyphs.CARD_2         = "2"
Glyphs.CARD_3         = "3"
Glyphs.CARD_4         = "4"
Glyphs.CARD_5         = "5"
Glyphs.CARD_6         = "6"
Glyphs.CARD_7         = "7"
Glyphs.CARD_8         = "8"
Glyphs.CARD_9         = "9"
Glyphs.CARD_10        = "10"
Glyphs.CARD_J         = "J"
Glyphs.CARD_Q         = "Q"
Glyphs.CARD_K         = "K"

-------------------------------------------
-- FAN ANIMATION FRAMES
-- 3-blade rotating fan using block glyphs
-------------------------------------------
Glyphs.FAN_FRAME_1    = string.char(179)  -- │ Vertical
Glyphs.FAN_FRAME_2    = string.char(47)   -- / Diagonal 1
Glyphs.FAN_FRAME_3    = string.char(196)  -- ─ Horizontal
Glyphs.FAN_FRAME_4    = string.char(92)   -- \ Diagonal 2

-------------------------------------------
-- HELPER FUNCTIONS
-------------------------------------------

--- Render a glyph with colors for blit
-- @param glyph string The glyph character
-- @param fg number Foreground color
-- @param bg number Background color
-- @return string, string, string Char, fg blit char, bg blit char
function Glyphs.render(glyph, fg, bg)
    local fgChar = ("%x"):format(math.log(fg or colors.white) / math.log(2))
    local bgChar = ("%x"):format(math.log(bg or colors.black) / math.log(2))
    return glyph, fgChar, bgChar
end

--- Get a 2x3 teletext block by bit pattern
-- @param pattern number Bit pattern (0-63)
-- @return string Glyph character
function Glyphs.getTeletextBlock(pattern)
    if pattern < 0 or pattern > 63 then
        error("Teletext pattern must be 0-63", 2)
    end
    return Glyphs.TELETEXT.map[pattern]
end

--- Build a horizontal bar using block characters
-- @param fillPercent number Fill percentage (0-100)
-- @param width number Width in characters
-- @return string String of block characters
function Glyphs.buildBar(fillPercent, width)
    local filled = math.floor((fillPercent / 100) * width)
    local bar = string.rep(Glyphs.BLOCK_FULL, filled)
    local remaining = width - filled
    if remaining > 0 then
        bar = bar .. string.rep(" ", remaining)
    end
    return bar
end

--- Build a horizontal bar with sub-character precision using half-blocks
-- @param fillPercent number Fill percentage (0-100)
-- @param width number Width in characters
-- @return table Array of {char, needsSwap} for each position
function Glyphs.buildSubBar(fillPercent, width)
    local totalHalves = width * 2
    local filledHalves = math.floor((fillPercent / 100) * totalHalves)
    local result = {}
    
    for i = 1, width do
        local halvesInThisChar = math.min(2, math.max(0, filledHalves - (i - 1) * 2))
        if halvesInThisChar == 2 then
            result[i] = { char = Glyphs.BLOCK_FULL, needsSwap = false }
        elseif halvesInThisChar == 1 then
            result[i] = { char = Glyphs.BLOCK_LEFT, needsSwap = false }
        else
            result[i] = { char = " ", needsSwap = false }
        end
    end
    
    return result
end

--- Get card suit glyph
-- @param suit string "heart", "diamond", "club", or "spade"
-- @return string Suit glyph
function Glyphs.getCardSuit(suit)
    local suits = {
        heart = Glyphs.HEART,
        diamond = Glyphs.DIAMOND,
        club = Glyphs.CLUB,
        spade = Glyphs.SPADE,
        h = Glyphs.HEART,
        d = Glyphs.DIAMOND,
        c = Glyphs.CLUB,
        s = Glyphs.SPADE,
    }
    return suits[suit:lower()] or Glyphs.HEART
end

--- Get card suit color (red or black)
-- @param suit string "heart", "diamond", "club", or "spade"
-- @return number CC color
function Glyphs.getCardSuitColor(suit)
    local s = suit:lower()
    if s == "heart" or s == "h" or s == "diamond" or s == "d" then
        return colors.red
    else
        return colors.black
    end
end

--- Get fan frame for animation
-- @param frameIndex number Frame index (1-4)
-- @return string Fan glyph
function Glyphs.getFanFrame(frameIndex)
    local frames = {
        Glyphs.FAN_FRAME_1,
        Glyphs.FAN_FRAME_2,
        Glyphs.FAN_FRAME_3,
        Glyphs.FAN_FRAME_4,
    }
    return frames[((frameIndex - 1) % 4) + 1]
end

return Glyphs
