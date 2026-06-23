# Opus UI Framework - Vendored for AmiCoin

This directory contains a vendored copy of the Opus UI toolkit from the Opus OS project.

**Source:** https://github.com/kepler155c/opus (branch: master-1.8)  
**License:** Open source (original Opus OS project)  
**Vendored:** 2026-06-23  
**Purpose:** Provide rich UI components for AmiCoin apps without requiring Opus OS

## What's Included (Dependency Closure)

### Core UI Framework (12 files)
- `ui.lua` - Main UI module (Manager, Element, Window, Page)
- `canvas.lua` - Rendering canvas with dirty-region tracking
- `region.lua` - Region management for canvas
- `transition.lua` - Page transition effects
- `tween.lua` - Animation tweening library

### Support Libraries (7 files)
- `class.lua` - OOP class system
- `event.lua` - Event management
- `input.lua` - Input handling (keyboard/mouse)
- `util.lua` - Utility functions
- `entry.lua` - Text entry field management
- `sound.lua` - Optional sound support
- `terminal.lua` - Terminal management

### UI Components (35 files in `components/`)
ActiveLayer, Button, Checkbox, Chooser, Dialog, DropMenu, DropMenuItem, 
Embedded, Form, Grid, Image, Menu, MenuBar, MenuItem, NftImage, Notification, 
ProgressBar, ScrollBar, ScrollingGrid, SlideOut, Slider, StatusBar, Tab, 
TabBar, TabBarMenuItem, Tabs, Text, TextArea, TextEntry, Throttle, TitleBar, 
VerticalMeter, Viewport, Wizard, WizardPage

### Dev Tools (2 files)
- `_charmap.lua` - Character map browser (displays all 256 CC glyphs)
- `_demo.lua` - Full UI demo with transitions and parallel execution

## Changes from Original Opus

1. **All requires localized**: `require('opus.xxx')` → `require('ami.lib.ui.xxx')`
2. **Component loading**: Modified to use loadfile with custom environment (no OS filesystem deps)
3. **OS dependencies removed**: Removed multishell debug feature (Ctrl+Shift+Click)
4. **Theme loading disabled**: Uses default themes only (no external theme files)
5. **No OS integration**: Removed kernel, shell, package manager, network stack

## Verification: Zero opus. Requires

```bash
$ cd ami/lib/ui && grep -r "require.*opus\." .
# (no results - all requires localized)
```

## How Canvas Avoids Flicker

The Canvas module implements **dirty-region tracking**:

1. Elements call `canvas:write()` to draw
2. Canvas tracks which regions have changed (dirty rectangles)
3. On `canvas:render()`, only dirty regions are blitted to the terminal
4. Static content (unchanged regions) is never redrawn

This means:
- ✅ Background tasks can update UI without full-screen repaints
- ✅ Animations are smooth (only moving parts redraw)
- ✅ No flicker from redundant clears

## Parallel Integration Pattern

Opus UI runs its event loop via `UI:pullEvents()`. To coexist with AmiCoin's 
background loops (network daemon, miner, etc.), use `parallel`:

```lua
local UI = require('ami.lib.ui.ui')

-- Set up your page
local myPage = UI.Page { --[[ ... ]] }
UI:setPage(myPage)

-- Run UI loop alongside background tasks
parallel.waitForAny(
    function()
        -- UI event loop (handles mouse/keyboard/timers)
        UI:pullEvents()
    end,
    function()
        -- Your background daemon (network, mining, etc.)
        while true do
            -- Do background work
            os.sleep(1)
            
            -- Safe to update UI from here:
            myPage.someElement.value = "Updated"
            myPage.someElement:draw()
            myPage:sync()  -- Flush canvas changes
        end
    end
)
```

The UI loop does NOT starve background tasks - parallel.waitForAny() yields 
on every event, giving all coroutines fair CPU time.

## Redraw Path (No Full-Screen Repaints)

1. Element changes state → calls `self:draw()`
2. `draw()` writes to Canvas → Canvas marks region dirty
3. Element or page calls `self:sync()`
4. Canvas computes dirty rectangles
5. Canvas blits ONLY dirty regions to terminal
6. Static elements remain untouched (no flicker)

On a static frame (no input, no animation):
- Zero terminal operations
- Background loop runs unimpeded
- Canvas buffers stay unchanged

## Usage Example

```lua
local UI = require('ami.lib.ui.ui')

local page = UI.Page {
    title = UI.TitleBar { title = 'My App' },
    
    button = UI.Button {
        x = 2, y = 3,
        text = 'Click Me',
        event = 'btn_click',
    },
    
    grid = UI.ScrollingGrid {
        y = 5, height = 10,
        columns = {
            { heading = 'Name', key = 'name', width = 15 },
            { heading = 'Value', key = 'val', width = 10 },
        },
        values = { { name = 'Test', val = '123' } },
    },
}

function page:eventHandler(event)
    if event.type == 'btn_click' then
        self:setFocus(self.grid)
        return true
    end
    return UI.Page.eventHandler(self, event)
end

UI:setPage(page)
UI:pullEvents()  -- Blocks until UI:quit() is called
```

## Testing

### Character Map
```bash
$ cd /ami/lib/ui
$ lua _charmap.lua
```
Displays all 256 glyphs with hex codes. Press any key to exit.

### Full Demo
```bash
$ cd /ami/lib/ui
$ lua _demo.lua
```
Shows:
- Page with multiple components (title bar, buttons, grid, status bar)
- Slide transitions between pages
- Background counter running in parallel with UI
- Flicker-free rendering

## Known Limitations

1. **No theme files**: Uses default colors only (theme loading disabled)
2. **No sound by default**: Sound.lua requires speaker peripheral (optional)
3. **Advanced terminal only**: Requires Advanced Computer/Monitor (color + mouse)
4. **Component load time**: Components lazy-load via loadfile (slight first-access delay)

## Target Hardware

- **Minimum**: Advanced Computer (color + mouse)
- **Optimal**: Advanced Monitor (larger screen)
- **Required APIs**: term, colors, peripheral (standard CC:Tweaked)

## Files Count

- Core framework: 12 files
- Support libraries: 7 files
- UI components: 35 files
- Dev tools: 2 files
- **Total: 56 Lua files**

## Integration with AmiCoin Apps

To add Opus UI to an existing AmiCoin app (node, wallet, shop, casino):

1. Require the UI module: `local UI = require('ami.lib.ui.ui')`
2. Create a Page with your components
3. Wrap your existing main loop in `parallel.waitForAny()` alongside `UI:pullEvents()`
4. Update UI elements from background loops via `:draw()` + `:sync()`

The vendored Opus UI does NOT interfere with:
- XTEA crypto (no crypto code in UI)
- Currency math (no AMI/µAMI handling in UI)
- Mesh protocol (no network code in UI)
- Existing parallel loops (coexists via parallel.waitForAny)

## Attribution

Original Opus OS and UI framework by kepler155c.  
Vendored and adapted for AmiCoin by Builder mode (2026-06-23).  
All original license and copyright notices preserved in source files.
