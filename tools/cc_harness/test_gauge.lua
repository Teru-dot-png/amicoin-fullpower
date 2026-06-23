-- tools/cc_harness/test_gauge.lua
-- Renders a Gauge through the shim and prints BOTH the text layer and the
-- background-colour layer, so we can see the solid bar (spaces+bg) + value text.
local shim = dofile("tools/cc_harness/shim.lua")
local UI = require("ami.lib.ui.ui")
local Theme = require("ami.lib.ui.theme"); Theme.setTheme("demon")
require("ami.lib.ui.widgets.gauge")
UI:disableEffects()

local page = UI.Page({ backgroundColor = _G.colors.black,
    g = UI.Gauge({ x = 1, y = 2, width = 23, max = 200 }),
})
UI:setPage(page)

local function show(val)
    page.g.value = val
    page.g:draw(); page.g:sync()
    local s = shim.screen
    local y = 2  -- gauge row
    -- text layer
    print(string.format("value=%-3d text: [%s]", val, s.text[y]:sub(1,23)))
    print(string.format("          bg  : [%s]", s.bg[y]:sub(1,23)))
end

print("Gauge 23-wide, max=200 (bg blit chars: e=red f=black 4=yellow d=lime 7=gray):")
show(0)
show(50)
show(130)
show(200)
print("\n(The bar is the bg layer; value text sits on top, split at fill edge.)")
