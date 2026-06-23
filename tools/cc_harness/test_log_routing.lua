-- tools/cc_harness/test_log_routing.lua
-- Verifies that print() routes into the dashboard's Node Log panel when the UI
-- is active (mirrors the real gate logic in node/startup.lua).
local shim = dofile("tools/cc_harness/shim.lua")

local UI = require("ami.lib.ui.ui")
local Theme = require("ami.lib.ui.theme"); Theme.setTheme("demon")
require("ami.lib.ui.widgets.gauge")
local nodeUI = require("node_ui")
UI:disableEffects()

-- Replicate the startup.lua gate + nodeLog.
local uiActive = false
local logSink
local realPrint = _G.print
_G.print = function(...)
  if uiActive then
    if logSink then
      local parts = {}
      for i = 1, select('#', ...) do parts[i] = tostring((select(i, ...))) end
      logSink(table.concat(parts, ' '))
    end
  else return realPrint(...) end
end

local page = nodeUI.createDashboard("fae5dacd0f07a37911fe027808e0132e", "6.1")
local LOG_LINES = 14
local logBuf = {}
local function nodeLog(line)
  logBuf[#logBuf+1] = tostring(line)
  while #logBuf > LOG_LINES do table.remove(logBuf, 1) end
  if uiActive and page.logPanel then
    for i = 1, LOG_LINES do
      local w = page.logPanel['logLine'..i]
      if w then w.value = logBuf[i] or '' end
    end
    page.logPanel:draw(); page.logPanel:sync()
  end
end
logSink = nodeLog

UI:setPage(page)
uiActive = true

-- Simulate background-thread prints (as miner/net would do).
print("[Miner] Tick #13235 | Rate: 50 uAMI")
print("[Net] BALANCE c958... -> 95882104 uAMI")
print("[Net] TRANSFER alice -> bob 1000 uAMI OK")

-- Confirm they landed in the panel widgets, not the terminal scroll.
local out = realPrint
out("logLine1:", page.logPanel.logLine1.value)
out("logLine2:", page.logPanel.logLine2.value)
out("logLine3:", page.logPanel.logLine3.value)
assert(page.logPanel.logLine1.value:find("Tick"),     "log line 1 should be the Miner tick print")
assert(page.logPanel.logLine3.value:find("TRANSFER"), "log line 3 should be the TRANSFER print")

-- Now overflow past 14 lines and confirm it scrolls (oldest drops off).
-- (print is still the routed version here, so these feed the log.)
for i = 1, 14 do print("[Net] filler " .. i) end
assert(page.logPanel.logLine14.value:find("filler 14"), "newest line should be at bottom after overflow")
assert(not page.logPanel.logLine1.value:find("Tick"), "oldest line should have scrolled off")
out("PASS: print() routes into the Node Log panel; scrolls correctly; no terminal scroll")
