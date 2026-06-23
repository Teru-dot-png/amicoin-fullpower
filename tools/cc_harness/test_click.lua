-- tools/cc_harness/test_click.lua
-- Verifies the Opus event pipeline: inject a mouse_click on the wallet's
-- "Send AMI" button and confirm its 'action_send' event fires (no crash).
local shim = dofile("tools/cc_harness/shim.lua")

local UI    = require("ami.lib.ui.ui")
local Event = require("ami.lib.ui.event")
local Theme = require("ami.lib.ui.theme"); Theme.setTheme("demon")
local WalletUI = require("wallet.wallet_ui")
UI:disableEffects()

local page = WalletUI.createDashboard("fae5dacd0f07a37911fe027808e0132e", "alice")

-- Capture button events at the page level.
local fired = {}
page.eventHandler = function(self, event)
  if event.type and event.type:match("^action_") then
    fired[#fired+1] = event.type
  end
  return UI.Page.eventHandler(self, event)
end

UI:setPage(page)

-- sendBtn: actionsPanel x=1,y=11 ; button x=2,y=1,w=12,h=3 -> screen ~ (5,12)
print("Injecting mouse_click at (5,12) [Send AMI], (18,12) [Receive], terminate")
shim.injectEvent("mouse_click", 1, 5, 12)
shim.injectEvent("mouse_up", 1, 5, 12)
shim.injectEvent("mouse_click", 1, 18, 12)
shim.injectEvent("mouse_up", 1, 18, 12)
shim.injectEvent("terminate")

local ok, err = pcall(function() UI:pullEvents() end)
print("pullEvents ok =", ok, err and ("err="..tostring(err)) or "")
print("events fired:", #fired == 0 and "(none)" or table.concat(fired, ", "))
