-- AmiCoin Theme System
-- Swappable color themes for UI components
-- Extends Opus UI with named color palettes

local colors = _G.colors

local Theme = {}

-- Current active theme
local currentTheme = "default"

-- Theme registry
local themes = {}

-- Theme color keys (all themes must provide these)
local REQUIRED_KEYS = {
    "background",       -- Main background
    "panel",            -- Panel/window background
    "accent",           -- Accent/highlight color
    "ok",               -- Success/positive
    "warn",             -- Warning
    "danger",           -- Error/critical
    "text",             -- Primary text
    "textDim",          -- Secondary/dimmed text
    "border",           -- Border lines
    "buttonBg",         -- Button background
    "buttonFg",         -- Button text
    "buttonFocusBg",    -- Focused button background
    "buttonFocusFg",    -- Focused button text
}

-- Default theme: Classic CC colors
themes.default = {
    background = colors.black,
    panel = colors.gray,
    accent = colors.lime,
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
}

-- Matrix theme: Green phosphor (matches node's matrix_ui)
themes.matrix = {
    background = colors.black,
    panel = colors.gray,
    accent = colors.green,
    ok = colors.lime,
    warn = colors.yellow,
    danger = colors.red,
    text = colors.lime,
    textDim = colors.green,
    border = colors.green,
    buttonBg = colors.green,
    buttonFg = colors.black,
    buttonFocusBg = colors.lime,
    buttonFocusFg = colors.black,
}

-- Crown Gold theme: Gold/yellow prestige (matches node's prestige_crown)
themes.crown_gold = {
    background = colors.black,
    panel = colors.gray,
    accent = colors.yellow,
    ok = colors.lime,
    warn = colors.orange,
    danger = colors.red,
    text = colors.yellow,
    textDim = colors.orange,
    border = colors.yellow,
    buttonBg = colors.orange,
    buttonFg = colors.black,
    buttonFocusBg = colors.yellow,
    buttonFocusFg = colors.black,
}

-- Ice Blue theme: Cyan/light blue
themes.ice_blue = {
    background = colors.black,
    panel = colors.gray,
    accent = colors.lightBlue,
    ok = colors.lime,
    warn = colors.yellow,
    danger = colors.red,
    text = colors.lightBlue,
    textDim = colors.cyan,
    border = colors.cyan,
    buttonBg = colors.cyan,
    buttonFg = colors.black,
    buttonFocusBg = colors.lightBlue,
    buttonFocusFg = colors.black,
}

-- Void Red theme: Red/orange danger
themes.void_red = {
    background = colors.black,
    panel = colors.gray,
    accent = colors.red,
    ok = colors.lime,
    warn = colors.orange,
    danger = colors.red,
    text = colors.orange,
    textDim = colors.red,
    border = colors.red,
    buttonBg = colors.red,
    buttonFg = colors.white,
    buttonFocusBg = colors.orange,
    buttonFocusFg = colors.white,
}

-- Demon theme: Professional red/crimson for AMI (the demon currency)
-- Primary red UI with dark backgrounds, lime success indicators
themes.demon = {
    background = colors.black,
    panel = colors.gray,
    accent = colors.red,
    ok = colors.lime,
    warn = colors.yellow,
    danger = colors.orange,
    text = colors.white,
    textDim = colors.lightGray,
    border = colors.red,
    buttonBg = colors.red,
    buttonFg = colors.white,
    buttonFocusBg = colors.orange,
    buttonFocusFg = colors.white,
}

--- Register a new theme
-- @param name string Theme name
-- @param colors table Color table with all required keys
-- @return boolean Success
function Theme.registerTheme(name, colorTable)
    if type(name) ~= "string" or name == "" then
        error("Theme name must be a non-empty string", 2)
    end
    if type(colorTable) ~= "table" then
        error("Theme colors must be a table", 2)
    end
    
    -- Validate all required keys are present
    for _, key in ipairs(REQUIRED_KEYS) do
        if colorTable[key] == nil then
            error("Theme missing required color: " .. key, 2)
        end
    end
    
    themes[name] = colorTable
    return true
end

--- Set the active theme
-- @param name string Theme name
-- @return boolean Success
function Theme.setTheme(name)
    if not themes[name] then
        error("Unknown theme: " .. tostring(name), 2)
    end
    currentTheme = name
    return true
end

--- Get the current theme table
-- @return table Current theme colors
function Theme.getTheme()
    return themes[currentTheme]
end

--- Get the current theme name
-- @return string Theme name
function Theme.getThemeName()
    return currentTheme
end

--- Get a specific color from the current theme
-- @param key string Color key
-- @return number CC color value
function Theme.getColor(key)
    local theme = themes[currentTheme]
    if not theme then
        error("No active theme", 2)
    end
    local color = theme[key]
    if color == nil then
        error("Unknown color key: " .. tostring(key), 2)
    end
    return color
end

--- List all available themes
-- @return table Array of theme names
function Theme.listThemes()
    local list = {}
    for name, _ in pairs(themes) do
        table.insert(list, name)
    end
    table.sort(list)
    return list
end

--- Apply theme to an Opus UI element
-- Convenience function to apply theme colors to common element properties
-- @param element table Opus UI element
-- @param options table Optional overrides { background, text, accent, ... }
function Theme.apply(element, options)
    local theme = themes[currentTheme]
    options = options or {}
    
    if element.backgroundColor == nil or options.background then
        element.backgroundColor = options.background or theme.background
    end
    if element.textColor == nil or options.text then
        element.textColor = options.text or theme.text
    end
    if options.accent then
        element.accentColor = options.accent
    end
    if options.ok then
        element.okColor = options.ok
    end
    if options.warn then
        element.warnColor = options.warn
    end
    if options.danger then
        element.dangerColor = options.danger
    end
    
    -- Button-specific
    if element.UIElement == "Button" then
        element.backgroundColor = options.buttonBg or theme.buttonBg
        element.textColor = options.buttonFg or theme.buttonFg
        element.backgroundFocusColor = options.buttonFocusBg or theme.buttonFocusBg
        element.textFocusColor = options.buttonFocusFg or theme.buttonFocusFg
    end
end

return Theme
