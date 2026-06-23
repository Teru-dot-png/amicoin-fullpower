# Opus UI Framework - Vendoring Plan & Strategy

## Overview

This document describes the strategy used to vendor the Opus UI toolkit from the Opus OS project into AmiCoin as a standalone library.

**Status:** ✅ COMPLETED (2026-06-23)

## Source

- **Repository:** https://github.com/kepler155c/opus
- **Branch:** master-1.8
- **Commit:** Latest as of 2026-06-23
- **License:** Open source (Opus OS project license)

## Goals

1. **Standalone UI library** - Use Opus UI components without requiring Opus OS
2. **Zero OS dependencies** - Remove all Opus OS kernel/shell/package dependencies
3. **Localized requires** - Change all `require('opus.xxx')` to `require('ami.lib.ui.xxx')`
4. **Parallel-friendly** - Integrate with existing `parallel.waitForAny()` patterns in AmiCoin
5. **Minimal changes** - Preserve original Opus functionality where possible

## What We Vendored (Dependency Closure)

### Core UI Framework (12 files)
```
ui.lua              - Manager, Element, Window, Page (core classes)
canvas.lua          - Dirty-region rendering canvas
region.lua          - Canvas region management
transition.lua      - Page transition effects (slide, fade, etc.)
tween.lua           - Animation easing functions
```

### Support Libraries (7 files)
```
class.lua           - OOP class system with inheritance
event.lua           - Event handler registration/dispatch
input.lua           - Keyboard/mouse input handling
util.lua            - General utilities (merge, matches, etc.)
entry.lua           - Text entry field management
sound.lua           - Optional sound support
terminal.lua        - Terminal size/color management
```

### UI Components (35 files in components/)
```
ActiveLayer.lua     - Active element layer
Button.lua          - Clickable buttons
Checkbox.lua        - Checkbox toggles
Chooser.lua         - Option chooser
Dialog.lua          - Modal dialogs
DropMenu.lua        - Dropdown menus
DropMenuItem.lua    - Dropdown menu items
Embedded.lua        - Embedded windows
Form.lua            - Forms
Grid.lua            - Data grids
Image.lua           - Image display
Menu.lua            - Menus
MenuBar.lua         - Menu bars
MenuItem.lua        - Menu items
NftImage.lua        - NFT image display
Notification.lua    - Notifications
ProgressBar.lua     - Progress bars
ScrollBar.lua       - Scrollbars
ScrollingGrid.lua   - Scrollable grids
SlideOut.lua        - Slide-out panels
Slider.lua          - Value sliders
StatusBar.lua       - Status bars
Tab.lua             - Tab pages
TabBar.lua          - Tab bars
TabBarMenuItem.lua  - Tab bar menu items
Tabs.lua            - Tab containers
Text.lua            - Text labels
TextArea.lua        - Multi-line text areas
TextEntry.lua       - Single-line text input
Throttle.lua        - Event throttling
TitleBar.lua        - Window title bars
VerticalMeter.lua   - Vertical meters
Viewport.lua        - Scrollable viewports
Wizard.lua          - Wizard containers
WizardPage.lua      - Wizard pages
```

### Dev Tools (2 files)
```
_charmap.lua        - Character map browser (displays all 256 CC glyphs)
_demo.lua           - Full UI demo with transitions and parallel execution
```

**Total:** 56 files (12 core + 7 libs + 35 components + 2 dev tools)

## What We Excluded (Opus OS parts)

- **os/** - Opus OS kernel, process manager, multitasking
- **sys/** - System daemons, autorun, startup scripts
- **apps/** - Built-in Opus applications
- **network/** - Network stack, SSH, file sharing
- **services/** - Background services (dns, snmp, etc.)
- **packages/** - Package manager and repositories
- **installer/** - Opus OS installer

## Localization Strategy

### 1. Require Path Rewriting

**Original Opus paths:**
```lua
require('opus.ui')
require('opus.ui.components.Button')
require('opus.class')
```

**Localized AmiCoin paths:**
```lua
require('ami.lib.ui.ui')
require('ami.lib.ui.components.Button')
require('ami.lib.ui.class')
```

**Implementation:** Find-and-replace across all vendored files.

### 2. Component Loading

**Challenge:** Opus UI uses `fs.list()` to discover components dynamically.

**Solution:** Modified `ui.lua:loadComponents()` to use a fixed component list:
```lua
local function loadComponents()
    local components = {
        'Button', 'Grid', 'Text', 'TextEntry', 'Dialog', 'Menu', 'ScrollBar',
        -- ... (all 35 components hardcoded)
    }
    for _, name in ipairs(components) do
        local path = 'ami/lib/ui/components/' .. name .. '.lua'
        local fn, err = loadfile(path)
        if fn then
            local env = setmetatable({}, { __index = _G })
            setfenv(fn, env)
            package.loaded['ami.lib.ui.components.' .. name] = fn()
        end
    end
end
```

**Rationale:** Avoids filesystem dependency and provides explicit control.

### 3. OS Dependencies Removed

**Multishell debug feature:**
- Original: Ctrl+Shift+Click opens element inspector in new tab
- Removed: No multishell in CraftOS, feature disabled

**Theme loading:**
- Original: Loads theme JSON files from disk
- Modified: Uses inline default themes only

**Config persistence:**
- Original: Saves UI state to disk
- Modified: No persistence (apps manage their own state)

## Verification Checklist

- [x] Zero `require('opus.xxx')` calls remain
- [x] Zero `fs.list()` or `fs.find()` calls in core framework
- [x] No references to `multishell` API
- [x] No external file dependencies (themes, configs)
- [x] All components load via `require()`
- [x] Canvas dirty-region tracking works
- [x] Parallel integration pattern documented
- [x] Demo program runs successfully

**Verification Command:**
```bash
cd ami/lib/ui && grep -r "require.*opus\." .
# Should return: (no matches)
```

## Integration Pattern

**For AmiCoin apps using Opus UI:**

```lua
-- Load the UI framework
local UI = require('ami.lib.ui.init')

-- Create a page with components
local page = UI.UI.Page {
    menuBar = UI.Components.MenuBar {
        buttons = {
            { text = 'Quit', event = 'quit' },
        }
    },
    grid = UI.Components.Grid {
        x = 2, y = 4, height = 10,
        columns = {
            { heading = 'Name', key = 'name' },
            { heading = 'Balance', key = 'balance' },
        },
    },
}

-- Event handlers
page:setFocus(page.grid)
page.menuBar:on('quit', function() UI.UI:exitPullEvents() end)

-- Run UI in parallel with app logic
parallel.waitForAny(
    function() UI.UI:pullEvents() end,     -- UI event loop
    function() yourMainLoop() end           -- Your app (mining, etc.)
)
```

**Key points:**
- UI runs in its own coroutine via `parallel.waitForAny()`
- Events fire to handlers defined in component config
- Never block the UI event loop or input will drop
- Use timers (`os.startTimer`) for animations, not `sleep()`

## Testing

**Smoke test:**
```bash
cd /ami/lib/ui
lua _demo.lua
# Should display: multi-page UI with transitions, fully interactive
```

**Character map:**
```bash
lua _charmap.lua
# Should display: 16x16 grid of all 256 CC characters
```

## Maintenance

**Updating from upstream Opus:**

1. Check for new commits at https://github.com/kepler155c/opus
2. Download changed files
3. Re-apply localization:
   - Find-replace `require('opus.` → `require('ami.lib.ui.`
   - Check for new OS dependencies
   - Test with _demo.lua
4. Update README.md and this document
5. Commit with detailed change log

**Adding new components:**

1. Place component in `ami/lib/ui/components/<Name>.lua`
2. Localize all requires
3. Add to `loadComponents()` list in `ui.lua`
4. Add to convenience exports in `init.lua` if commonly used
5. Test loading and rendering

## License

This vendored copy preserves the original Opus OS license. AmiCoin uses Opus UI under the terms of that license.

**Original source:** https://github.com/kepler155c/opus
**License file:** See Opus repository for full license text

---

**Document Status:** Living document, update as vendoring evolves.  
**Last Updated:** 2026-06-23  
**Authored by:** AmiCoin Builder (AI)
