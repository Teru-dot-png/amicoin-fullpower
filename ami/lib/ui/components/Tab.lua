local class = require('ami.lib.ui.class')

local colors = _G.colors

UI.Tab = class(UI.ActiveLayer)
UI.Tab.defaults = {
	UIElement = 'Tab',
	tabTitle = 'tab',
	backgroundColor = colors.cyan,
	y = 2,
}
