-- AmiCoin Gauge Widget
-- Horizontal bar with sub-character precision and tier colors

local class  = require('ami.lib.ui.class')
local UI     = require('ami.lib.ui.ui')
local Glyphs = require('ami.lib.ui.glyphs')
local Theme  = require('ami.lib.ui.theme')

local colors = _G.colors

UI.Gauge = class(UI.Window)
UI.Gauge.defaults = {
    UIElement = 'Gauge',
    width = 20,
    height = 1,
    value = 0,
    max = 100,
    label = '',
    showLabel = true,
    showValue = true,
    -- Tier thresholds (percent)
    tierLow = 33,
    tierMid = 66,
    tierHigh = 90,
    -- Tier colors (override these per instance if needed)
    colorLow = colors.lime,      -- <33%
    colorMid = colors.yellow,    -- 33-66%
    colorHigh = colors.orange,   -- 66-90%
    colorCrit = colors.red,      -- >90%
    backgroundColor = colors.black,
    borderColor = nil,  -- nil = no border
}

function UI.Gauge:postInit()
    self.value = math.max(0, math.min(self.max, self.value))
end

function UI.Gauge:setValue(v)
    self.value = math.max(0, math.min(self.max, v))
    self:draw()
end

function UI.Gauge:setMax(m)
    if m <= 0 then
        error("Max must be positive", 2)
    end
    self.max = m
    self.value = math.min(self.value, self.max)
    self:draw()
end

function UI.Gauge:setTier(percent, color)
    -- Custom tier override
    if percent < self.tierLow then
        self.colorLow = color
    elseif percent < self.tierMid then
        self.colorMid = color
    elseif percent < self.tierHigh then
        self.colorHigh = color
    else
        self.colorCrit = color
    end
end

function UI.Gauge:getBarColor()
    local percent = (self.value / self.max) * 100
    if percent >= self.tierHigh then
        return self.colorCrit
    elseif percent >= self.tierMid then
        return self.colorHigh
    elseif percent >= self.tierLow then
        return self.colorMid
    else
        return self.colorLow
    end
end

function UI.Gauge:draw()
    -- Clear background
    self:clear(self.backgroundColor)
    
    local barWidth = self.width
    local barY = 1
    
    -- Adjust for label
    if self.showLabel and self.label ~= '' then
        self:write(1, barY, self.label, self.backgroundColor, Theme.getColor('textDim'))
        barY = barY + 1
        if self.height > 1 then
            barWidth = self.width
        end
    end
    
    -- Calculate fill percentage
    local fillPercent = (self.value / self.max) * 100
    local barColor = self:getBarColor()
    
    -- Draw border if enabled
    local innerWidth = barWidth
    local barX = 1
    if self.borderColor then
        -- Top border
        self:write(1, barY, Glyphs.BOX_TL .. string.rep(Glyphs.BOX_H, barWidth - 2) .. Glyphs.BOX_TR,
            self.backgroundColor, self.borderColor)
        barY = barY + 1
        barX = 2
        innerWidth = barWidth - 2
    end
    
    -- Build the bar using blocks
    local filledChars = math.floor((fillPercent / 100) * innerWidth)
    local bar = string.rep(Glyphs.BLOCK_FULL, filledChars)
    local emptyChars = innerWidth - filledChars
    if emptyChars > 0 then
        bar = bar .. string.rep(" ", emptyChars)
    end
    
    -- Draw the bar
    if self.borderColor then
        self:write(1, barY, Glyphs.BOX_V, self.backgroundColor, self.borderColor)
        self:write(2, barY, bar, self.backgroundColor, barColor)
        self:write(barWidth, barY, Glyphs.BOX_V, self.backgroundColor, self.borderColor)
        barY = barY + 1
        -- Bottom border
        self:write(1, barY, Glyphs.BOX_BL .. string.rep(Glyphs.BOX_H, barWidth - 2) .. Glyphs.BOX_BR,
            self.backgroundColor, self.borderColor)
    else
        self:write(barX, barY, bar, self.backgroundColor, barColor)
    end
    
    -- Draw value text if enabled
    if self.showValue then
        local valueText = string.format("%d/%d", self.value, self.max)
        local textX = math.floor((self.width - #valueText) / 2) + 1
        local textY = self.borderColor and 2 or 1
        if self.showLabel and self.label ~= '' then
            textY = textY + 1
        end
        self:write(textX, textY, valueText, barColor, Theme.getColor('text'))
    end
end

return UI.Gauge
