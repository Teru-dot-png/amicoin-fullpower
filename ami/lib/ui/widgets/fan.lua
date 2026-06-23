-- AmiCoin Fan Widget (pre-rendered)
-- Plays baked ASCII frames from fan_frames.lua. No runtime trig; each frame is
-- blitted one row-string at a time (rows = #writes/frame) at ~1 fps. This is the
-- budget-safe replacement for the old live parametric renderer, which blew
-- CC:Tweaked's "too long without yielding" limit doing ~150 cell-writes/frame.
--
-- Regenerate frames with: python3 tools/gen_fan_frames.py

local class  = require('ami.lib.ui.class')
local UI     = require('ami.lib.ui.ui')
local Theme  = require('ami.lib.ui.theme')
local FRAMES = require('ami.lib.ui.widgets.fan_frames')

local colors = _G.colors
local os     = _G.os
local math   = _G.math

UI.Fan = class(UI.Window)
UI.Fan.defaults = {
    UIElement       = 'Fan',
    width           = FRAMES.cols,
    height          = FRAMES.rows,
    spinning        = false,
    level           = 1,          -- Air cooler level (1-10); sets spin speed
    color           = colors.lightGray,
    backgroundColor = colors.black,
    frameIndex      = 1,
    interval        = 1.0,        -- seconds per frame (set by setLevel)
    direction       = 1,          -- +1 forward, -1 reverse
}

function UI.Fan:postInit()
    self.timerId = nil
    self:setLevel(self.level)
    if self.spinning then
        self:start()
    end
end

-- Higher cooler level => faster spin (shorter interval). Base ~1 fps.
function UI.Fan:setLevel(level)
    level = math.max(1, math.min(10, level or 1))
    self.level = level
    self.interval = math.max(0.45, 1.05 - (level - 1) * 0.06)
    if self.spinning then
        self:renderFrame()
    end
end

function UI.Fan:setDirection(dir)
    self.direction = (dir >= 0) and 1 or -1
end

function UI.Fan:start()
    self.spinning = true
    self:renderFrame()
    self:scheduleNextFrame()
end

function UI.Fan:stop()
    self.spinning = false
    self.timerId = nil
    self:renderFrame()  -- draw the dimmed, stopped frame
end

function UI.Fan:scheduleNextFrame()
    if not self.spinning then return end
    self.timerId = os.startTimer(self.interval)
end

function UI.Fan:eventHandler(event)
    if event.type == 'timer' and event.timerId == self.timerId then
        if self.spinning then
            local n = #FRAMES.frames
            self.frameIndex = (self.frameIndex - 1 + self.direction) % n + 1
            self:renderFrame()
            self:scheduleNextFrame()
        end
        return true
    end
    return false
end

function UI.Fan:renderFrame()
    local frame = FRAMES.frames[self.frameIndex] or FRAMES.frames[1]
    local fg = self.spinning and self.color or Theme.getColor('textDim')
    self:clear(self.backgroundColor)
    for r = 1, #frame do
        self:write(1, r, frame[r], self.backgroundColor, fg)
    end
end

function UI.Fan:enable()
    UI.Window.enable(self)
    if self.spinning then
        self:scheduleNextFrame()
    end
end

function UI.Fan:disable()
    self.timerId = nil
    UI.Window.disable(self)
end

return UI.Fan
