-- AmiCoin Stage 1 Demo
-- Showcase: Theme system + Custom widgets + Opus UI components
-- Demonstrates flicker-free rendering, parallel integration, and theme switching

local UI         = require('ami.lib.ui.ui')
local Theme      = require('ami.lib.ui.theme')
local Glyphs     = require('ami.lib.ui.glyphs')
local Event      = require('ami.lib.ui.event')

-- Load custom widgets
require('ami.lib.ui.widgets.gauge')
require('ami.lib.ui.widgets.fan')
require('ami.lib.ui.widgets.card')

local colors     = _G.colors
local os         = _G.os
local parallel   = _G.parallel
local term       = _G.term

-------------------------------------------
-- BACKGROUND TASK (proves parallel works)
-------------------------------------------
local bgCounter = 0
local bgRunning = true

local function backgroundTask()
    while bgRunning do
        os.sleep(2)
        bgCounter = bgCounter + 1
    end
end

-------------------------------------------
-- DEMO APPLICATION
-------------------------------------------
local app = UI.Page {
    backgroundColor = colors.black,
    
    -- Status bar at top
    statusBar = UI.StatusBar {
        y = 1,
        backgroundColor = colors.gray,
        textColor = colors.white,
        columns = {
            { key = 'title', width = 20 },
            { key = 'counter', width = 20 },
            { key = 'theme', width = UI.term.width - 40 },
        }
    },
    
    -- Navigation hint at bottom
    navBar = UI.StatusBar {
        y = -1,
        backgroundColor = colors.lightGray,
        textColor = colors.black,
        columns = {
            { key = 'help', width = UI.term.width },
        }
    },
    
    -- Container for page content
    container = UI.Window {
        y = 2,
        ey = -2,
    },
}

-------------------------------------------
-- PAGE FORWARD DECLARATIONS
-------------------------------------------
local page1, page2  -- Forward declare to avoid reference issues

-------------------------------------------
-- PAGE 1: Gauges + Buttons
-------------------------------------------
page1 = UI.Page {
    backgroundColor = colors.black,
    
    -- Title
    titleText = UI.Text {
        x = 2,
        y = 2,
        value = "Stage 1: Theme + Widgets Demo",
        textColor = colors.yellow,
    },
    
    subtitleText = UI.Text {
        x = 2,
        y = 3,
        value = "Page 1: Gauges + Opus Buttons",
        textColor = colors.lightGray,
    },
    
    -- Gauge 1: Low value (green)
    gauge1Label = UI.Text {
        x = 2,
        y = 5,
        value = "Temperature:",
        textColor = colors.white,
    },
    gauge1 = UI.Gauge {
        x = 2,
        y = 6,
        width = 20,
        value = 25,
        max = 100,
        showValue = true,
    },
    
    -- Gauge 2: Mid value (yellow)
    gauge2Label = UI.Text {
        x = 2,
        y = 8,
        value = "Load:",
        textColor = colors.white,
    },
    gauge2 = UI.Gauge {
        x = 2,
        y = 9,
        width = 20,
        value = 50,
        max = 100,
        showValue = true,
    },
    
    -- Gauge 3: High value (red)
    gauge3Label = UI.Text {
        x = 2,
        y = 11,
        value = "Danger:",
        textColor = colors.white,
    },
    gauge3 = UI.Gauge {
        x = 2,
        y = 12,
        width = 20,
        value = 95,
        max = 100,
        showValue = true,
    },
    
    -- Animate gauge button
    animateBtn = UI.Button {
        x = 25,
        y = 8,
        text = "Animate",
        event = 'animate_gauges',
    },
    
    -- Next page button
    nextBtn = UI.Button {
        x = 25,
        y = 11,
        text = "Next Page",
        event = 'next_page',
    },
}

-- Gauge animation state
local gaugeAnimating = false
local gaugeTimer = nil

function page1:eventHandler(event)
    if event.type == 'animate_gauges' then
        gaugeAnimating = not gaugeAnimating
        if gaugeAnimating then
            self.animateBtn.text = "Stop"
            self.animateBtn:draw()
            self:animateGauges()
        else
            self.animateBtn.text = "Animate"
            self.animateBtn:draw()
        end
        return true
    elseif event.type == 'next_page' then
        app.container:setPage(page2)
        return true
    elseif event.type == 'timer' and event.timerId == gaugeTimer and gaugeAnimating then
        self:animateGauges()
        return true
    end
end

function page1:animateGauges()
    -- Cycle gauge values
    local v1 = (self.gauge1.value + 5) % 100
    local v2 = (self.gauge2.value + 7) % 100
    local v3 = (self.gauge3.value + 3) % 100
    
    self.gauge1:setValue(v1)
    self.gauge2:setValue(v2)
    self.gauge3:setValue(v3)
    
    self:sync()
    
    if gaugeAnimating then
        gaugeTimer = os.startTimer(0.2)
    end
end

-------------------------------------------
-- PAGE 2: Parametric Fan + Card
-------------------------------------------
page2 = UI.Page {
    backgroundColor = colors.black,
    
    -- Title
    titleText = UI.Text {
        x = 2,
        y = 2,
        value = "Page 2: Parametric Fan + Card",
        textColor = colors.yellow,
    },
    
    subtitleText = UI.Text {
        x = 2,
        y = 3,
        value = "Math-based sine-wave rendering",
        textColor = colors.lightGray,
    },
    
    -- Fan widget (larger, starts at level 1)
    fanLabel = UI.Text {
        x = 2,
        y = 5,
        value = "Air Cooler (Level 1):",
        textColor = colors.white,
    },
    fan = UI.Fan {
        x = 2,
        y = 6,
        level = 1,
        spinning = false,
        color = colors.lightBlue,
    },
    
    -- Fan stats display
    fanStatsLabel = UI.Text {
        x = 2,
        y = 18,
        value = "Blades: 2  Radius: 5  Twist: 0.0  Speed: 1.0x",
        textColor = colors.lightGray,
    },
    
    -- Fan controls row 1
    fanStartBtn = UI.Button {
        x = 24,
        y = 7,
        text = "Start",
        event = 'start_fan',
    },
    
    fanStopBtn = UI.Button {
        x = 32,
        y = 7,
        text = "Stop",
        event = 'stop_fan',
    },
    
    -- Level controls row 2
    levelLabel = UI.Text {
        x = 24,
        y = 9,
        value = "Level:",
        textColor = colors.white,
    },
    levelDownBtn = UI.Button {
        x = 32,
        y = 9,
        text = "-",
        event = 'level_down',
    },
    levelUpBtn = UI.Button {
        x = 35,
        y = 9,
        text = "+",
        event = 'level_up',
    },
    levelMaxBtn = UI.Button {
        x = 38,
        y = 9,
        text = "Max",
        event = 'level_max',
    },
    
    -- Direction control row 3
    dirLabel = UI.Text {
        x = 24,
        y = 11,
        value = "Spin:",
        textColor = colors.white,
    },
    dirCWBtn = UI.Button {
        x = 32,
        y = 11,
        text = "CW",
        event = 'dir_cw',
    },
    dirCCWBtn = UI.Button {
        x = 37,
        y = 11,
        text = "CCW",
        event = 'dir_ccw',
    },
    
    -- Card widget (moved down)
    cardLabel = UI.Text {
        x = 24,
        y = 14,
        value = "Playing Card:",
        textColor = colors.white,
    },
    card = UI.Card {
        x = 24,
        y = 15,
        suit = 'heart',
        rank = 'A',
        faceUp = true,
    },
    
    -- Card controls
    flipBtn = UI.Button {
        x = 32,
        y = 15,
        text = "Flip",
        event = 'flip_card',
    },
    
    nextCardBtn = UI.Button {
        x = 32,
        y = 17,
        text = "Next",
        event = 'next_card',
    },
    
    -- Navigation
    backBtn = UI.Button {
        x = 2,
        y = 20,
        text = "Back",
        event = 'prev_page',
    },
    
    themeBtn = UI.Button {
        x = 10,
        y = 20,
        text = "Themes",
        event = 'show_themes',
    },
}

-- Card deck state
local suits = { 'spade', 'heart', 'diamond', 'club' }
local ranks = { 'A', '2', '3', '4', '5', '6', '7', '8', '9', '10', 'J', 'Q', 'K' }
local cardIndex = 1

-- Fan preset data for display
local FAN_PRESETS = {
    [1]  = { blades = 2, radius = 5,  twist = 0.0,  speed = 1.0 },
    [2]  = { blades = 3, radius = 6,  twist = 0.1,  speed = 1.2 },
    [3]  = { blades = 3, radius = 7,  twist = 0.15, speed = 1.4 },
    [4]  = { blades = 4, radius = 8,  twist = 0.2,  speed = 1.6 },
    [5]  = { blades = 4, radius = 9,  twist = 0.25, speed = 1.8 },
    [6]  = { blades = 5, radius = 10, twist = 0.3,  speed = 2.0 },
    [7]  = { blades = 5, radius = 11, twist = 0.35, speed = 2.2 },
    [8]  = { blades = 6, radius = 12, twist = 0.4,  speed = 2.5 },
    [9]  = { blades = 6, radius = 13, twist = 0.45, speed = 2.8 },
    [10] = { blades = 7, radius = 14, twist = 0.5,  speed = 3.0 },
}

function page2:updateFanStats()
    local lv = self.fan.level
    local p = FAN_PRESETS[lv]
    self.fanLabel.value = string.format("Air Cooler (Level %d):", lv)
    self.fanStatsLabel.value = string.format("Blades: %d  Radius: %d  Twist: %.2f  Speed: %.1fx", 
        p.blades, p.radius, p.twist, p.speed)
    self.fanLabel:draw()
    self.fanStatsLabel:draw()
end

function page2:eventHandler(event)
    if event.type == 'start_fan' then
        self.fan:start()
        return true
    elseif event.type == 'stop_fan' then
        self.fan:stop()
        return true
    elseif event.type == 'level_down' then
        local newLevel = math.max(1, self.fan.level - 1)
        self.fan:setLevel(newLevel)
        self:updateFanStats()
        return true
    elseif event.type == 'level_up' then
        local newLevel = math.min(10, self.fan.level + 1)
        self.fan:setLevel(newLevel)
        self:updateFanStats()
        return true
    elseif event.type == 'level_max' then
        self.fan:setLevel(10)
        self:updateFanStats()
        return true
    elseif event.type == 'dir_cw' then
        self.fan:setDirection(1)
        return true
    elseif event.type == 'dir_ccw' then
        self.fan:setDirection(-1)
        return true
    elseif event.type == 'flip_card' then
        self.card:flip()
        return true
    elseif event.type == 'next_card' then
        cardIndex = (cardIndex % (#suits * #ranks)) + 1
        local suitIdx = ((cardIndex - 1) % #suits) + 1
        local rankIdx = math.floor((cardIndex - 1) / #suits) + 1
        self.card:setCard(suits[suitIdx], ranks[rankIdx])
        return true
    elseif event.type == 'prev_page' then
        app.container:setPage(page1)
        return true
    elseif event.type == 'show_themes' then
        app:showThemeDialog()
        return true
    end
end

-------------------------------------------
-- THEME DIALOG (slide-in modal)
-------------------------------------------
local themeDialog = UI.SlideOut {
    backgroundColor = colors.gray,
    titleBar = UI.TitleBar {
        title = "Choose Theme",
        event = 'slide_hide',
    },
}

-- Build theme buttons
local themes = Theme.listThemes()
local themeButtons = {}
for i, themeName in ipairs(themes) do
    local btn = UI.Button {
        x = 2,
        y = i + 1,
        width = 15,
        text = themeName,
        event = 'set_theme',
        themeName = themeName,
    }
    themeButtons[i] = btn
    themeDialog[themeName .. '_btn'] = btn
end

function themeDialog:eventHandler(event)
    if event.type == 'set_theme' and event.button and event.button.themeName then
        Theme.setTheme(event.button.themeName)
        -- Redraw everything with new theme
        app:applyTheme()
        app:draw()
        self:hide()
        return true
    elseif event.type == 'slide_hide' then
        self:hide()
        return true
    end
end

-- Add theme dialog to app
app.themeDialog = themeDialog

-------------------------------------------
-- THEME APPLICATION
-------------------------------------------
function app:applyTheme()
    local theme = Theme.getTheme()
    
    -- Update app colors
    self.backgroundColor = theme.background
    self.statusBar.backgroundColor = theme.panel
    self.statusBar.textColor = theme.text
    self.navBar.backgroundColor = theme.buttonBg
    self.navBar.textColor = theme.buttonFg
    
    -- Update page 1
    page1.backgroundColor = theme.background
    page1.titleText.textColor = theme.accent
    page1.subtitleText.textColor = theme.textDim
    page1.gauge1Label.textColor = theme.text
    page1.gauge2Label.textColor = theme.text
    page1.gauge3Label.textColor = theme.text
    Theme.apply(page1.animateBtn)
    Theme.apply(page1.nextBtn)
    
    -- Update page 2
    page2.backgroundColor = theme.background
    page2.titleText.textColor = theme.accent
    page2.subtitleText.textColor = theme.textDim
    page2.fanLabel.textColor = theme.text
    page2.cardLabel.textColor = theme.text
    Theme.apply(page2.fanStartBtn)
    Theme.apply(page2.fanStopBtn)
    Theme.apply(page2.flipBtn)
    Theme.apply(page2.nextCardBtn)
    Theme.apply(page2.backBtn)
    Theme.apply(page2.themeBtn)
    
    -- Update theme dialog
    themeDialog.backgroundColor = theme.panel
    for _, btn in pairs(themeButtons) do
        Theme.apply(btn)
    end
end

function app:showThemeDialog()
    self.themeDialog:show()
end

-------------------------------------------
-- APP SETUP
-------------------------------------------
function app:postInit()
    -- Set up container pages
    self.container:setPage(page1)
    
    -- Apply initial theme
    self:applyTheme()
end

function app:eventHandler(event)
    -- Update status bar
    self.statusBar.values = {
        title = "AmiCoin UI Demo",
        counter = "BG Counter: " .. tostring(bgCounter),
        theme = "Theme: " .. Theme.getThemeName(),
    }
    self.statusBar:draw()
    
    self.navBar.values = {
        help = "Tab: Navigate | Enter: Select | Q: Quit | Page1: Gauges | Page2: Widgets",
    }
    self.navBar:draw()
    
    -- Handle quit
    if event.type == 'key' and event.key == 'q' then
        bgRunning = false
        self:exitPullEvents()
        return true
    end
end

-------------------------------------------
-- MAIN
-------------------------------------------
local function main()
    if not term.isColor() then
        print("This demo requires an Advanced Computer/Monitor")
        return
    end
    
    -- Set initial theme
    Theme.setTheme("default")
    
    -- Run app with background task in parallel
    parallel.waitForAny(
        function() app:pullEvents() end,
        backgroundTask
    )
    
    -- Cleanup
    term.clear()
    term.setCursorPos(1, 1)
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
    print("Demo exited. BG Counter reached: " .. bgCounter)
end

-- Run if executed directly
if not pcall(debug.getlocal, 4, 1) then
    main()
end

return {
    app = app,
    main = main,
}
