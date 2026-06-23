-- AmiCoin Card Widget
-- Playing card face for Blackjack/Poker/Higher-Lower

local class  = require('ami.lib.ui.class')
local UI     = require('ami.lib.ui.ui')
local Glyphs = require('ami.lib.ui.glyphs')
local Theme  = require('ami.lib.ui.theme')

local colors = _G.colors

UI.Card = class(UI.Window)
UI.Card.defaults = {
    UIElement = 'Card',
    width = 7,
    height = 5,
    suit = 'spade',  -- 'spade', 'heart', 'diamond', 'club'
    rank = 'A',      -- 'A', '2'-'10', 'J', 'Q', 'K'
    faceUp = true,
    backgroundColor = colors.black,
    cardColor = colors.white,
    backColor = colors.blue,
    backPattern = colors.lightBlue,
}

function UI.Card:postInit()
    self.suit = self.suit:lower()
    self.animating = false
end

function UI.Card:flip()
    self.faceUp = not self.faceUp
    self:draw()
end

function UI.Card:setSuit(suit)
    self.suit = suit:lower()
    if self.faceUp then
        self:draw()
    end
end

function UI.Card:setRank(rank)
    self.rank = tostring(rank):upper()
    if self.faceUp then
        self:draw()
    end
end

function UI.Card:setCard(suit, rank)
    self.suit = suit:lower()
    self.rank = tostring(rank):upper()
    if self.faceUp then
        self:draw()
    end
end

function UI.Card:draw()
    -- Clear background
    self:clear(self.backgroundColor)
    
    if not self.faceUp then
        self:drawBack()
    else
        self:drawFace()
    end
end

function UI.Card:drawBack()
    -- Draw card back (face-down)
    -- Border
    self:write(1, 1, Glyphs.BOX_TL .. string.rep(Glyphs.BOX_H, self.width - 2) .. Glyphs.BOX_TR,
        self.backColor, self.backPattern)
    for y = 2, self.height - 1 do
        self:write(1, y, Glyphs.BOX_V .. string.rep(Glyphs.SHADE_MEDIUM, self.width - 2) .. Glyphs.BOX_V,
            self.backColor, self.backPattern)
    end
    self:write(1, self.height, Glyphs.BOX_BL .. string.rep(Glyphs.BOX_H, self.width - 2) .. Glyphs.BOX_BR,
        self.backColor, self.backPattern)
end

function UI.Card:drawFace()
    -- Draw card face (face-up)
    local suitGlyph = Glyphs.getCardSuit(self.suit)
    local suitColor = Glyphs.getCardSuitColor(self.suit)
    
    -- Border
    self:write(1, 1, Glyphs.BOX_TL .. string.rep(Glyphs.BOX_H, self.width - 2) .. Glyphs.BOX_TR,
        self.cardColor, colors.black)
    for y = 2, self.height - 1 do
        self:write(1, y, Glyphs.BOX_V .. string.rep(" ", self.width - 2) .. Glyphs.BOX_V,
            self.cardColor, colors.black)
    end
    self:write(1, self.height, Glyphs.BOX_BL .. string.rep(Glyphs.BOX_H, self.width - 2) .. Glyphs.BOX_BR,
        self.cardColor, colors.black)
    
    -- Rank in top-left
    local rankText = self.rank
    if #rankText == 1 then
        rankText = " " .. rankText
    end
    self:write(2, 2, rankText, self.cardColor, suitColor)
    
    -- Suit in center
    local cx = math.floor(self.width / 2) + 1
    local cy = math.floor(self.height / 2) + 1
    self:write(cx, cy, suitGlyph, self.cardColor, suitColor)
    
    -- Rank in bottom-right (upside-down effect)
    local bottomRank = self.rank
    if #bottomRank == 1 then
        bottomRank = bottomRank .. " "
    end
    self:write(self.width - #bottomRank, self.height - 1, bottomRank, self.cardColor, suitColor)
end

--- Animate card flip (future enhancement - needs timer support)
function UI.Card:animateFlip(callback)
    -- TODO: Multi-frame flip animation
    -- For now, just immediate flip
    self:flip()
    if callback then
        callback()
    end
end

return UI.Card
