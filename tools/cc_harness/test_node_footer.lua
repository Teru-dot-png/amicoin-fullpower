-- tools/cc_harness/test_node_footer.lua
-- Traces: (1) a footer-button CLICK queues the same 'ami_action' a keypress would
-- run, and (2) a long log message word-wraps on a boundary in the Node Log panel.
local shim = dofile("tools/cc_harness/shim.lua")

local UI = require("ami.lib.ui.ui")
local Theme = require("ami.lib.ui.theme"); Theme.setTheme("demon")
local Util = require("ami.lib.ui.util")
require("ami.lib.ui.widgets.gauge")
local nodeUI = require("node_ui")
UI:disableEffects()

local page = nodeUI.createDashboard("fae5dacd0f07a37911fe027808e0132e", "test")
UI:setPage(page)

-- ── TRACE 1: click the [P]Shop footer button -> 'ami_action' "p" ──
-- footerBar x=1,y=19 ; btnShop x=14,w=12 -> screen cols 14..25 on row 19.
print("== TRACE 1: footer [P]Shop click ==")
local captured = {}
local realQueue = os.queueEvent
os.queueEvent = function(name, ...)
  if name == "ami_action" then captured[#captured+1] = select(1, ...) end
  return realQueue(name, ...)
end
shim.injectEvent("mouse_click", 1, 18, 19)
shim.injectEvent("mouse_up", 1, 18, 19)
shim.injectEvent("terminate")
pcall(function() UI:pullEvents() end)
os.queueEvent = realQueue
print("  click(18,19) on [P]Shop -> ami_action queued:", table.concat(captured, ",") )
assert(captured[1] == "p", "footer [P] click should queue ami_action 'p'")
print("  PASS: mouse click routes to the SAME action key as pressing P")

-- ── TRACE 2: long log line wraps on a word boundary ──
print("\n== TRACE 2: log word-wrap ==")
local long = "[Miner] Proof-of-Uptime daemon reward interval thirty seconds"
local lines = Util.wordWrap(long, 22)
for i, l in ipairs(lines) do print(string.format("  %2d |%s|", i, l)) end
-- assert no line exceeds width and no word is split across a space-break
for _, l in ipairs(lines) do assert(#l <= 22, "wrapped line exceeds 22 cols") end
assert(lines[1] == "[Miner]" or lines[1]:match("^%[Miner%]"), "first line keeps the tag")
-- confirm a specific word boundary: 'Proof-of-Uptime' is not chopped mid-token
local joined = table.concat(lines, " ")
assert(joined:find("Proof%-of%-Uptime"), "Proof-of-Uptime survives intact across wrap")
print("  PASS: wraps on spaces, every line <= 22 cols, 'Proof-of-Uptime' intact")
