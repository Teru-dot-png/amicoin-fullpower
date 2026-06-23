-- tools/cc_harness/run_wallet_init.lua
-- Drives the wallet Opus UI init headlessly, same watchdog as the node harness.
local shim = dofile("tools/cc_harness/shim.lua")

local BUDGET = tonumber(os.getenv("BUDGET") or "80000000")
local function watchdog()
  error("INSTRUCTION BUDGET EXCEEDED - likely infinite loop:\n"..debug.traceback("", 2), 2)
end
local function step(label, fn)
  io.write(string.format("[%-22s] ", label)); io.flush()
  debug.sethook(watchdog, "", BUDGET)
  local ok, err = pcall(fn)
  debug.sethook()
  if ok then print("OK") return true
  else print("FAIL"); print("  -> "..tostring(err)); return false, err end
end

print("=== AmiCoin Wallet UI init harness ===\n")
local UI, Theme, WalletUI, page
step("require ui.ui", function() UI = require("ami.lib.ui.ui") end)
step("require theme", function() Theme = require("ami.lib.ui.theme"); Theme.setTheme("demon") end)
step("require wallet_ui", function() WalletUI = require("wallet.wallet_ui") end)
step("UI:disableEffects", function() UI:disableEffects() end)
if not step("createDashboard", function()
  page = WalletUI.createDashboard("fae5dacd0f07a37911fe027808e0132e", "alice")
end) then os.exit(1) end
step("UI:setPage (paint)", function() UI:setPage(page) end)
step("updateDashboard", function()
  WalletUI.updateDashboard(page, 12500000, 2, 3, {effective_rate=50, current_rate=50})
end)

print("\n=== Screen buffer ===")
print(shim.dumpScreen())
print("\nDONE.")
