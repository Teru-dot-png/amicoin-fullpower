-- wallet/wallet_ui.lua
-- AmiCoin Wallet Dashboard UI (Opus Framework)
-- Demon theme (red/black/gray) with professional layout

local UI     = require('ami.lib.ui.ui')
local Event  = require('ami.lib.ui.event')
local Theme  = require('ami.lib.ui.theme')

-- Apply demon theme
Theme.setTheme('demon')

local WalletUI = {}

function WalletUI.createDashboard(address, amidnsName)
    local shortAddr = address and (address:sub(1, 8) .. '...' .. address:sub(-4)) or 'Loading...'
    local displayName = amidnsName or 'Not registered'
    
    return UI.Page({
        backgroundColor = colors.black,
        
        -- Title bar
        titleBar = UI.TitleBar({
            title = 'AmiCoin Wallet',
            backgroundColor = colors.red,
            textColor = colors.white,
        }),
        
        -- Balance panel (prominent)
        balancePanel = UI.Window({
            x = 1, y = 2, width = -1, height = 9,
            backgroundColor = colors.gray,
            
            balanceLabel = UI.Text({
                x = 'center', y = 2,
                value = 'Balance',
                textColor = colors.white,
            }),
            
            balanceValue = UI.Text({
                x = 'center', y = 4,
                value = '0.000000 AMI',
                textColor = colors.yellow,
            }),
            
            balanceMicro = UI.Text({
                x = 'center', y = 5,
                value = '(0 uAMI)',
                textColor = colors.gray,
            }),
            
            addressLabel = UI.Text({
                x = 2, y = 7,
                value = 'Addr: ' .. shortAddr,
                textColor = colors.lightGray,
            }),
            
            nameLabel = UI.Text({
                x = 2, y = 8,
                value = 'Name: ' .. displayName,
                textColor = colors.lightGray,
            }),
        }),
        
        -- Quick actions (big buttons row 1)
        actionsPanel = UI.Window({
            x = 1, y = 11, width = -1, height = 3,
            backgroundColor = colors.black,
            
            sendBtn = UI.Button({
                x = 2, y = 1,
                width = 12, height = 3,
                text = 'Send AMI',
                event = 'action_send',
                backgroundColor = colors.red,
                textColor = colors.white,
            }),
            
            receiveBtn = UI.Button({
                x = 15, y = 1,
                width = 11, height = 3,
                text = 'Receive',
                event = 'action_receive',
                backgroundColor = colors.orange,
                textColor = colors.white,
            }),
            
            exportBtn = UI.Button({
                x = 27, y = 1,
                width = 11, height = 3,
                text = 'Export',
                event = 'action_export',
                backgroundColor = colors.orange,
                textColor = colors.white,
            }),
            
            nodesBtn = UI.Button({
                x = 39, y = 1,
                width = 12, height = 3,
                text = 'Nodes',
                event = 'action_nodes',
                backgroundColor = colors.gray,
                textColor = colors.white,
            }),
        }),
        
        -- Quick actions (big buttons row 2)
        actionsPanel2 = UI.Window({
            x = 1, y = 14, width = -1, height = 3,
            backgroundColor = colors.black,
            
            vaultBtn = UI.Button({
                x = 2, y = 1,
                width = 12, height = 3,
                text = 'Vault',
                event = 'action_vault',
                backgroundColor = colors.pink,
                textColor = colors.white,
            }),
            
            updateBtn = UI.Button({
                x = 15, y = 1,
                width = 11, height = 3,
                text = 'Update',
                event = 'action_update',
                backgroundColor = colors.orange,
                textColor = colors.white,
            }),
            
            logoutBtn = UI.Button({
                x = 27, y = 1,
                width = 11, height = 3,
                text = 'Logout',
                event = 'action_logout',
                backgroundColor = colors.gray,
                textColor = colors.white,
            }),
        }),
        
        -- Status bar (node count + sync status)
        statusBar = UI.StatusBar({
            backgroundColor = colors.red,
            textColor = colors.white,
        }),
    })
end

-- Update dashboard with current state
function WalletUI.updateDashboard(page, balance, onlineNodes, totalNodes, netStats)
    -- Update balance display
    if balance then
        local ami = balance / 1000000
        page.balancePanel.balanceValue:setValue(string.format("%.6f AMI", ami))
        page.balancePanel.balanceMicro:setValue(string.format("(%d uAMI)", balance))
    else
        page.balancePanel.balanceValue:setValue("Loading...")
        page.balancePanel.balanceMicro:setValue("")
    end
    
    -- Update status bar
    local statusText = ""
    if totalNodes and totalNodes > 0 then
        local online = onlineNodes or 0
        local netInfo = ""
        if netStats then
            local rate = netStats.effective_rate or netStats.current_rate or 0
            local earnPerHour = rate * 120  -- 120 ticks/hour
            netInfo = string.format(" | %d uAMI/tk +%d/hr", rate, earnPerHour)
        end
        statusText = string.format("%d/%d nodes online%s", online, totalNodes, netInfo)
    else
        statusText = "No nodes configured - press Nodes"
    end
    page.statusBar:setValue(statusText)
    
    page:draw()
end

return WalletUI
