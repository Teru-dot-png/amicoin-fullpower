-- AmiCoin Fan Widget
-- Animated 3-blade cooling fan using block glyphs

local class  = require('ami.lib.ui.class')
local UI     = require('ami.lib.ui.ui')
local Glyphs = require('ami.lib.ui.glyphs')
local Theme  = require('ami.lib.ui.theme')

local colors = _G.colors
local os     = _G.os

UI.Fan = class(UI.Window)
UI.Fan.defaults = {
    UIElement = 'Fan',
    width = 3,
    height = 3,
    spinning = false,
    fps = 5,  -- Frames per second
    color = colors.lightGray,
    backgroundColor = colors.black,
}

function UI.Fan:postInit()
    self.frameIndex = 1
    self.timerId = nil
    self.lastUpdate = 0
    
    if self.spinning then
        self:start()
    end
end

function UI.Fan:start()
    self.spinning = true
    self.lastUpdate = os.epoch("utc")
    -- Timer will be started by the event loop
    self:scheduleNextFrame()
end

function UI.Fan:stop()
    self.spinning = false
    if self.timerId then
        -- Timer will naturally expire, no need to cancel
        self.timerId = nil
    end
    self:draw()
end

function UI.Fan:setSpeed(fps)
    self.fps = math.max(1, math.min(30, fps))  -- Clamp to 1-30 FPS
end

function UI.Fan:scheduleNextFrame()
    if not self.spinning then return end
    
    local interval = 1.0 / self.fps
    self.timerId = os.startTimer(interval)
end

function UI.Fan:eventHandler(event)
    if event.type == 'timer' and event.timerId == self.timerId then
        if self.spinning then
            self.frameIndex = (self.frameIndex % 4) + 1
            self:draw()
            self:scheduleNextFrame()
        end
        return true
    end
    return false
end

function UI.Fan:draw()
    -- Clear background
    self:clear(self.backgroundColor)
    
    if not self.spinning then
        -- Show static fan (stopped)
        local cx, cy = math.floor(self.width / 2) + 1, math.floor(self.height / 2) + 1
        self:write(cx, cy, Glyphs.FAN_FRAME_1, self.backgroundColor, Theme.getColor('textDim'))
        return
    end
    
    -- Draw rotating fan blade
    local fanGlyph = Glyphs.getFanFrame(self.frameIndex)
    local cx, cy = math.floor(self.width / 2) + 1, math.floor(self.height / 2) + 1
    self:write(cx, cy, fanGlyph, self.backgroundColor, self.color)
end

function UI.Fan:enable()
    UI.Window.enable(self)
    if self.spinning then
        self:scheduleNextFrame()
    end
end

function UI.Fan:disable()
    if self.timerId then
        -- Let timer expire naturally
        self.timerId = nil
    end
    UI.Window.disable(self)
end

return UI.Fan
