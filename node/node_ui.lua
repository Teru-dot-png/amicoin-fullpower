-- node_ui.lua
-- Opus UI dashboard page definition for AmiCoin Node
-- Separated for clarity; required by startup.lua

local UI = require('ami.lib.ui.ui')
require('ami.lib.ui.widgets.fan')
require('ami.lib.ui.widgets.gauge')
local colors = _G.colors

local function createDashboard(nodeKey, nodeVersion)
    -- Clean tiled layout for a 51x19 advanced terminal (no overlapping panels):
    --   row 1        TitleBar
    --   rows 2-12    infoPanel  (left, cols 1-26)   |  thermalPanel (right, cols 28-51, rows 2-18)
    --   rows 13-18   upgradesPanel (left, cols 1-26)|
    --   row 19       StatusBar
    local page = UI.Page({
        backgroundColor = colors.black,

        titleBar = UI.TitleBar({
            title = 'AmiCoin Node v' .. nodeVersion,
            backgroundColor = colors.red,
            textColor = colors.white,
        }),

        -- ── Left top: node + economic stats ──
        infoPanel = UI.Window({
            x = 1, y = 2, width = 26, height = 11,
            backgroundColor = colors.gray,

            nodeKeyLabel = UI.Text({
                x = 2, y = 1, value = 'Node Key', textColor = colors.white,
            }),
            nodeKeyValue = UI.Text({
                x = 2, y = 2, value = nodeKey:sub(1, 16) .. '..', textColor = colors.yellow,
            }),

            activeWalletsLabel = UI.Text({
                x = 2, y = 4, value = 'Wallets', textColor = colors.white,
            }),
            activeWalletsValue = UI.Text({
                x = 12, y = 4, value = '0', textColor = colors.lime,
            }),

            supplyLabel = UI.Text({
                x = 2, y = 6, value = 'Supply', textColor = colors.white,
            }),
            supplyValue = UI.Text({
                x = 2, y = 7, value = '0.000000 AMI', textColor = colors.yellow,
            }),
            supplyuAMI = UI.Text({
                x = 2, y = 8, value = '(0 uAMI)', textColor = colors.lightGray,
            }),

            miningRateLabel = UI.Text({
                x = 2, y = 9, value = 'Mining Rate', textColor = colors.white,
            }),
            miningRateGauge = UI.Gauge({
                x = 2, y = 10, width = 23, max = 200,
            }),
            miningRateText = UI.Text({
                x = 2, y = 11, value = '0 uAMI/tk', textColor = colors.lime,
            }),
            ratePerHour = UI.Text({
                x = 14, y = 11, value = '0/hr', textColor = colors.lightGray,
            }),
            -- lagValue lives in the title-less corner; keep field for updateDashboard
            lagValue = UI.Text({
                x = 18, y = 4, value = 'OK', textColor = colors.lime,
            }),
        }),

        -- ── Left bottom: active upgrades ──
        upgradesPanel = UI.Window({
            x = 1, y = 13, width = 26, height = 6,
            backgroundColor = colors.gray,

            upgradesLabel = UI.Text({
                x = 2, y = 1, value = 'Active Upgrades', textColor = colors.white,
            }),
            upgradesList = UI.ScrollingGrid({
                x = 2, y = 2, width = 24, height = 4,
                columns = {
                    { heading = 'Upgrade', key = 'name'  },          -- auto-fills remaining width
                    { heading = 'Lv',      key = 'level', width = 4 },
                },
                sortColumn = 'name',
                values = {},
            }),
        }),

        -- ── Right column: thermal + fan ──
        thermalPanel = UI.Window({
            x = 28, y = 2, width = 24, height = 17,
            backgroundColor = colors.gray,

            tempLabel = UI.Text({
                x = 2, y = 1, value = 'Temperature', textColor = colors.white,
            }),
            tempValue = UI.Text({
                x = 2, y = 2, value = '0C OK', textColor = colors.lime,
            }),

            -- Pre-rendered fan (17x9); centered in the 24-wide column.
            fan = UI.Fan({
                x = 4, y = 5, level = 1,
            }),

            coolingLabel = UI.Text({
                x = 2, y = 15, value = 'Cooling: None', textColor = colors.gray,
            }),
        }),

        statusBar = UI.StatusBar({
            backgroundColor = colors.red,
            textColor = colors.white,
            columns = {
                { key = 'message', width = -1 },
            },
            values = {
                message = '[U]pdate [P]grades [T]AMIdecode [A]dmin',
            },
        }),
    })

    return page
end

return {
    createDashboard = createDashboard,
}
