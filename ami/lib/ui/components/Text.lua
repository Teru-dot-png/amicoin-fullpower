local class = require('ami.lib.ui.class')
local Util  = require('ami.lib.ui.util')

UI.Text = class(UI.Window)
UI.Text.defaults = {
	UIElement = 'Text',
	value = '',
	height = 1,
}
function UI.Text:setParent()
	if not self.width and not self.ex then
		self.width = #tostring(self.value)
	end
	UI.Window.setParent(self)
end

function UI.Text:draw()
	self:write(1, 1, Util.widthify(self.value, self.width, self.align))
end
