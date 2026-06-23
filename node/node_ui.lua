-- node_ui.lua
-- Opus UI dashboard page definition for AmiCoin Node
-- Separated for clarity; required by startup.lua

local UI = require('ami.lib.ui.ui')
local colors = _G.colors

local function createDashboard(nodeKey, nodeVersion)
    local page = UI.Page({
        backgroundColor = colors.black,
        
        -- Title bar
        titleBar = UI.TitleBar({
            title = 'AmiCoin Node v' .. nodeVersion,
            backgroundColor = colors.red,
            textColor = colors.white,
        }),
        
        -- Main content area with two columns
        infoPanel = UI.Window({
            x = 1, y = 2, width = 27, height = -2,
            backgroundColor = colors.gray,
            
            -- Node Key
            nodeKeyLabel = UI.Text({
                x = 2, y = 1,
                value = 'Node Key:',
                textColor = colors.white,
            }),
            nodeKeyValue = UI.Text({
                x = 2, y = 2,
                value = nodeKey:sub(1, 20) .. '...',
                textColor = colors.yellow,
            }),
            
            -- Active Wallets
            activeWalletsLabel = UI.Text({
                x = 2, y = 4,
                value = 'Active Wallets:',
                textColor = colors.white,
            }),
            activeWalletsValue = UI.Text({
                x = 18, y = 4,
                value = '0',
                textColor = colors.lime,
            }),
            
            -- Total Supply
            supplyLabel = UI.Text({
                x = 2, y = 6,
                value = 'Total Supply:',
                textColor = colors.white,
            }),
            supplyValue = UI.Text({
                x = 2, y = 7,
                value = '0.000000 AMI',
                textColor = colors.yellow,
            }),
            supplyuAMI = UI.Text({
                x = 2, y = 8,
                value = '(0 uAMI)',
                textColor = colors.gray,
            }),
            
            -- Mining Rate
            miningRateLabel = UI.Text({
                x = 2, y = 10,
                value = 'Mining Rate:',
                textColor = colors.white,
            }),
            miningRateGauge = UI.Gauge({
                x = 2, y = 11, width = 23,
                max = 200,
            }),
            miningRateText = UI.Text({
                x = 2, y = 12,
                value = '0 uAMI/tk',
                textColor = colors.lime,
            }),
            ratePerHour = UI.Text({
                x = 2, y = 13,
                value = '0.0000 AMI/hr',
                textColor = colors.gray,
            }),
            
            -- Lag Indicator
            lagLabel = UI.Text({
                x = 2, y = 15,
                value = 'TPS Status:',
                textColor = colors.white,
            }),
            lagValue = UI.Text({
                x = 15, y = 15,
                value = 'OK',
                textColor = colors.lime,
            }),
        }),
        
        -- Right column: Thermal & Fan
        thermalPanel = UI.Window({
            x = 28, y = 2, width = -1, height = 18,
            backgroundColor = colors.gray,
            
            tempLabel = UI.Text({
                x = 2, y = 1,
                value = 'Temperature:',
                textColor = colors.white,
            }),
            tempValue = UI.Text({
                x = 2, y = 2,
                value = '0C OK',
                textColor = colors.lime,
            }),
            
            -- Parametric fan widget
            fan = UI.Fan({
                x = 3, y = 4,
                level = 1,
            }),
            
            coolingLabel = UI.Text({
                x = 2, y = 16,
                value = 'Cooling: None',
                textColor = colors.gray,
            }),
        }),
        
        -- Bottom: Upgrades list
        upgradesPanel = UI.Window({
            x = 1, y = -11, width = -1, height = 10,
            backgroundColor = colors.gray,
            
            upgradesLabel = UI.Text({
                x = 2, y = 1,
                value = 'Active Upgrades:',
                textColor = colors.white,
            }),
            
            upgradesList = UI.ScrollingGrid({
                x = 2, y = 2, width = -2, height = -1,
                columns = {
                    { heading = 'Upgrade',    key = 'name'  , width = -10 },
                    { heading = 'Level',      key = 'level' , width = 8  },
                },
                sortColumn = 'name',
                values = {},
            }),
        }),
        
        -- Status bar
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
