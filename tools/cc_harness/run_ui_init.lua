-- tools/cc_harness/run_ui_init.lua
-- Drives the node's Opus UI initialisation under the CC shim, with an
-- instruction-count hook that converts any infinite loop into a traceback.
--
-- Usage: cd repo root && lua tools/cc_harness/run_ui_init.lua

local shim = dofile("tools/cc_harness/shim.lua")

-- Instruction budget watchdog: a full UI init + paint should be a few million
-- instructions. If we blow way past that, we're in an infinite loop.
local BUDGET = tonumber(os.getenv("BUDGET") or "80000000")
local hookCount = 0
local function watchdog()
  hookCount = hookCount + 1
  error("INSTRUCTION BUDGET EXCEEDED (~"..(hookCount*BUDGET)..
        " ops) - likely infinite loop:\n"..debug.traceback("", 2), 2)
end

local function step(label, fn)
  io.write(string.format("[%-22s] ", label)); io.flush()
  debug.sethook(watchdog, "", BUDGET)
  local t0 = os.clock()
  local ok, err = pcall(fn)
  debug.sethook()
  local dt = os.clock() - t0
  if ok then
    print(string.format("OK   (%.3fs)", dt))
    return true
  else
    print(string.format("FAIL (%.3fs)", dt))
    print("  -> " .. tostring(err))
    return false, err
  end
end

print("=== AmiCoin Opus UI init harness ===")
print(string.format("screen %dx%d, budget=%d ops/hook\n", shim.W, shim.H, BUDGET))

local UI, Theme, nodeUI, page

if not step("require ui.ui", function() UI = require("ami.lib.ui.ui") end) then os.exit(1) end
if not step("require theme", function() Theme = require("ami.lib.ui.theme") end) then os.exit(1) end
step("setTheme demon", function() Theme.setTheme("demon") end)
step("require fan widget", function() require("ami.lib.ui.widgets.fan") end)
step("require gauge widget", function() require("ami.lib.ui.widgets.gauge") end)
step("require node_ui", function() nodeUI = require("node_ui") end)
step("UI:disableEffects", function() UI:disableEffects() end)
if not step("createDashboard", function()
  page = nodeUI.createDashboard("fae5dacd0f07a37911fe027808e0132e", "5.9")
end) then os.exit(1) end
step("UI:setPage (paint)", function() UI:setPage(page) end)

print("\n=== Final screen buffer ===")
print(shim.dumpScreen())

-- Populate the grid + start the fan to verify dynamic content renders.
step("populate grid + fan", function()
  page.upgradesPanel.upgradesList:setValues({
    { name = "OvrclkMiner", level = "Lv5" },
    { name = "MintSurge",   level = "Lv3" },
    { name = "WalletBonus", level = "Lv6" },
    { name = "AirCooler",   level = "Lv3" },
  })
  page.thermalPanel.fan:setLevel(3)
  page.thermalPanel.fan:start()
  page.infoPanel.miningRateGauge.value = 90
  page:draw()
  page:sync()
end)
print("\n=== Populated screen buffer ===")
print(shim.dumpScreen())

-- Try a few event-loop iterations (timer-driven fan frames + one click)
print("\n=== pulling a few events ===")
shim.injectEvent("timer", 1)
shim.injectEvent("mouse_click", 1, 5, 10)
shim.injectEvent("terminate")
step("UI:pullEvents (3 evts)", function()
  local ok = pcall(function() UI:pullEvents() end)
  return ok
end)

print("\nDONE.")
