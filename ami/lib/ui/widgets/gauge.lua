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

    local barY = 1

    -- Optional label on its own line above the bar.
    if self.showLabel and self.label ~= '' then
        self:write(1, barY, self.label, self.backgroundColor, Theme.getColor('textDim'))
        barY = barY + 1
    end

    local barColor   = self:getBarColor()
    local trackColor = Theme.getColor('panel') or colors.gray
    local barWidth   = self.width

    -- ── Solid bar via space + BACKGROUND color (the CC-native technique). ──
    -- CC:Tweaked's font has NO CP437 block glyph at 219; a space painted with a
    -- background colour is the only reliable way to fill a cell solidly. A single
    -- left-half teletext block (char 149 = TL+ML+BL) gives one extra sub-cell of
    -- precision for the fractional cell.
    local exact   = (self.value / self.max) * barWidth      -- fractional cells
    local full    = math.floor(exact)
    local frac    = exact - full
    if full > barWidth then full = barWidth end

    -- Empty track across the whole width first.
    self:write(1, barY, string.rep(' ', barWidth), trackColor)
    -- Solid filled portion.
    if full > 0 then
        self:write(1, barY, string.rep(' ', full), barColor)
    end
    -- Half-cell for the fractional remainder (left-half block in barColor).
    if frac >= 0.5 and full < barWidth then
        self:write(full + 1, barY, string.char(149), trackColor, barColor)
    end

    -- ── Centered value text, split at the fill boundary for readability. ──
    if self.showValue then
        local valueText = string.format("%d/%d", self.value, self.max)
        local startX    = math.floor((barWidth - #valueText) / 2) + 1
        for i = 1, #valueText do
            local cx   = startX + i - 1
            if cx >= 1 and cx <= barWidth then
                local ch   = valueText:sub(i, i)
                local onFill = cx <= full
                local bg   = onFill and barColor or trackColor
                local fg   = onFill and colors.black or colors.white
                self:write(cx, barY, ch, bg, fg)
            end
        end
    end
end

return UI.Gauge
