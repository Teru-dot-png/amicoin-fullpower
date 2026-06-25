-- wallet/wallet_ui.lua
-- AmiCoin Wallet Dashboard UI (Opus Framework)
-- Pocket-computer layout: 26 wide x 20 tall

local UI    = require('ami.lib.ui.ui')
local Theme = require('ami.lib.ui.theme')

Theme.setTheme('demon')

local WalletUI = {}

local _blinkState = false

-- Write a colored AMI/uAMI token at (x, y) in window win.
-- Returns the x position after the token.
local function writeToken(win, x, y, bg, kind)
    if kind == 'uami' then
        win:write(x,   y, 'u', bg, colors.lime)
        win:write(x+1, y, 'A', bg, colors.pink)
        win:write(x+2, y, 'M', bg, colors.red)
        win:write(x+3, y, 'I', bg, colors.pink)
        return x + 4
    else
        win:write(x,   y, 'A', bg, colors.pink)
        win:write(x+1, y, 'M', bg, colors.red)
        win:write(x+2, y, 'I', bg, colors.pink)
        return x + 3
    end
end

local function fillRow(win, x, y, bg)
    local rem = win.width - x + 1
    if rem > 0 then win:write(x, y, string.rep(' ', rem), bg, bg) end
end

function WalletUI.createDashboard(address, playerName)
    local shortAddr = address
        and (address:sub(1, 4) .. '..' .. address:sub(-4))
        or  '???'
    local titleStr = (playerName and #playerName > 0)
        and (playerName .. '  Addr:' .. shortAddr)
        or  ('Wallet  Addr:' .. shortAddr)

    local page = UI.Page({
        backgroundColor = colors.black,

        titleBar = UI.TitleBar({
            title = titleStr,
            backgroundColor = colors.red,
            textColor = colors.white,
        }),

        -- Balance panel (rows 2-5, gray background)
        -- Custom draw renders colored AMI/uAMI tokens without cutoffs.
        balancePanel = UI.Window({
            x = 1, y = 2, width = -1, height = 4,
            backgroundColor = colors.gray,
            _amiFloat = 0.0,
            _uami     = 0,
            _nodeStr  = '?/? nodes',

            draw = function(self)
                local bg = colors.gray
                self:clear(bg)

                -- Row 1: "Bal:" label
                self:write(1, 1, ' Bal:', bg, colors.lightGray)
                fillRow(self, 6, 1, bg)

                -- Row 2: AMI amount + colored AMI token
                local amiNum = string.format(' %.5f ', self._amiFloat)
                self:write(1, 2, amiNum, bg, colors.yellow)
                local ax = #amiNum + 1
                ax = writeToken(self, ax, 2, bg, 'ami')
                fillRow(self, ax, 2, bg)

                -- Row 3: uAMI amount + colored uAMI token
                local uamiNum = string.format(' %d ', self._uami)
                self:write(1, 3, uamiNum, bg, colors.yellow)
                local ux = #uamiNum + 1
                ux = writeToken(self, ux, 3, bg, 'uami')
                fillRow(self, ux, 3, bg)

                -- Row 4: node summary
                local nodeLine = ' ' .. self._nodeStr
                self:write(1, 4, nodeLine, bg, colors.lightGray)
                fillRow(self, #nodeLine + 1, 4, bg)
            end,
        }),

        -- Node list grid (rows 6-17), 12 rows = 1 header + 11 node rows
        nodeGrid = UI.ScrollingGrid({
            x = 1, y = 6, width = -1, height = 12,
            backgroundColor = colors.black,
            textColor = colors.white,
            textSelectedColor = colors.white,
            headerBackgroundColor = colors.red,
            headerTextColor = colors.white,
            backgroundSelectedColor = colors.gray,
            unfocusedBackgroundSelectedColor = colors.black,
            columns = {
                { heading = 'Node',   key = 'name',   width = 11 },
                { heading = 'Ping',   key = 'ping',   width = 4, align = 'right' },
                { heading = 'St',     key = 'status', width = 5 },
            },
            values = {},

            -- Color each row by node health
            getRowTextColor = function(self, row, selected)
                if selected and self.focused then return self.textSelectedColor end
                if row._err   then return colors.red    end
                if row._fpbad then return colors.orange end
                if row._new   then return colors.yellow end
                return colors.lime
            end,
        }),

        -- Button row 1 (row 18): [S]end [R] [E]xp [N]Cmd  (1-char gaps)
        -- Layout: S(6) gap(1) R(4) gap(1) E(5) gap(1) N(8) = 26
        btnRow1 = UI.Window({
            x = 1, y = 18, width = -1, height = 1,
            backgroundColor = colors.black,

            sendBtn = UI.Button({
                x = 1, y = 1, width = 6, height = 1,
                text = '[S]end', event = 'action_send',
                backgroundColor = colors.red,
                backgroundFocusColor = colors.orange,
                textColor = colors.white, textFocusColor = colors.white,
            }),
            refreshBtn = UI.Button({
                x = 8, y = 1, width = 4, height = 1,
                text = '[R]', event = 'action_refresh',
                backgroundColor = colors.gray,
                backgroundFocusColor = colors.lightGray,
                textColor = colors.white, textFocusColor = colors.white,
            }),
            exportBtn = UI.Button({
                x = 13, y = 1, width = 5, height = 1,
                text = '[E]xp', event = 'action_export',
                backgroundColor = colors.orange,
                backgroundFocusColor = colors.yellow,
                textColor = colors.white, textFocusColor = colors.white,
            }),
            nodesBtn = UI.Button({
                x = 19, y = 1, width = 8, height = 1,
                text = '[N]Cmd', event = 'action_nodes',
                backgroundColor = colors.gray,
                backgroundFocusColor = colors.lightGray,
                textColor = colors.white, textFocusColor = colors.white,
            }),
        }),

        -- Button row 2 (row 19): [V]ault [U]pdate [L]ogout  (1-char gaps)
        -- Layout: V(8) gap(1) U(8) gap(1) L(8) = 26
        btnRow2 = UI.Window({
            x = 1, y = 19, width = -1, height = 1,
            backgroundColor = colors.black,

            vaultBtn = UI.Button({
                x = 1, y = 1, width = 8, height = 1,
                text = '[V]ault', event = 'action_vault',
                backgroundColor = colors.pink,
                backgroundFocusColor = colors.red,
                textColor = colors.white, textFocusColor = colors.white,
            }),
            updateBtn = UI.Button({
                x = 10, y = 1, width = 8, height = 1,
                text = '[U]pdate', event = 'action_update',
                backgroundColor = colors.orange,
                backgroundFocusColor = colors.yellow,
                textColor = colors.white, textFocusColor = colors.white,
            }),
            logoutBtn = UI.Button({
                x = 19, y = 1, width = 8, height = 1,
                text = '[L]ogout', event = 'action_logout',
                backgroundColor = colors.gray,
                backgroundFocusColor = colors.lightGray,
                textColor = colors.white, textFocusColor = colors.white,
            }),
        }),

        -- Status bar (row 20)
        statusBar = UI.StatusBar({
            backgroundColor = colors.red,
            textColor = colors.white,
        }),
    })

    return page
end

-- Update dashboard with latest data and redraw.
-- perNode: array of { name, balance, err, latency, fp_ok } from main.lua
function WalletUI.updateDashboard(page, balance, onlineNodes, totalNodes, netStats, perNode)
    local bp = page.balancePanel
    if balance then
        bp._amiFloat = balance / 1000000
        bp._uami     = balance
    else
        bp._amiFloat = 0.0
        bp._uami     = 0
    end
    local online = onlineNodes or 0
    local total  = totalNodes  or 0
    bp._nodeStr = string.format('%d/%d nodes', online, total)

    -- Rebuild node grid rows from perNode
    local rows = {}
    if perNode and #perNode > 0 then
        for i, n in ipairs(perNode) do
            local ping = n.latency and (n.latency .. 'ms') or '--'
            local status, _err, _fpbad, _new
            if n.err then
                status = '[ERR]'; _err = true
            elseif n.fp_ok == false then
                status = '[FP!]'; _fpbad = true
            elseif n.fp_ok == 'tofc' then
                status = '[NEW]'; _new = true
            else
                status = '[OK]'
            end
            rows[i] = {
                name   = (n.name or '?'):sub(1, 11),
                ping   = ping,
                status = status,
                _err   = _err,
                _fpbad = _fpbad,
                _new   = _new,
            }
        end
    end
    page.nodeGrid:setValues(rows)

    -- Update [N]Cmd label with live node count
    local nBtn = page.btnRow1 and page.btnRow1.nodesBtn
    if nBtn then
        nBtn.text = total > 0
            and string.format('[N](%d)', total)
            or  '[N]Cmd'
    end

    -- Status bar (no node count; blinking # as activity pulse)
    _blinkState = not _blinkState
    local blink = _blinkState and '#' or ' '
    local statusText
    if netStats then
        local rate    = netStats.effective_rate or netStats.current_rate or 0
        local perHour = rate * 120
        statusText = string.format('%duAMI/30s +%d/hr %s', rate, perHour, blink)
    elseif total > 0 then
        statusText = string.format('%d/%d nodes %s', online, total, blink)
    else
        statusText = 'No nodes -- press [N]'
    end
    page.statusBar:setStatus(statusText)

    page:draw()
    page:sync()
end

return WalletUI
