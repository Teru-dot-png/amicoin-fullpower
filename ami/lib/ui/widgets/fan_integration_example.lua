-- INTEGRATION EXAMPLE: Parametric Fan Widget in Node UI
-- This file demonstrates how to integrate the parametric fan widget
-- with the node's upgrade system.
--
-- USAGE:
--   1. Require the Fan widget in your node UI code
--   2. Query air_cooler upgrade level from upgrades module
--   3. Set fan level based on upgrade
--   4. Start/stop fan based on conditions

local UI       = require('ami.lib.ui.ui')
local upgrades = require('upgrades')

-- Load the Fan widget
require('ami.lib.ui.widgets.fan')

-------------------------------------------
-- EXAMPLE 1: Simple Integration
-------------------------------------------
-- Add fan to a UI page/window:

local myPage = UI.Page {
    backgroundColor = colors.black,
    
    -- Cooling fan widget
    coolingFan = UI.Fan {
        x = 5,
        y = 5,
        level = 1,      -- Default level
        spinning = false,
        color = colors.cyan,
    },
    
    -- Temperature display
    tempLabel = UI.Text {
        x = 28,
        y = 8,
        value = "Temp: 30C",
        textColor = colors.white,
    },
}

-------------------------------------------
-- EXAMPLE 2: Dynamic Level from Upgrade
-------------------------------------------
-- Query air_cooler level and apply to fan:

function myPage:postInit()
    -- Get air_cooler upgrade level (0-10)
    local airCoolerLevel = upgrades.getLevel("air_cooler")
    
    if airCoolerLevel > 0 then
        -- Set fan to match upgrade level
        self.coolingFan:setLevel(airCoolerLevel)
        self.coolingFan:start()
    else
        -- No cooling upgrade = fan off
        self.coolingFan:stop()
    end
end

-------------------------------------------
-- EXAMPLE 3: Temperature-Based Control
-------------------------------------------
-- Start/stop fan based on node temperature:

function myPage:updateTemperature(temp)
    self.tempLabel.value = string.format("Temp: %dC", temp)
    self.tempLabel:draw()
    
    local airCoolerLevel = upgrades.getLevel("air_cooler")
    
    if airCoolerLevel > 0 then
        self.coolingFan:setLevel(airCoolerLevel)
        
        -- Start fan if temp above threshold
        if temp > 100 and not self.coolingFan.spinning then
            self.coolingFan:start()
        elseif temp <= 50 and self.coolingFan.spinning then
            self.coolingFan:stop()
        end
    else
        -- No upgrade = no fan
        if self.coolingFan.spinning then
            self.coolingFan:stop()
        end
    end
end

-------------------------------------------
-- EXAMPLE 4: Live Upgrade Detection
-------------------------------------------
-- Update fan when user purchases air_cooler upgrade:

function myPage:onUpgradePurchased(upgradeId)
    if upgradeId == "air_cooler" then
        local newLevel = upgrades.getLevel("air_cooler")
        
        -- Animate level change
        self.coolingFan:setLevel(newLevel)
        
        if not self.coolingFan.spinning then
            self.coolingFan:start()
        end
        
        -- Show notification
        print(string.format("Air cooler upgraded to level %d!", newLevel))
    end
end

-------------------------------------------
-- EXAMPLE 5: Advanced Monitor Display
-------------------------------------------
-- For nodes with Advanced Monitor attached:

local function setupMonitorDisplay()
    local monitor = peripheral.find("monitor")
    if not monitor then return end
    
    -- Wrap monitor as Opus terminal
    local monitorTerm = UI.term.monitor(monitor)
    
    local monitorPage = UI.Page {
        terminal = monitorTerm,
        backgroundColor = colors.black,
        
        titleBar = UI.TitleBar {
            title = "AmiCoin Node",
            backgroundColor = colors.gray,
        },
        
        -- Large fan display
        fan = UI.Fan {
            x = 3,
            y = 3,
            level = upgrades.getLevel("air_cooler") or 1,
            spinning = true,
            color = colors.lime,
        },
        
        -- Stats panel
        statsPanel = UI.Window {
            x = 28,
            y = 3,
            width = 20,
            height = 10,
            backgroundColor = colors.gray,
        },
        
        tempLabel = UI.Text {
            x = 29,
            y = 4,
            value = "Temperature: --C",
            textColor = colors.white,
        },
        
        levelLabel = UI.Text {
            x = 29,
            y = 6,
            value = "Cooler Level: 0",
            textColor = colors.white,
        },
        
        bladesLabel = UI.Text {
            x = 29,
            y = 8,
            value = "Blades: 2",
            textColor = colors.lightGray,
        },
    }
    
    monitorPage:draw()
    monitorPage:sync()
    
    return monitorPage
end

-------------------------------------------
-- EXAMPLE 6: Thermal System Integration
-------------------------------------------
-- Complete thermal management with fan visualization:

local ThermalManager = {}

function ThermalManager:new()
    local obj = {
        baseTemp = 30,
        currentTemp = 30,
        targetTemp = 30,
        coolerLevel = 0,
        overclocLevel = 0,
    }
    setmetatable(obj, { __index = self })
    return obj
end

function ThermalManager:update()
    -- Calculate target temp from upgrades
    local AMBIENT = 30
    local HEAT_PER_OC = 28
    local COOL_PER_LEVEL = 28
    
    self.coolerLevel = upgrades.getLevel("air_cooler")
    self.overclocLevel = upgrades.getLevel("miner_boost")
    
    local heatAdded = HEAT_PER_OC * self.overclocLevel
    local coolRemoved = COOL_PER_LEVEL * self.coolerLevel
    
    self.targetTemp = AMBIENT + heatAdded - coolRemoved
    
    -- Smooth temp change (cosmetic)
    if self.currentTemp < self.targetTemp then
        self.currentTemp = math.min(self.targetTemp, self.currentTemp + 2)
    elseif self.currentTemp > self.targetTemp then
        self.currentTemp = math.max(self.targetTemp, self.currentTemp - 2)
    end
    
    return self.currentTemp
end

function ThermalManager:shouldThrottle()
    -- Throttle mining if temp exceeds safe threshold
    return self.currentTemp > 300
end

-- Usage in main loop:
--[[
local thermal = ThermalManager:new()
local ui = setupMonitorDisplay()

while true do
    local temp = thermal:update()
    
    -- Update UI
    if ui then
        ui.tempLabel.value = string.format("Temperature: %dC", temp)
        ui.levelLabel.value = string.format("Cooler Level: %d", thermal.coolerLevel)
        ui.tempLabel:draw()
        ui.levelLabel:draw()
        
        -- Update fan
        if thermal.coolerLevel > 0 then
            ui.fan:setLevel(thermal.coolerLevel)
            if not ui.fan.spinning then
                ui.fan:start()
            end
        else
            ui.fan:stop()
        end
    end
    
    -- Throttle mining if overheating
    if thermal:shouldThrottle() then
        print("WARNING: Overheating! Mining throttled.")
    end
    
    os.sleep(1)
end
]]

-------------------------------------------
-- API SUMMARY
-------------------------------------------
--[[
Fan Widget Methods:
  :setLevel(1-10)      -- Set upgrade level (changes blades, radius, twist, speed)
  :start()             -- Start spinning
  :stop()              -- Stop spinning
  :setSpeed(fps)       -- Set FPS (1-60, default 30)
  :setDirection(dir)   -- Set direction (+1 = clockwise, -1 = counter-clockwise)

Fan Widget Properties:
  .level               -- Current upgrade level (1-10)
  .spinning            -- Boolean: is fan currently spinning
  .blades              -- Number of blades (from preset)
  .radius              -- Fan radius in cells (from preset)
  .twist               -- Spiral factor (from preset)
  .speed               -- Rotation speed multiplier (from preset)
  .rotation            -- Current rotation angle (radians)
  .direction           -- Rotation direction (+1 or -1)

Upgrade Integration:
  upgrades.getLevel("air_cooler")  -- Returns 0-10

Preset Scaling:
  Level  Blades  Radius  Twist   Speed
  -----  ------  ------  -----   -----
    1      2       5      0.0     1.0x
    2      3       6      0.1     1.2x
    3      3       7      0.15    1.4x
    4      4       8      0.2     1.6x
    5      4       9      0.25    1.8x
    6      5      10      0.3     2.0x
    7      5      11      0.35    2.2x
    8      6      12      0.4     2.5x
    9      6      13      0.45    2.8x
   10      7      14      0.5     3.0x

Algorithm (for each cell):
  s = sin(BLADES × angle + TWIST × distance + rotation)
  where:
    angle = atan2(dy, dx)
    distance = √(dx² + dy²)
    rotation = current rotation angle (increments each frame)
  
  Map s to shade:
    s > 0.55:  █ (full block)
    s > 0.15:  ▓ (dark shade)
    s > -0.2:  ▒ (medium shade)
    s ≤ -0.2:  (air/space)
]]

return myPage
