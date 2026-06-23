-- AmiCoin Parametric Fan Widget
-- Math-based sine-wave fan renderer with upgrade level scaling
-- Replaces simple 4-frame animation with continuous parametric rendering

local class  = require('ami.lib.ui.class')
local UI     = require('ami.lib.ui.ui')
local Theme  = require('ami.lib.ui.theme')

local colors = _G.colors
local os     = _G.os
local math   = _G.math

-------------------------------------------
-- UPGRADE PRESETS
-------------------------------------------
-- Each level defines blade count, radius, twist (spiral), and speed
local PRESETS = {
    [1]  = { blades = 2, radius = 4,  twist = 0.0,  speed = 1.0 },  -- Slow 2-blade
    [2]  = { blades = 3, radius = 4,  twist = 0.1,  speed = 1.2 },
    [3]  = { blades = 3, radius = 4,  twist = 0.15, speed = 1.4 },
    [4]  = { blades = 4, radius = 4,  twist = 0.2,  speed = 1.6 },
    [5]  = { blades = 4, radius = 4,  twist = 0.25, speed = 1.8 },  -- Mid-tier
    [6]  = { blades = 5, radius = 4, twist = 0.3,  speed = 2.0 },
    [7]  = { blades = 5, radius = 4, twist = 0.35, speed = 2.2 },
    [8]  = { blades = 6, radius = 4, twist = 0.4,  speed = 2.5 },
    [9]  = { blades = 6, radius = 4, twist = 0.45, speed = 2.8 },
    [10] = { blades = 7, radius = 4, twist = 0.5,  speed = 3.0 }, -- Max cooling
}

-------------------------------------------
-- WIDGET CLASS
-------------------------------------------
UI.Fan = class(UI.Window)
UI.Fan.defaults = {
    UIElement = 'Fan',
    width = 21,          -- Calculated: radius * 2 * ASPECT + 1 (for level 1: 5*2*2+1=21)
    height = 11,         -- Calculated: radius * 2 + 1 (for level 1: 5*2+1=11)
    spinning = false,
    fps = 5,             -- Render rate (low: a full repaint is ~150 cell-writes)
    level = 1,           -- Air cooler upgrade level (1-10)
    color = colors.lightGray,
    backgroundColor = colors.black,
    
    -- Internal state (set by preset)
    blades = 2,
    radius = 4,
    twist = 0.0,
    speed = 1.0,
    rotation = 0,
    direction = 1,       -- +1 = clockwise, -1 = counter-clockwise
}

function UI.Fan:postInit()
    self.timerId = nil
    
    -- Apply preset for initial level
    self:setLevel(self.level)
    
    if self.spinning then
        self:start()
    end
end

function UI.Fan:start()
    self.spinning = true
    self:renderFrame()
    self:scheduleNextFrame()
end

function UI.Fan:stop()
    self.spinning = false
    if self.timerId then
        self.timerId = nil
    end
    self:renderFrame()  -- Draw stopped state
end

function UI.Fan:setSpeed(fps)
    self.fps = math.max(1, math.min(60, fps))  -- Clamp to 1-60 FPS
end

function UI.Fan:setLevel(level)
    level = math.max(1, math.min(10, level or 1))
    local preset = PRESETS[level]
    
    self.level = level
    self.blades = preset.blades
    self.radius = preset.radius
    self.twist = preset.twist
    self.speed = preset.speed
    
    -- Recalculate dimensions (ASPECT = 2.0)
    local ASPECT = 2.0
    self.width = math.floor(self.radius * ASPECT * 2) + 1
    self.height = self.radius * 2 + 1
    
    if self.spinning then
        self:renderFrame()
    end
end

function UI.Fan:setDirection(dir)
    self.direction = (dir >= 0) and 1 or -1
end

function UI.Fan:scheduleNextFrame()
    if not self.spinning then return end
    
    local interval = 1.0 / self.fps
    self.timerId = os.startTimer(interval)
end

function UI.Fan:eventHandler(event)
    if event.type == 'timer' and event.timerId == self.timerId then
        if self.spinning then
            -- Increment rotation based on speed (radians per second)
            local dt = 1.0 / self.fps
            self.rotation = self.rotation + (self.direction * self.speed * dt)
            
            self:renderFrame()
            self:scheduleNextFrame()
        end
        return true
    end
    return false
end

-------------------------------------------
-- PARAMETRIC SINE-WAVE RENDERER
-------------------------------------------
function UI.Fan:renderFrame()
    local ASPECT = 2.0
    local RAMP = { 
        string.char(219),  -- █ full block
        string.char(178),  -- ▓ dark shade
        string.char(177),  -- ▒ medium shade
        string.char(176),  -- ░ light shade
        " "                -- air
    }
    
    local R = self.radius
    local cols = math.floor(R * ASPECT * 2) + 1
    local rows = R * 2 + 1
    local cx = (cols - 1) / 2
    local cy = (rows - 1) / 2
    
    -- Clear canvas
    self:clear(self.backgroundColor)
    
    for row = 0, rows - 1 do
        for col = 0, cols - 1 do
            local dx = (col - cx) / ASPECT
            local dy = (row - cy)
            local dist = math.sqrt(dx*dx + dy*dy)
            
            -- Outside disc
            if dist > R + 0.3 then
                -- Skip (already cleared)
            -- Hub (center)
            elseif dist < R * 0.1 then
                self:write(col + 1, row + 1, RAMP[1], self.backgroundColor, self.color)
            else
                -- Calculate angle and sine wave
                local angle = math.atan2(dy, dx)
                local s = math.sin(self.blades * angle + self.twist * dist + self.rotation)
                
                -- Map sine to shade index
                local idx
                if s > 0.55 then
                    idx = 1  -- Full block
                elseif s > 0.15 then
                    idx = 2  -- Dark shade
                elseif s > -0.2 then
                    idx = 3  -- Medium shade
                else
                    idx = 5  -- Air
                end
                
                -- Soften rim
                if dist > R * 0.92 and idx < 5 then
                    idx = idx + 1
                    if idx > 5 then idx = 5 end
                end
                
                -- Apply color only to solid parts when spinning
                local charColor = self.color
                if not self.spinning then
                    charColor = Theme.getColor('textDim')
                end
                
                if idx < 5 then
                    self:write(col + 1, row + 1, RAMP[idx], self.backgroundColor, charColor)
                end
            end
        end
    end
end

function UI.Fan:enable()
    UI.Window.enable(self)
    if self.spinning then
        self:scheduleNextFrame()
    end
end

function UI.Fan:disable()
    if self.timerId then
        self.timerId = nil
    end
    UI.Window.disable(self)
end

return UI.Fan
