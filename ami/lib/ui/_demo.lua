-- Opus UI Framework Demo for AmiCoin
-- Demonstrates vendored Opus UI components with flicker-free rendering
-- Shows how to run UI loop in parallel with background tasks

local UI = require('ami.lib.ui.ui')
local Transition = require('ami.lib.ui.transition')

-- Create main page with components
local demoPage = UI.Page {
    menuBar = UI.MenuBar {
        buttons = {
            { text = 'File',    event = 'menu_file' },
            { text = 'Help',    event = 'menu_help' },
        },
    },
    
    title = UI.TitleBar {
        y = 2,
        title = 'Opus UI Demo - AmiCoin Edition',
        backgroundColor = colors.cyan,
    },
    
    instructions = UI.Text {
        x = 2,
        y = 4,
        value = 'This demo shows Opus UI running with a background task.',
    },
    
    counter = UI.Text {
        x = 2,
        y = 6,
        value = 'Background counter: 0',
    },
    
    grid = UI.ScrollingGrid {
        y = 8,
        height = 8,
        columns = {
            { heading = 'Item', key = 'name', width = 20 },
            { heading = 'Value', key = 'value', width = 10 },
        },
        values = {
            { name = 'CPU', value = 'Diamond' },
            { name = 'Monitor', value = 'Advanced' },
            { name = 'Modem', value = 'Wireless' },
            { name = 'GPU', value = 'Integrated' },
        },
    },
    
    buttonPanel = UI.Window {
        y = -5,
        height = 3,
        backgroundColor = colors.gray,
        
        slideBtn = UI.Button {
            x = 2,
            y = 2,
            text = 'Slide Effect',
            event = 'slide_demo',
        },
        
        fadeBtn = UI.Button {
            x = 18,
            y = 2,
            text = 'Fade Effect',
            event = 'fade_demo',
        },
        
        quitBtn = UI.Button {
            x = -10,
            y = 2,
            ex = -2,
            text = 'Quit',
            event = 'quit',
        },
    },
    
    statusBar = UI.StatusBar {
        backgroundColor = colors.lightGray,
    },
}

-- Handle events
function demoPage:eventHandler(event)
    if event.type == 'quit' then
        UI:quit()
        return true
        
    elseif event.type == 'slide_demo' then
        -- Demo slide transition
        local tempPage = UI.Page {
            notification = UI.Notification {
                y = -3,
                backgroundColor = colors.lime,
            },
            
            backBtn = UI.Button {
                x = 2,
                y = -2,
                text = 'Back',
                event = 'back',
            },
        }
        
        tempPage.notification:info('Slide transition demo!')
        
        function tempPage:eventHandler(evt)
            if evt.type == 'back' then
                UI:setPage(demoPage, Transition.slideLeft)
                return true
            end
        end
        
        UI:setPage(tempPage, Transition.slideRight)
        return true
        
    elseif event.type == 'fade_demo' then
        -- Demo fade transition
        demoPage.statusBar:timedStatus('Fade transition!', 3)
        return true
        
    elseif event.type == 'menu_help' then
        demoPage.statusBar:setStatus('Opus UI vendored for AmiCoin - press Q to quit')
        return true
    end
    
    return UI.Page.eventHandler(self, event)
end

-- Background task that runs in parallel with UI
local function backgroundTask()
    local counter = 0
    while true do
        -- Simulate background work
        os.sleep(1)
        counter = counter + 1
        
        -- Update UI (safe because Canvas buffers changes)
        if demoPage.counter then
            demoPage.counter.value = 'Background counter: ' .. counter
            demoPage.counter:draw()
            demoPage:sync()
        end
    end
end

-- Main entry point
local function main()
    -- Check for advanced terminal
    if not term.isColor() then
        print("This demo requires an Advanced Computer/Monitor")
        return
    end
    
    print("Starting Opus UI Demo...")
    print("Setting up UI...")
    
    -- Set initial page
    UI:setPage(demoPage)
    demoPage.statusBar:setStatus('Ready - Click buttons to test transitions')
    
    -- Run UI loop in parallel with background task
    -- This demonstrates coexistence with existing app loops
    parallel.waitForAny(
        function()
            -- UI event loop
            UI:pullEvents()
        end,
        backgroundTask
    )
    
    -- Cleanup
    term.clear()
    term.setCursorPos(1, 1)
    print("Demo exited cleanly")
end

-- Run the demo
local ok, err = pcall(main)
if not ok then
    term.clear()
    term.setCursorPos(1, 1)
    print("Error in demo:")
    print(err)
end
