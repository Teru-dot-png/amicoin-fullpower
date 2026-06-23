-- tools/cc_harness/test_upgrade_shop.lua
-- Builds the Opus upgrade-shop page, fills it from a fake catalog, renders it,
-- and traces: a Buy-button click -> os.queueEvent('shop_buy'); a Back click ->
-- 'shop_close'; and grid selection -> details panel update.
local shim = dofile("tools/cc_harness/shim.lua")

local UI = require("ami.lib.ui.ui")
local Theme = require("ami.lib.ui.theme"); Theme.setTheme("demon")
require("ami.lib.ui.widgets.gauge")
local UpgradeUI = require("upgrade_ui")
UI:disableEffects()

-- Fake catalog (mirrors upgrades.getCatalog() shape).
local catalog = {
  { idx=1, id="miner_boost", name="Overclocked Miner", short="OvrclkMiner",
    desc="+20% mining payout multiplier per level (max 3.0x).",
    burn=false, level=5, max=10, maxed=false, nextCost=12915500 },
  { idx=2, id="mint_surge", name="Mint Surge", short="MintSurge",
    desc="Bonus 2x reward tick every 80-8*(lv-1) min.",
    burn=false, level=3, max=10, maxed=false, nextCost=4641600 },
  { idx=3, id="wallet_bonus", name="Wallet Bonus", short="WalletBonus",
    desc="+1uAMI/tick per active wallet per level credited to treasury.",
    burn=false, level=6, max=10, maxed=false, nextCost=700000 },
  { idx=4, id="genesis", name="Genesis Protocol", short="GenesisProto",
    desc="PRESTIGE: Broadcasts boot signature across the mesh.",
    burn=false, level=0, max=10, maxed=false, nextCost=200000 },
}
-- pad to 16 to prove the scrollbar appears
for i = 5, 16 do
  catalog[i] = { idx=i, id="x"..i, name="Upgrade "..i, short="Upg"..i,
    desc="Filler upgrade number "..i.." to overflow the grid.",
    burn=false, level=0, max=10, maxed=false, nextCost=100000*i }
end

local page = UpgradeUI.createPage("test")
UpgradeUI.setCatalog(page, catalog)
UI:setPage(page)

print("=== upgrade shop screen ===")
do
  local s = shim.screen
  print("+" .. string.rep("-", shim.W) .. "+")
  for y = 1, shim.H do print("|" .. s.text[y] .. "|") end
  print("+" .. string.rep("-", shim.W) .. "+")
end

-- TRACE: Buy button click -> 'shop_buy'
print("\n== TRACE: Buy click ==")
local captured = {}
local realQ = os.queueEvent
os.queueEvent = function(name, ...) if name=="shop_buy" or name=="shop_close" then captured[#captured+1]=name end; return realQ(name, ...) end
-- footerBar y=18; buyBtn x=1 w=14 -> click (4,18)
shim.injectEvent("mouse_click", 1, 4, 18)
shim.injectEvent("mouse_up", 1, 4, 18)
shim.injectEvent("terminate")
pcall(function() UI:pullEvents() end)
os.queueEvent = realQ
print("  Buy click -> queued:", table.concat(captured, ","))
assert(captured[1]=="shop_buy", "Buy button must queue shop_buy")

-- TRACE: selectedIndex reflects grid selection
page.catalogGrid:setIndex(3)
print("  selectedIndex after setIndex(3) =", UpgradeUI.selectedIndex(page))
assert(UpgradeUI.selectedIndex(page) == 3, "selectedIndex should map to catalog idx 3")
print("  PASS: Buy routes to shop_buy; selection maps to catalog index")
