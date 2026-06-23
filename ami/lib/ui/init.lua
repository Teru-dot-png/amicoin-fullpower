-- Opus UI Framework Entry Point for AmiCoin
-- Vendored from https://github.com/kepler155c/opus (master-1.8)
--
-- This is the main entry point for using Opus UI in AmiCoin applications.
-- It provides access to the UI framework, components, and utilities.
--
-- USAGE PATTERN (Parallel with existing loops):
--
-- local UI = require('ami.lib.ui.init')
-- local page = UI.UI.Page {
--   Button = { x = 2, y = 2, text = "Click Me", event = "click" }
-- }
-- 
-- -- In your main loop:
-- parallel.waitForAny(
--   function() UI.UI:pullEvents() end,  -- UI event loop
--   function() yourExistingLoop() end    -- Your app logic
-- )
--
-- COMPONENTS AVAILABLE:
-- See ami/lib/ui/components/ for all 35 available components:
--   Button, Grid, ScrollBar, TextEntry, Dialog, Menu, Tabs, etc.
--
-- IMPORTANT: Non-blocking integration
-- - Use parallel.waitForAny() or parallel.waitForAll() to run UI alongside app logic
-- - UI events fire to your event handlers defined in component config
-- - Never block the UI event loop or input will drop

local UI = require('ami.lib.ui.ui')

-- Export the framework
return {
    -- Core UI framework (Manager, Element, Window, Page)
    UI = UI,
    
    -- Pre-load commonly used components for convenience
    Components = {
        Button = require('ami.lib.ui.components.Button'),
        Grid = require('ami.lib.ui.components.Grid'),
        Text = require('ami.lib.ui.components.Text'),
        TextEntry = require('ami.lib.ui.components.TextEntry'),
        Dialog = require('ami.lib.ui.components.Dialog'),
        Menu = require('ami.lib.ui.components.Menu'),
        ScrollBar = require('ami.lib.ui.components.ScrollBar'),
        ProgressBar = require('ami.lib.ui.components.ProgressBar'),
        Tabs = require('ami.lib.ui.components.Tabs'),
        StatusBar = require('ami.lib.ui.components.StatusBar'),
    },
    
    -- Rendering utilities
    Canvas = require('ami.lib.ui.canvas'),
    Region = require('ami.lib.ui.region'),
    Transition = require('ami.lib.ui.transition'),
    Tween = require('ami.lib.ui.tween'),
    
    -- Support utilities
    Class = require('ami.lib.ui.class'),
    Event = require('ami.lib.ui.event'),
    Util = require('ami.lib.ui.util'),
    
    -- Theme placeholder (no external theme loading in vendored version)
    Theme = {
        -- Default CC colors, can be customized per-app
        colors = {
            primary = colors.blue,
            secondary = colors.cyan,
            success = colors.lime,
            danger = colors.red,
            warning = colors.orange,
            info = colors.lightBlue,
            background = colors.black,
            text = colors.white,
        }
    },
    
    -- Version info
    version = "1.8-vendored",
    source = "https://github.com/kepler155c/opus",
}
