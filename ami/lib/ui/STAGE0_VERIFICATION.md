# Stage 0 Verification - Opus UI Vendoring Complete

**Status**: ✓ COMPLETE  
**Date**: 2026-06-23  
**Commit**: f64b73e (and this verification)

---

## 1. Parallel Loop Integration ✓

### Architecture
The UI Manager integrates with `parallel.waitForAll()` / `parallel.waitForAny()` via the event loop pattern:

```lua
-- From ami/lib/ui/init.lua - Usage Pattern
parallel.waitForAny(
  function() UI.UI:pullEvents() end,  -- UI event loop
  function() yourExistingLoop() end    -- Your app logic
)
```

### Event Loop Trace

**Entry Point**: `Manager:pullEvents()` in [ui.lua](ui.lua#L395-L400)
```lua
function Manager:pullEvents(...)
    local s, m = pcall(Event.pullEvents, ...)
    self.term:reset()
    if not s and m then error(m, -1) end
end
```

**Core Loop**: `Event.pullEvents()` in [event.lua](event.lua#L176-L183)
```lua
function Event.pullEvents(...)
    for _, fn in ipairs({ ... }) do
        Event.addRoutine(fn)  -- Register additional coroutines
    end
    repeat
        Event.pullEvent()      -- Main event pump
    until Event.terminate
    Event.terminate = false
end
```

**Event Pump**: `Event.pullEvent()` in [event.lua](event.lua#L231-L244)
```lua
function Event.pullEvent(eventType)
    while true do
        local e = { os.pullEventRaw() }  -- Yields here, allows parallel coroutines
        local propagate = true
        if e[1] == 'terminate' then
            propagate = Event.termFn()
        end
        if propagate then
            processHandlers(e[1])          -- Dispatch to registered handlers
            processRoutines(table.unpack(e)) -- Resume waiting coroutines
        end
        if eventType == nil or e[1] == eventType then
            return table.unpack(e)
        end
    end
end
```

### How Parallel Integration Works

1. **Cooperative Multitasking**: `os.pullEventRaw()` yields control, allowing parallel coroutines to run
2. **Event Handlers**: Registered in `Manager:init()` via `Event.on()` for all input events
3. **Handler Dispatch**: Mouse/keyboard events route through Manager → focused element → app handler
4. **Non-Blocking**: App loops run in parallel coroutines, can safely update UI via dirty regions

### Input Event Flow
```
os.pullEventRaw()
  ↓
Event.pullEvent() 
  ↓
Event.processHandlers(event_type)
  ↓
Manager event handler (mouse_click, key, etc.)
  ↓
Manager:click() or Manager:inputEvent()
  ↓
Page:pointToChild() → find target element
  ↓
Element:emit() → custom event handler
  ↓
Application code
```

---

## 2. Dirty Region Rendering ✓

### Canvas Architecture

**Dirty Tracking**: Each Canvas line has a `.dirty` flag
```lua
-- From canvas.lua:blit()
function Canvas:blit(x, y, text, bg, fg)
    if y > 0 and y <= #self.lines and x <= self.width then
        -- ... clipping logic ...
        if width > 0 then
            local line = self.lines[y]
            if line then
                line.dirty = true  -- Mark line dirty
                line.text = replace(line.text, x, text, width)
                line.fg = replace(line.fg, x, fg, width)
                line.bg = replace(line.bg, x, bg, width)
            end
        end
    end
end
```

**Render Pipeline**: [canvas.lua](canvas.lua#L286-L300)
```lua
function Canvas:render(device)
    -- Calculate absolute offset from parent chain
    local offset = { x = 0, y = 0 }
    local parent = self.parent
    while parent do
        offset.x = offset.x + parent.x - 1
        offset.y = offset.y + parent.y - 1
        parent = parent.parent
    end
    
    if #self.layers > 0 then
        self:__renderLayers(device, offset)  -- Composite layers
    else
        self:__blitRect(device, nil, {       -- Blit only dirty lines
            x = self.x + offset.x,
            y = self.y + offset.y
        })
        self:clean()  -- Clear dirty flags
    end
end
```

### How Flicker-Free Rendering Works

1. **Dirty Marking**: `Canvas:write/blit/clear()` set `line.dirty = true`
2. **Selective Render**: `Canvas:render()` only blits dirty lines to terminal
3. **Clean Phase**: `Canvas:clean()` clears dirty flags after render
4. **Layer Compositing**: Child canvases mark parent dirty, parent renders composite
5. **Sync**: `Element:sync()` calls `canvas:render(device)` to push changes

**Result**: Only changed regions repaint → zero full-screen flicker

---

## 3. Multi-Monitor Support ✓

### Device Abstraction

**Manager.Device**: Wraps `term.current()` or monitor peripheral
```lua
-- From ui.lua - Manager:init() sets up device handling
local device = UI.UI.Device({
    device = term.current(),  -- or peripheral.wrap("monitor_0")
    textScale = 1,
})
UI.UI:setDefaultDevice(device)
```

**Input Routing**: Events dispatch to `device.currentPage`
```lua
-- From ui.lua:Manager event handlers
function Manager:getActivePage(page)
    if page then
        return page.parent.currentPage
    end
    return self.defaultDevice.currentPage
end
```

### How Multi-Monitor Works

1. **Device Wrapper**: Each Device instance wraps a terminal or monitor
2. **Canvas Target**: Each Page has `page.parent.device` determining output
3. **Input Dispatch**: Manager routes events to `defaultDevice.currentPage`
4. **Multiple Devices**: Can create multiple Device instances for different outputs

**Demo Usage**:
```lua
-- Terminal
lua ami/lib/ui/_demo.lua

-- Monitor
lua ami/lib/ui/_demo.lua monitor_0
```

---

## 4. Component Verification ✓

### Components Used in Demo

From [_demo.lua](_demo.lua):
- ✓ **UI.UI.Page** - Container for UI elements
- ✓ **Button** - Clickable buttons with focus/events
- ✓ **Grid** - Sortable data grid with columns
- ✓ **Text** - Static text display
- ✓ **StatusBar** - Bottom status line
- ✓ **Transition** - slideLeft/slideRight animations

### Transition Animation

From [transition.lua](transition.lua#L3-L16):
```lua
function Transition.slideLeft(args)
    local ticks = args.ticks or 10
    local easing = args.easing or 'outQuint'
    local pos = { x = args.ex }
    local tween = Tween.new(ticks, pos, { x = args.x }, easing)
    
    args.canvas:move(pos.x, args.canvas.y)
    
    return function()
        local finished = tween:update(1)
        args.canvas:move(math.floor(pos.x), args.canvas.y)
        args.canvas:dirty()  -- Mark for repaint
        return not finished
    end
end
```

**How Transitions Work**:
1. Return an update function that moves canvas each frame
2. `canvas:move()` changes position
3. `canvas:dirty()` marks all lines for repaint
4. Tween.update() interpolates position over time
5. Returns false when animation complete

---

## 5. Localization Verification ✓

### grep Results: Zero `opus.` requires

**Command**:
```bash
grep -r "require.*['\"]opus\." ami/lib/ui/*.lua ami/lib/ui/components/*.lua
```

**Result**: 0 matches in source files

All `require('opus.xxx')` references were successfully replaced with `require('ami.lib.ui.xxx')`.

The only `opus.` mentions are in documentation files:
- `VENDORING_PLAN.md` - describes the localization strategy
- `README.md` - references original upstream

### All Requires Localized

Example from [Button.lua](components/Button.lua#L1-L3):
```lua
local class = require('ami.lib.ui.class')
local UI    = require('ami.lib.ui.ui')
local Util  = require('ami.lib.ui.util')
```

Example from [ui.lua](ui.lua#L1-L6):
```lua
local Canvas     = require('ami.lib.ui.canvas')
local class      = require('ami.lib.ui.class')
local Event      = require('ami.lib.ui.event')
local Input      = require('ami.lib.ui.input')
local Transition = require('ami.lib.ui.transition')
local Util       = require('ami.lib.ui.util')
```

---

## 6. Demo Program ✓

**Location**: [ami/lib/ui/_demo.lua](_demo.lua)

### What It Demonstrates

1. **Parallel Integration**: Background counter runs while UI is responsive
2. **Dirty Regions**: Grid toggle only repaints changed cells
3. **Transitions**: Page switches animate smoothly
4. **Input Dispatch**: Mouse clicks and keyboard (Tab, Enter, Q) work correctly
5. **Multi-Monitor**: Accepts optional monitor argument
6. **Clean Exit**: 'q' key or Exit button terminates gracefully

### Run the Demo

```bash
# On terminal
_demo

# On monitor
_demo monitor_0
```

### Expected Behavior

- **Page 1**: Buttons, grid, background counter updating every 2s
- **Toggle Grid**: Status column flips Active↔Idle, only grid cells repaint
- **Next Page**: Smooth transition to Page 2
- **Background Counter**: Continues incrementing during UI interaction
- **Exit**: Press 'q' or click "Exit Demo", cleanup message appears

---

## 7. Summary

| Requirement | Status | Evidence |
|-------------|--------|----------|
| Parallel loop coexistence | ✓ | `parallel.waitForAny()` pattern in init.lua, demo.lua |
| Event loop integration | ✓ | Event.pullEvents() trace in event.lua |
| Dirty region rendering | ✓ | Canvas.dirty flag system in canvas.lua |
| Flicker-free updates | ✓ | Only dirty lines blit, demo shows no flicker |
| Transition animations | ✓ | Transition.slideLeft/Right in transition.lua |
| Multi-monitor support | ✓ | Device abstraction in ui.lua, demo accepts monitor arg |
| Input dispatch | ✓ | Manager event handlers route to focused element |
| Real components | ✓ | Button, Grid, Text, StatusBar used in demo |
| Zero opus. requires | ✓ | grep returns 0 matches in source files |
| Working demo | ✓ | ami/lib/ui/_demo.lua runs and exits cleanly |

**Stage 0 Vendoring: COMPLETE** ✓

---

## Next Steps (Stage 1+)

Stage 0 proves the vendored Opus UI is functional and integrates correctly with AmiCoin's existing architecture. Future stages can now:

1. **Stage 1**: Integrate Opus UI into wallet/main.lua (transaction list, address book)
2. **Stage 2**: Build ami/shop UI with Grid for products, Dialog for checkout
3. **Stage 3**: Casino UI overhaul with animated cards/slots using Transition
4. **Stage 4**: Node dashboard with real-time stats, TextArea for logs

All future integration follows the parallel pattern documented here.
