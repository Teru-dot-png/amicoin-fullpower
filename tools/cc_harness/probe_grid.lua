-- tools/cc_harness/probe_grid.lua
local shim = dofile("tools/cc_harness/shim.lua")

local UI = require("ami.lib.ui.ui")
local Theme = require("ami.lib.ui.theme"); Theme.setTheme("demon")
require("ami.lib.ui.widgets.fan")
require("ami.lib.ui.widgets.gauge")
local nodeUI = require("node_ui")
UI:disableEffects()

-- Instrument ScrollBar:draw
local drawCalls = 0
local origSBdraw = UI.ScrollBar.draw
UI.ScrollBar.draw = function(self)
  drawCalls = drawCalls + 1
  local view = self.parent:getViewArea()
  if drawCalls <= 5 or drawCalls % 100000 == 0 then
    io.write(string.format("ScrollBar:draw #%d  view={height=%s, totalHeight=%s, offsetY=%s, y=%s, static=%s}  self.height=%s parent.pageSize=%s\n",
      drawCalls, tostring(view.height), tostring(view.totalHeight),
      tostring(view.offsetY), tostring(view.y), tostring(view.static),
      tostring(self.height), tostring(self.parent.pageSize)))
    io.flush()
  end
  if drawCalls > 50 then error("ScrollBar:draw called >50 times -> re-entrant loop") end
  return origSBdraw(self)
end

local page = nodeUI.createDashboard("fae5dacd0f07a37911fe027808e0132e", "5.7")
print("created page; grid pageSize before enable =", tostring(page.upgradesPanel.upgradesList.pageSize))
print("grid height =", tostring(page.upgradesPanel.upgradesList.height))

debug.sethook(function() error("BUDGET\n"..debug.traceback(),2) end, "", 30000000)
local ok, err = pcall(function() UI:setPage(page) end)
debug.sethook()
print("setPage ok=", ok, "err=", err)
print("total ScrollBar:draw calls =", drawCalls)
