-- AmiCoin Named Glyph Map
-- Reference for CC:Tweaked's font (verified against the real term_font.png via
-- tools/cc_glyphs/decode_font.py).
--
-- IMPORTANT - CC:Tweaked's font is NOT CP437:
--   * 0-31   : special glyphs (smileys, card suits, arrows, music) - CP437-like, VALID.
--   * 32-126 : standard ASCII - VALID.
--   * 128-159: 2x3 "teletext" sextant blocks (the ONLY real drawing glyphs).
--   * Box-drawing (CP437 179/196/218...) and block/shade (219/176-178) DO NOT
--     exist - those code points render as garbage letters. Use teletext blocks,
--     or paint a SPACE with a background colour for solid fills.
-- CRITICAL: Always use string.char(code) - never literal high-byte characters.

local colors = _G.colors

local Glyphs = {}

-------------------------------------------
-- TELETEXT 2x3 BLOCKS (codes 128-159) - the real CC drawing glyphs.
-- Sub-pixel layout per char cell (2 wide x 3 tall):
--     TL(1)  TR(2)
--     ML(4)  MR(8)
--     BL(16) BR(via fg/bg colour-swap)
--   code = 128 + TL*1 + TR*2 + ML*4 + MR*8 + BL*16     (BR is NOT a code bit)
-------------------------------------------
-- Box-drawing approximations built from teletext (CC has no CP437 box chars):
Glyphs.BOX_H          = string.char(140)  -- middle horizontal bar (ML+MR)
Glyphs.BOX_V          = string.char(149)  -- left vertical bar (TL+ML+BL)
Glyphs.BOX_TL         = string.char(140)  -- no true corner; reuse H-bar
Glyphs.BOX_TR         = string.char(140)
Glyphs.BOX_BL         = string.char(140)
Glyphs.BOX_BR         = string.char(140)
Glyphs.BOX_CROSS      = string.char(159)  -- densest block as a junction
Glyphs.BOX_T_DOWN     = string.char(140)
Glyphs.BOX_T_UP       = string.char(140)
Glyphs.BOX_T_RIGHT    = string.char(149)
Glyphs.BOX_T_LEFT     = string.char(149)

-- Double / mixed box variants don't exist in CC; alias to the approximations.
Glyphs.BOX_DOUBLE_TL  = Glyphs.BOX_TL
Glyphs.BOX_DOUBLE_TR  = Glyphs.BOX_TR
Glyphs.BOX_DOUBLE_BL  = Glyphs.BOX_BL
Glyphs.BOX_DOUBLE_BR  = Glyphs.BOX_BR
Glyphs.BOX_DOUBLE_H   = Glyphs.BOX_H
Glyphs.BOX_DOUBLE_V   = Glyphs.BOX_V
Glyphs.BOX_MIX_TL     = Glyphs.BOX_TL
Glyphs.BOX_MIX_TR     = Glyphs.BOX_TR
Glyphs.BOX_MIX_BL     = Glyphs.BOX_BL
Glyphs.BOX_MIX_BR     = Glyphs.BOX_BR

-------------------------------------------
-- BLOCKS / SHADES (CC has no CP437 blocks; use teletext or space+bg)
-- The fullest single foreground glyph is 159 (~5/6 filled). For a truly solid
-- cell, paint a SPACE with the desired BACKGROUND colour instead.
-------------------------------------------
Glyphs.BLOCK_FULL     = string.char(159)  -- densest fg glyph (TL+TR+ML+MR+BL)
Glyphs.BLOCK_BOTTOM   = string.char(151)  -- bottom-ish (ML+MR+BL + top) approx
Glyphs.BLOCK_LEFT     = string.char(149)  -- left half (TL+ML+BL)
Glyphs.BLOCK_RIGHT    = string.char(154)  -- right half (TR+MR) approx
Glyphs.BLOCK_TOP      = string.char(131)  -- top third (TL+TR)

-- "Shades" approximated with teletext density (no true CP437 shades in CC).
Glyphs.SHADE_LIGHT    = string.char(129)  -- sparse (TL only)
Glyphs.SHADE_MEDIUM   = string.char(137)  -- TL+MR diagonal-ish
Glyphs.SHADE_DARK     = string.char(151)  -- dense (TL+TR+ML+MR + ...)

-------------------------------------------
-- 2x3 TELETEXT BLOCKS (128-159)
-- bit order: 0x01=TL, 0x02=TR, 0x04=ML, 0x08=MR, 0x10=BL  (BR via colour-swap)
-------------------------------------------
Glyphs.TELETEXT = {}
-- Map a 5-bit pattern (0-31) to its char code (128-159).
local function buildTeletextMap()
    local map = {}
    for i = 0, 31 do
        map[i] = string.char(128 + i)
    end
    return map
end
Glyphs.TELETEXT.map = buildTeletextMap()

-- Common 2x3 patterns (BR pixel needs a fg/bg swap; not encodable as a code).
Glyphs.TELETEXT_EMPTY      = Glyphs.TELETEXT.map[0]      -- all off (space-like)
Glyphs.TELETEXT_FULL       = Glyphs.TELETEXT.map[31]     -- 0x1F densest (BR off)
Glyphs.TELETEXT_TOP_LEFT   = Glyphs.TELETEXT.map[1]      -- 0x01
Glyphs.TELETEXT_TOP_RIGHT  = Glyphs.TELETEXT.map[2]      -- 0x02
Glyphs.TELETEXT_TOP_HALF   = Glyphs.TELETEXT.map[3]      -- 0x03 (TL+TR)
Glyphs.TELETEXT_BOT_LEFT   = Glyphs.TELETEXT.map[16]     -- 0x10
Glyphs.TELETEXT_BOT_RIGHT  = Glyphs.TELETEXT.map[0]      -- BR not codable; see swap
Glyphs.TELETEXT_BOT_HALF   = Glyphs.TELETEXT.map[16]     -- 0x10 (BL; BR via swap)
Glyphs.TELETEXT_LEFT_FULL  = Glyphs.TELETEXT.map[21]     -- 0x15 (TL+ML+BL)
Glyphs.TELETEXT_RIGHT_FULL = Glyphs.TELETEXT.map[10]     -- 0x0A (TR+MR; BR via swap)

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
Glyphs.MULTIPLY       = "x"                -- CC has no x glyph; use ASCII
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
-- FAN ANIMATION FRAMES (legacy; the live fan now uses baked fan_frames.lua)
-- Simple ASCII spinner - guaranteed to render on any CC font.
-------------------------------------------
Glyphs.FAN_FRAME_1    = "|"   -- vertical
Glyphs.FAN_FRAME_2    = "/"   -- diagonal
Glyphs.FAN_FRAME_3    = "-"   -- horizontal
Glyphs.FAN_FRAME_4    = "\\"  -- diagonal

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
-- @param pattern number Bit pattern (0-31): TL1 TR2 ML4 MR8 BL16 (BR via swap)
-- @return string Glyph character (codes 128-159)
function Glyphs.getTeletextBlock(pattern)
    if pattern < 0 or pattern > 31 then
        error("Teletext pattern must be 0-31 (BR pixel needs a fg/bg swap)", 2)
    end
    return Glyphs.TELETEXT.map[pattern]
end

--- Build a horizontal bar string (drawn in the bar colour as foreground).
-- For a crisp SOLID bar prefer painting spaces with a background colour; this
-- helper returns the densest fg glyph (159) for the filled part.
-- @param fillPercent number Fill percentage (0-100)
-- @param width number Width in characters
-- @return string String of block characters
function Glyphs.buildBar(fillPercent, width)
    local filled = math.floor((fillPercent / 100) * width)
    local bar = string.rep(string.char(159), filled)
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
