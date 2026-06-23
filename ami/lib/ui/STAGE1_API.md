# Stage 1 API Documentation
## AmiCoin Shared Widget + Theme Library

**Status**: ✅ Complete  
**Dependencies**: Opus UI (vendored in `/ami/lib/ui/`)  
**Version**: 1.0

---

## Overview

Stage 1 provides a comprehensive theme system, named glyph reference, and custom widgets built on top of the vendored Opus UI framework. All components integrate seamlessly with Opus's dirty-region rendering and parallel event loops.

---

## 1. Theme System (`theme.lua`)

A swappable color palette system that applies consistent colors across all UI components.

### Theme Structure

Every theme must provide these color keys:

```lua
{
    background,       -- Main background color
    panel,            -- Panel/window background
    accent,           -- Accent/highlight color
    ok,               -- Success/positive indicator
    warn,             -- Warning indicator
    danger,           -- Error/critical indicator
    text,             -- Primary text color
    textDim,          -- Secondary/dimmed text
    border,           -- Border line color
    buttonBg,         -- Button background
    buttonFg,         -- Button text
    buttonFocusBg,    -- Focused button background
    buttonFocusFg,    -- Focused button text
}
```

### Built-in Themes

| Theme | Description | Colors |
|-------|-------------|--------|
| `default` | Classic CC colors | White on black, lime accent |
| `matrix` | Green phosphor | Lime text on black, green accents (matches node's matrix_ui) |
| `crown_gold` | Gold/yellow prestige | Yellow text on black, gold accents (matches node's prestige_crown) |
| `ice_blue` | Cyan/light blue | Light blue text, cyan accents |
| `void_red` | Red/orange danger | Orange/red text, danger theme |

### API Methods

#### `Theme.setTheme(name)`
Set the active theme by name.

```lua
local Theme = require('ami.lib.ui.theme')
Theme.setTheme("matrix")
```

**Parameters:**
- `name` (string): Theme name (must be registered)

**Returns:** `boolean` - Success

---

#### `Theme.getTheme()`
Get the current theme's color table.

```lua
local theme = Theme.getTheme()
print(theme.accent)  -- colors.lime (in default theme)
```

**Returns:** `table` - Theme color table

---

#### `Theme.getThemeName()`
Get the name of the currently active theme.

```lua
local name = Theme.getThemeName()  -- "default"
```

**Returns:** `string` - Theme name

---

#### `Theme.getColor(key)`
Get a specific color from the current theme.

```lua
local accentColor = Theme.getColor('accent')
local textColor = Theme.getColor('text')
```

**Parameters:**
- `key` (string): Color key from theme

**Returns:** `number` - CC color value

---

#### `Theme.listThemes()`
Get a sorted list of all registered theme names.

```lua
local themes = Theme.listThemes()
-- { "crown_gold", "default", "ice_blue", "matrix", "void_red" }
```

**Returns:** `table` - Array of theme name strings

---

#### `Theme.registerTheme(name, colors)`
Register a new custom theme.

```lua
Theme.registerTheme("my_theme", {
    background = colors.black,
    panel = colors.gray,
    accent = colors.pink,
    ok = colors.lime,
    warn = colors.yellow,
    danger = colors.red,
    text = colors.white,
    textDim = colors.lightGray,
    border = colors.gray,
    buttonBg = colors.lightGray,
    buttonFg = colors.black,
    buttonFocusBg = colors.gray,
    buttonFocusFg = colors.white,
})
```

**Parameters:**
- `name` (string): Unique theme name
- `colors` (table): Color table with all required keys

**Returns:** `boolean` - Success

---

#### `Theme.apply(element, options)`
Apply theme colors to an Opus UI element.

```lua
local button = UI.Button { text = "Click Me" }
Theme.apply(button)  -- Uses current theme's button colors
```

**Parameters:**
- `element` (table): Opus UI element
- `options` (table, optional): Override colors `{ background, text, accent, ... }`

**Notes:**
- Automatically detects Button elements and applies button-specific colors
- Safe to call on elements that already have colors set (won't override unless option specified)

---

## 2. Named Glyph Map (`glyphs.lua`)

A comprehensive reference for CC:Tweaked's 256-character font. All glyphs use `string.char(code)` to avoid UTF-8 mangling.

### Glyph Categories

#### Box Drawing (192-218)

```lua
local Glyphs = require('ami.lib.ui.glyphs')

-- Single-line borders
Glyphs.BOX_TL         -- ┌ Top-left corner
Glyphs.BOX_TR         -- ┐ Top-right corner
Glyphs.BOX_BL         -- └ Bottom-left corner
Glyphs.BOX_BR         -- ┘ Bottom-right corner
Glyphs.BOX_H          -- ─ Horizontal line
Glyphs.BOX_V          -- │ Vertical line
Glyphs.BOX_CROSS      -- ┼ Four-way intersection
Glyphs.BOX_T_DOWN     -- ┬ T pointing down
Glyphs.BOX_T_UP       -- ┴ T pointing up
Glyphs.BOX_T_RIGHT    -- ├ T pointing right
Glyphs.BOX_T_LEFT     -- ┤ T pointing left

-- Double-line borders
Glyphs.BOX_DOUBLE_TL  -- ╔
Glyphs.BOX_DOUBLE_TR  -- ╗
Glyphs.BOX_DOUBLE_BL  -- ╚
Glyphs.BOX_DOUBLE_BR  -- ╝
Glyphs.BOX_DOUBLE_H   -- ═
Glyphs.BOX_DOUBLE_V   -- ║
```

#### Block Characters (176-178, 219-223)

```lua
Glyphs.SHADE_LIGHT    -- ░ Light shade
Glyphs.SHADE_MEDIUM   -- ▒ Medium shade
Glyphs.SHADE_DARK     -- ▓ Dark shade
Glyphs.BLOCK_FULL     -- █ Full block
Glyphs.BLOCK_BOTTOM   -- ▄ Bottom half
Glyphs.BLOCK_LEFT     -- ▌ Left half
Glyphs.BLOCK_RIGHT    -- ▐ Right half
Glyphs.BLOCK_TOP      -- ▀ Top half
```

#### Arrows (16-31)

```lua
Glyphs.ARROW_RIGHT    -- ►
Glyphs.ARROW_LEFT     -- ◄
Glyphs.ARROW_UP       -- ↑
Glyphs.ARROW_DOWN     -- ↓
Glyphs.ARROW_UD       -- ↕ Up-down
Glyphs.ARROW_LR       -- ↔ Left-right
Glyphs.TRIANGLE_UP    -- ▲
Glyphs.TRIANGLE_DOWN  -- ▼
```

#### Card Suits (3-6)

```lua
Glyphs.HEART          -- ♥
Glyphs.DIAMOND        -- ♦
Glyphs.CLUB           -- ♣
Glyphs.SPADE          -- ♠
```

#### Symbols (misc)

```lua
Glyphs.DOT            -- • Small bullet
Glyphs.BULLET         -- ∙ Middle dot
Glyphs.CIRCLE_OPEN    -- ○ Open circle
Glyphs.DEGREE         -- °
Glyphs.PLUS_MINUS     -- ±
Glyphs.CHECKMARK      -- √
Glyphs.CROWN          -- ⌂ Crown/house
Glyphs.COIN           -- ○ Coin (circle)
```

#### Fan Animation Frames

```lua
Glyphs.FAN_FRAME_1    -- │ Vertical
Glyphs.FAN_FRAME_2    -- / Diagonal 1
Glyphs.FAN_FRAME_3    -- ─ Horizontal
Glyphs.FAN_FRAME_4    -- \ Diagonal 2
```

#### 2x3 Teletext Blocks (128-159)

Sub-character 2×3 block patterns. Each glyph represents 6 subpixels.

```lua
-- Access by bit pattern (0-63)
Glyphs.TELETEXT.map[0]    -- All off
Glyphs.TELETEXT.map[63]   -- All on (0x3F)

-- Common patterns
Glyphs.TELETEXT_EMPTY      -- All off
Glyphs.TELETEXT_FULL       -- All on
Glyphs.TELETEXT_TOP_HALF   -- Top 2 pixels
Glyphs.TELETEXT_BOT_HALF   -- Bottom 2 pixels
Glyphs.TELETEXT_LEFT_FULL  -- Left column
Glyphs.TELETEXT_RIGHT_FULL -- Right column
```

**Bit pattern:** `0x01=TL, 0x02=TR, 0x04=ML, 0x08=MR, 0x10=BL, 0x20=BR`

### Helper Functions

#### `Glyphs.render(glyph, fg, bg)`
Render a glyph with colors for blit-ready output.

```lua
local char, fgBlit, bgBlit = Glyphs.render(Glyphs.HEART, colors.red, colors.white)
-- Returns: "♥", "e", "0"
```

**Parameters:**
- `glyph` (string): Glyph character
- `fg` (number, optional): Foreground color (default: white)
- `bg` (number, optional): Background color (default: black)

**Returns:** `string, string, string` - Character, fg blit char, bg blit char

---

#### `Glyphs.getTeletextBlock(pattern)`
Get a 2×3 teletext block by bit pattern.

```lua
local block = Glyphs.getTeletextBlock(0x15)  -- Left column (TL+ML+BL)
```

**Parameters:**
- `pattern` (number): Bit pattern (0-63)

**Returns:** `string` - Glyph character

---

#### `Glyphs.buildBar(fillPercent, width)`
Build a horizontal bar using full-block characters.

```lua
local bar = Glyphs.buildBar(75, 10)  -- "███████   " (7.5 rounded to 7)
```

**Parameters:**
- `fillPercent` (number): Fill percentage (0-100)
- `width` (number): Width in characters

**Returns:** `string` - Bar string

---

#### `Glyphs.getCardSuit(suit)`
Get the glyph for a card suit.

```lua
local suitGlyph = Glyphs.getCardSuit("heart")  -- "♥"
```

**Parameters:**
- `suit` (string): "heart", "diamond", "club", "spade" (or "h", "d", "c", "s")

**Returns:** `string` - Suit glyph

---

#### `Glyphs.getCardSuitColor(suit)`
Get the CC color for a card suit (red or black).

```lua
local color = Glyphs.getCardSuitColor("heart")  -- colors.red
```

**Parameters:**
- `suit` (string): Suit name

**Returns:** `number` - `colors.red` or `colors.black`

---

#### `Glyphs.getFanFrame(frameIndex)`
Get a fan blade glyph for animation (cycles through 4 frames).

```lua
local frame = Glyphs.getFanFrame(1)  -- "│"
```

**Parameters:**
- `frameIndex` (number): Frame index (1-4, wraps)

**Returns:** `string` - Fan glyph

---

## 3. Custom Widgets

All widgets extend `UI.Window` and integrate with Opus UI's rendering pipeline.

### Gauge (`widgets/gauge.lua`)

Horizontal progress bar with tier-based colors and sub-character precision.

#### Constructor

```lua
local gauge = UI.Gauge {
    x = 2,
    y = 5,
    width = 20,        -- Bar width
    value = 50,        -- Current value
    max = 100,         -- Maximum value
    showValue = true,  -- Show "50/100" text
    showLabel = false, -- Show label above bar
    label = "HP",      -- Label text
    borderColor = nil, -- Optional border (nil = no border)
}
```

#### Properties

| Property | Type | Default | Description |
|----------|------|---------|-------------|
| `width` | number | 20 | Width in characters |
| `height` | number | 1 | Height (auto-adjusts for label/border) |
| `value` | number | 0 | Current value |
| `max` | number | 100 | Maximum value |
| `label` | string | '' | Label text |
| `showLabel` | boolean | true | Display label above bar |
| `showValue` | boolean | true | Display value text overlay |
| `tierLow` | number | 33 | Low tier threshold (%) |
| `tierMid` | number | 66 | Mid tier threshold (%) |
| `tierHigh` | number | 90 | High tier threshold (%) |
| `colorLow` | color | lime | Color when <33% |
| `colorMid` | color | yellow | Color when 33-66% |
| `colorHigh` | color | orange | Color when 66-90% |
| `colorCrit` | color | red | Color when >90% |
| `borderColor` | color/nil | nil | Border color (nil = no border) |

#### Methods

##### `gauge:setValue(value)`
Update the gauge value (clamped to 0-max).

```lua
gauge:setValue(75)  -- Updates and redraws
```

##### `gauge:setMax(max)`
Change the maximum value.

```lua
gauge:setMax(200)
```

##### `gauge:setTier(percent, color)`
Override a tier color.

```lua
gauge:setTier(50, colors.blue)  -- Mid tier now blue
```

#### Example

```lua
local healthBar = UI.Gauge {
    x = 2, y = 10,
    width = 30,
    value = 80,
    max = 100,
    label = "Health",
    showValue = true,
}

-- Later...
healthBar:setValue(20)  -- Bar turns red (<33%)
```

---

### Fan (`widgets/fan.lua`)

**Parametric sine-wave cooling fan** with upgrade level scaling. Replaces simple 4-frame animation with mathematical rendering using blade count, radius, twist (spiral curve), and speed.

#### Core Algorithm

The fan is rendered using a parametric sine-wave equation applied to each cell:

```
s = sin(BLADES × angle + TWIST × distance + rotation)
```

Where:
- **BLADES**: Number of fan blades (controls frequency)
- **TWIST**: Spiral curve factor (0 = straight spokes, >0 = curved blades)
- **distance**: Cell's distance from hub `√(dx² + dy²)`
- **angle**: Direction from hub `atan2(dy, dx)`
- **rotation**: Current rotation angle (increments each frame)

The sine value `s` maps to shade characters:
- `s > 0.55`: █ (full block) - solid blade
- `s > 0.15`: ▓ (dark shade) - blade edge
- `s > -0.2`: ▒ (medium shade) - blade falloff
- `s ≤ -0.2`: space - air/gap

Special cases:
- `distance < 0.1 × RADIUS`: Force solid (█) - hub
- `distance > RADIUS`: Force blank - outside disc

#### Constructor

```lua
local fan = UI.Fan {
    x = 10,
    y = 5,
    level = 1,         -- Air cooler upgrade level (1-10)
    spinning = false,  -- Start stopped
    fps = 30,          -- Animation speed (1-60 FPS)
    color = colors.lightBlue,
    direction = 1,     -- +1 = clockwise, -1 = counter-clockwise
}
```

Dimensions are auto-calculated from level preset:
- `width = radius × 2 × ASPECT + 1` (ASPECT = 2.0 for char cell ratio)
- `height = radius × 2 + 1`

#### Properties

| Property | Type | Default | Description |
|----------|------|---------|-------------|
| `level` | number | 1 | Upgrade level (1-10), sets preset |
| `spinning` | boolean | false | Is fan spinning |
| `fps` | number | 30 | Animation speed (1-60 FPS) |
| `color` | color | lightGray | Fan blade color |
| `direction` | number | 1 | Rotation direction (+1/-1) |
| `blades` | number | 2 | Blade count (from preset) |
| `radius` | number | 5 | Fan radius in cells (from preset) |
| `twist` | number | 0.0 | Spiral factor (from preset) |
| `speed` | number | 1.0 | Rotation speed multiplier (from preset) |
| `rotation` | number | 0 | Current angle in radians (internal) |

#### Upgrade Presets

Each level defines blade count, radius, twist, and speed:

| Level | Blades | Radius | Twist | Speed | Size (cols × rows) |
|-------|--------|--------|-------|-------|-------------------|
| 1     | 2      | 5      | 0.0   | 1.0x  | 21 × 11           |
| 2     | 3      | 6      | 0.1   | 1.2x  | 25 × 13           |
| 3     | 3      | 7      | 0.15  | 1.4x  | 29 × 15           |
| 4     | 4      | 8      | 0.2   | 1.6x  | 33 × 17           |
| 5     | 4      | 9      | 0.25  | 1.8x  | 37 × 19           |
| 6     | 5      | 10     | 0.3   | 2.0x  | 41 × 21           |
| 7     | 5      | 11     | 0.35  | 2.2x  | 45 × 23           |
| 8     | 6      | 12     | 0.4   | 2.5x  | 49 × 25           |
| 9     | 6      | 13     | 0.45  | 2.8x  | 53 × 27           |
| 10    | 7      | 14     | 0.5   | 3.0x  | 57 × 29           |

Higher levels produce larger, faster, more complex fans with curved blades.

#### Methods

##### `fan:start()`
Start the fan animation.

```lua
fan:start()
```

##### `fan:stop()`
Stop the fan animation (renders static stopped state).

```lua
fan:stop()
```

##### `fan:setSpeed(fps)`
Change animation speed (clamped 1-60 FPS).

```lua
fan:setSpeed(45)  -- Smooth 45 FPS
```

##### `fan:setLevel(level)`
Set upgrade level (1-10) and apply preset. Auto-recalculates dimensions and redraws.

```lua
fan:setLevel(5)  -- 4 blades, radius 9, twisted
```

**Parameters:**
- `level` (number): Upgrade level (clamped to 1-10)

**Effect:**
- Updates `blades`, `radius`, `twist`, `speed` from preset
- Recalculates `width` and `height`
- Redraws if spinning

##### `fan:setDirection(dir)`
Set rotation direction.

```lua
fan:setDirection(1)   -- Clockwise
fan:setDirection(-1)  -- Counter-clockwise
```

**Parameters:**
- `dir` (number): +1 for clockwise, -1 for counter-clockwise

#### Integration with Node Upgrades

Query `air_cooler` upgrade level and apply to fan:

```lua
local upgrades = require("upgrades")

-- Get upgrade level (0-10)
local airCoolerLevel = upgrades.getLevel("air_cooler")

if airCoolerLevel > 0 then
    fan:setLevel(airCoolerLevel)
    fan:start()
else
    fan:stop()  -- No cooling = no fan
end
```

See `ami/lib/ui/widgets/fan_integration_example.lua` for complete examples.

#### Performance Notes

- Uses timer-based rendering (non-blocking, parallel-safe)
- Only updates its own cells (flicker-free dirty-region rendering)
- Higher levels render more cells (radius²), may lag on slow computers
- Default 30 FPS is smooth; reduce to 15-20 FPS if lagging

#### Notes

- Uses `os.startTimer` for animation frames
- Only updates its own cell (flicker-free)
- Stops cleanly when `spinning = false`
- Shows static blade when stopped

#### Example

```lua
local coolingFan = UI.Fan {
    x = 5, y = 5,
    spinning = true,
    fps = 8,
    color = colors.lightBlue,
}

-- Control fan based on temperature
if temperature > 80 then
    coolingFan:start()
else
    coolingFan:stop()
end
```

---

### Card (`widgets/card.lua`)

Playing card face for card games (Blackjack, Poker, etc.).

#### Constructor

```lua
local card = UI.Card {
    x = 10,
    y = 5,
    width = 7,       -- Card width
    height = 5,      -- Card height
    suit = 'heart',  -- 'heart', 'diamond', 'club', 'spade'
    rank = 'A',      -- 'A', '2'-'10', 'J', 'Q', 'K'
    faceUp = true,   -- Show face (true) or back (false)
}
```

#### Properties

| Property | Type | Default | Description |
|----------|------|---------|-------------|
| `width` | number | 7 | Card width |
| `height` | number | 5 | Card height |
| `suit` | string | 'spade' | Card suit |
| `rank` | string | 'A' | Card rank |
| `faceUp` | boolean | true | Face-up (true) or face-down (false) |
| `cardColor` | color | white | Card face color |
| `backColor` | color | blue | Card back primary color |
| `backPattern` | color | lightBlue | Card back pattern color |

#### Methods

##### `card:flip()`
Flip the card (face-up ↔ face-down).

```lua
card:flip()
```

##### `card:setSuit(suit)`
Change the card suit.

```lua
card:setSuit("diamond")
```

##### `card:setRank(rank)`
Change the card rank.

```lua
card:setRank("K")
```

##### `card:setCard(suit, rank)`
Change both suit and rank at once.

```lua
card:setCard("club", "7")
```

#### Example

```lua
-- Dealer's card (face-down)
local dealerCard = UI.Card {
    x = 5, y = 5,
    suit = 'spade',
    rank = 'K',
    faceUp = false,  -- Hidden
}

-- Player's card (face-up)
local playerCard = UI.Card {
    x = 15, y = 5,
    suit = 'heart',
    rank = 'A',
    faceUp = true,
}

-- Reveal dealer card
dealerCard:flip()
```

---

## 4. Opus UI Components (Used in Demo)

These are standard Opus UI components we use from the vendored library:

### `UI.Button`
Clickable button with focus states.

```lua
UI.Button {
    x = 10, y = 5,
    text = "Click Me",
    event = 'button_clicked',  -- Custom event name
}
```

### `UI.Text`
Static text label.

```lua
UI.Text {
    x = 2, y = 2,
    value = "Hello World",
    textColor = colors.yellow,
}
```

### `UI.StatusBar`
Multi-column status bar.

```lua
UI.StatusBar {
    y = 1,
    columns = {
        { key = 'title', width = 20 },
        { key = 'status', width = 10 },
    }
}

-- Update values
statusBar.values = { title = "App", status = "OK" }
statusBar:draw()
```

### `UI.Page`
Top-level container for UI elements.

```lua
local page = UI.Page {
    backgroundColor = colors.black,
    button1 = UI.Button { ... },
    text1 = UI.Text { ... },
}
```

### `UI.SlideOut`
Slide-in/out panel (for dialogs, menus).

```lua
local slideOut = UI.SlideOut {
    titleBar = UI.TitleBar { title = "Dialog" },
    -- ... content ...
}

slideOut:show()  -- Slide in
slideOut:hide()  -- Slide out
```

---

## 5. Integration Example

Complete example showing how to use all Stage 1 components:

```lua
local UI     = require('ami.lib.ui.ui')
local Theme  = require('ami.lib.ui.theme')
local Glyphs = require('ami.lib.ui.glyphs')

-- Load widgets
require('ami.lib.ui.widgets.gauge')
require('ami.lib.ui.widgets.fan')
require('ami.lib.ui.widgets.card')

-- Set theme
Theme.setTheme("matrix")

-- Build app
local app = UI.Page {
    backgroundColor = Theme.getColor('background'),
    
    title = UI.Text {
        x = 2, y = 2,
        value = "My Casino App",
        textColor = Theme.getColor('accent'),
    },
    
    healthBar = UI.Gauge {
        x = 2, y = 5,
        width = 20,
        value = 100,
        max = 100,
        label = "HP",
    },
    
    coolingFan = UI.Fan {
        x = 30, y = 5,
        spinning = true,
    },
    
    playerCard = UI.Card {
        x = 2, y = 10,
        suit = 'heart',
        rank = 'A',
        faceUp = true,
    },
    
    hitBtn = UI.Button {
        x = 2, y = 16,
        text = "Hit",
        event = 'hit',
    },
}

-- Apply theme to buttons
Theme.apply(app.hitBtn)

function app:eventHandler(event)
    if event.type == 'hit' then
        -- Deal card logic
        self.playerCard:setCard('diamond', '7')
        return true
    elseif event.type == 'key' and event.key == 'q' then
        self:exitPullEvents()
        return true
    end
end

-- Run
app:run()
```

---

## 6. Best Practices

### Theme Switching

Always redraw after changing themes:

```lua
Theme.setTheme("crown_gold")
app:applyTheme()  -- Update all component colors
app:draw()        -- Redraw UI
```

### Widget Performance

- Widgets only redraw their own cells (flicker-free)
- Use `:setValue()` instead of direct property modification
- Gauge animation: Use timers, not tight loops

### Glyph Usage

- Always use `string.char(code)`, never literal high bytes
- Use helper functions (`getCardSuit`, `buildBar`) when available
- Test glyphs on Advanced Computer (basic terminals may not support all)

### Parallel Integration

Widgets work seamlessly with `parallel.waitForAny`:

```lua
parallel.waitForAny(
    function() app:pullEvents() end,
    backgroundTask  -- Won't block UI
)
```

---

## 7. Testing

Run the Stage 1 demo to see all features:

```
cd /ami/lib/ui
_demo2.lua
```

**Controls:**
- **Tab**: Navigate between elements
- **Enter**: Activate focused button
- **Q**: Quit
- **Page 1**: Animate gauges, test theme colors
- **Page 2**: Start/stop fan, flip cards, open theme dialog

---

## 8. Future Enhancements (Stage 2+)

- Animated card flip (multi-frame)
- Vertical gauges
- More teletext block helpers (sprite rendering)
- Additional themes (emerald, ruby, sapphire)
- Theme editor UI
- Gradient backgrounds using teletext blocks

---

**End of Stage 1 API Documentation**
