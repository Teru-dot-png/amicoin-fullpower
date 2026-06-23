-- node_ui.lua
-- Opus UI dashboard page definition for AmiCoin Node
-- Separated for clarity; required by startup.lua

local UI = require('ami.lib.ui.ui')
require('ami.lib.ui.widgets.fan')
require('ami.lib.ui.widgets.gauge')
local colors = _G.colors

-- Footer button event -> action key. The page eventHandler turns a button click
-- into os.queueEvent('ami_action', <key>), which the node's keyboard thread also
-- listens for, so mouse and the U/P/T/A accelerators share ONE dispatch path.
local FOOTER_ACTIONS = {
    act_update = 'u',
    act_shop   = 'p',
    act_decode = 't',
    act_admin  = 'a',
}

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
                x = 2, y = 2, width = 24, value = nodeKey:sub(1, 16) .. '..', textColor = colors.yellow,
            }),

            activeWalletsLabel = UI.Text({
                x = 2, y = 3, value = 'Wallets', textColor = colors.white,
            }),
            activeWalletsValue = UI.Text({
                x = 12, y = 3, width = 5, value = '0', textColor = colors.lime,
            }),
            -- TPS / lag status shares the Wallets row.
            lagValue = UI.Text({
                x = 18, y = 3, width = 7, value = 'OK', textColor = colors.lime,
            }),

            supplyLabel = UI.Text({
                x = 2, y = 4, value = 'Supply', textColor = colors.white,
            }),
            supplyValue = UI.Text({
                x = 2, y = 5, width = 24, value = '0.000000 AMI', textColor = colors.yellow,
            }),
            supplyuAMI = UI.Text({
                x = 2, y = 6, width = 24, value = '(0 uAMI)', textColor = colors.lightGray,
            }),

            miningRateLabel = UI.Text({
                x = 2, y = 7, value = 'Mining Rate', textColor = colors.white,
            }),
            miningRateGauge = UI.Gauge({
                x = 2, y = 8, width = 23, max = 200,
            }),
            miningRateText = UI.Text({
                x = 2, y = 9, width = 13, value = '0 uAMI/tk', textColor = colors.lime,
            }),
            ratePerHour = UI.Text({
                x = 14, y = 9, width = 11, value = '0/hr', textColor = colors.lightGray,
            }),

            -- Next-mint countdown (updates ~1/s; the bar fills over the 30s cycle).
            mintLabel = UI.Text({
                x = 2, y = 10, value = 'Next Mint', textColor = colors.white,
            }),
            mintCountdown = UI.Text({
                x = 16, y = 10, width = 9, value = '30s', textColor = colors.cyan,
            }),
            mintBar = UI.Gauge({
                x = 2, y = 11, width = 23, max = 100, showValue = false,
                colorLow = colors.cyan, colorMid = colors.cyan,
                colorHigh = colors.cyan, colorCrit = colors.cyan,
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

        -- ── Right column: live node log (fan now lives on the monitor) ──
        logPanel = (function()
            local p = {
                x = 28, y = 2, width = 24, height = 17,
                backgroundColor = colors.black,

                logHeader = UI.Text({
                    x = 1, y = 1, width = 24, align = 'center',
                    value = ' Node Log ',
                    backgroundColor = colors.red, textColor = colors.white,
                }),
                -- Compact thermal/cooling status line at the bottom.
                tempValue = UI.Text({
                    x = 2, y = 16, width = 22,
                    value = '0C OK', textColor = colors.lime,
                }),
            }
            -- 14 scrolling log lines (rows 2..15).
            for i = 1, 14 do
                p['logLine' .. i] = UI.Text({
                    x = 2, y = 1 + i, width = 22,
                    value = '', textColor = colors.lightGray,
                })
            end
            return UI.Window(p)
        end)(),

        -- Footer: real clickable Opus Buttons (row 19). Each fires a distinct
        -- event the page maps to an 'ami_action' os event; the U/P/T/A keyboard
        -- accelerators run the same actions via the node's keyboard thread.
        footerBar = UI.Window({
            x = 1, y = 19, width = 51, height = 1,
            backgroundColor = colors.red,

            btnUpdate = UI.Button({
                x = 1, y = 1, width = 13, text = '[U]pdate', event = 'act_update',
                backgroundColor = colors.red, textColor = colors.white,
                backgroundFocusColor = colors.orange, textFocusColor = colors.white,
            }),
            btnShop = UI.Button({
                x = 14, y = 1, width = 12, text = '[P]Shop', event = 'act_shop',
                backgroundColor = colors.red, textColor = colors.white,
                backgroundFocusColor = colors.orange, textFocusColor = colors.white,
            }),
            btnDecode = UI.Button({
                x = 26, y = 1, width = 13, text = '[T]Decode', event = 'act_decode',
                backgroundColor = colors.red, textColor = colors.white,
                backgroundFocusColor = colors.orange, textFocusColor = colors.white,
            }),
            btnAdmin = UI.Button({
                x = 39, y = 1, width = 13, text = '[A]dmin', event = 'act_admin',
                backgroundColor = colors.red, textColor = colors.white,
                backgroundFocusColor = colors.orange, textFocusColor = colors.white,
            }),
        }),
    })

    -- Route footer button clicks into the shared 'ami_action' dispatch. Falls
    -- through to the default Page handler (focus traversal) for everything else.
    page.eventHandler = function(self, event)
        if event.type and FOOTER_ACTIONS[event.type] then
            os.queueEvent('ami_action', FOOTER_ACTIONS[event.type])
            return true
        end
        return UI.Page.eventHandler(self, event)
    end

    return page
end

return {
    createDashboard = createDashboard,
}
