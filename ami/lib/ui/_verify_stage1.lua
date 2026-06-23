-- Stage 1 Verification Script
-- Quick test of theme, glyphs, and widgets

local Theme  = require('ami.lib.ui.theme')
local Glyphs = require('ami.lib.ui.glyphs')

print("=== Stage 1 Component Verification ===")
print()

-- Test Theme System
print("1. THEME SYSTEM")
print("  Available themes:")
local themes = Theme.listThemes()
for _, name in ipairs(themes) do
    print("    - " .. name)
end
print("  Current theme: " .. Theme.getThemeName())
print("  Setting theme to 'matrix'...")
Theme.setTheme("matrix")
local theme = Theme.getTheme()
print("  Accent color: " .. tostring(theme.accent))
print()

-- Test Glyphs
print("2. GLYPH SYSTEM")
print("  Box drawing: " .. Glyphs.BOX_TL .. Glyphs.BOX_H .. Glyphs.BOX_TR)
print("  Card suits: " .. Glyphs.HEART .. " " .. Glyphs.DIAMOND .. " " .. Glyphs.CLUB .. " " .. Glyphs.SPADE)
print("  Blocks: " .. Glyphs.BLOCK_FULL .. Glyphs.SHADE_DARK .. Glyphs.SHADE_MEDIUM .. Glyphs.SHADE_LIGHT)
print("  Arrows: " .. Glyphs.ARROW_UP .. Glyphs.ARROW_DOWN .. Glyphs.ARROW_LEFT .. Glyphs.ARROW_RIGHT)
print("  Bar test (50%): " .. Glyphs.buildBar(50, 10))
print()

-- Test Widget Modules
print("3. WIDGET MODULES")
local success, Gauge = pcall(require, 'ami.lib.ui.widgets.gauge')
print("  Gauge widget: " .. (success and "OK" or "FAIL"))

success, Fan = pcall(require, 'ami.lib.ui.widgets.fan')
print("  Fan widget: " .. (success and "OK" or "FAIL"))

success, Card = pcall(require, 'ami.lib.ui.widgets.card')
print("  Card widget: " .. (success and "OK" or "FAIL"))
print()

print("=== Stage 1 Verification Complete ===")
print("Run '_demo2.lua' to see interactive demo")
