-- wallet/wallet_ui.lua
-- AmiCoin Wallet Dashboard UI (Opus Framework)
-- Pocket-computer layout: 26 wide x 20 tall

local UI    = require('ami.lib.ui.ui')
local Theme = require('ami.lib.ui.theme')
local Util  = require('ami.lib.ui.util')

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

-- Write text at (x, y) in window win with inline AMI/uAMI token coloring.
-- Everything else is rendered in fg. Clipped to the window width.
local function writeAmiText(win, x, y, text, bg, fg)
    text = text:sub(1, win.width - x + 1)
    local i, run = 1, 1
    local function flush(upto)
        if upto >= run then
            win:write(x + run - 1, y, text:sub(run, upto), bg, fg)
        end
    end
    while i <= #text do
        local kind, len
        if     text:sub(i, i + 3) == 'uAMI' then kind, len = 'uami', 4
        elseif text:sub(i, i + 2) == 'AMI'  then kind, len = 'ami',  3
        end
        if kind then
            flush(i - 1)
            writeToken(win, x + i - 1, y, bg, kind)
            i = i + len
            run = i
        else
            i = i + 1
        end
    end
    flush(#text)
end

-- Word-wrapped message area shared by the Send and Invoice pages.
-- Set its text with WalletUI.setMessage().
local function messagePanel(y, height)
    return UI.Window({
        x = 1, y = y, width = -1, height = height,
        backgroundColor = colors.black,
        _text  = '',
        _color = colors.white,
        draw = function(self)
            local bg = colors.black
            self:clear(bg)
            local lines = Util.wordWrap(self._text, self.width - 2)
            for i = 1, math.min(#lines, self.height) do
                writeAmiText(self, 2, i, lines[i], bg, self._color)
            end
        end,
    })
end

-- Show a message on a Send/Invoice page and repaint it.
function WalletUI.setMessage(page, text, color)
    page.message._text  = text or ''
    page.message._color = color or colors.white
    page:draw()
    page:sync()
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
                { heading = 'Node',   key = 'name',   width = 10 },
                { heading = 'Bal',    key = 'bal',    width = 7, align = 'right' },
                { heading = 'St',     key = 'status', width = 5 },
            },
            values = {},

            getRowTextColor = function(self, row, selected)
                if selected and self.focused then return self.textSelectedColor end
                if row._err   then return colors.red    end
                if row._fpbad then return colors.orange end
                if row._new   then return colors.yellow end
                return colors.lime
            end,
        }),

        -- Button row 1 (y=18): S(6) gap R(4) gap E(5) gap N(8) = 26
        sendBtn = UI.Button({
            x = 1, y = 18, width = 6, height = 1,
            text = '[S]end', event = 'action_send',
            backgroundColor = colors.red,
            backgroundFocusColor = colors.orange,
            textColor = colors.white, textFocusColor = colors.white,
        }),
        refreshBtn = UI.Button({
            x = 8, y = 18, width = 4, height = 1,
            text = '[R]', event = 'action_refresh',
            backgroundColor = colors.gray,
            backgroundFocusColor = colors.lightGray,
            textColor = colors.white, textFocusColor = colors.white,
        }),
        exportBtn = UI.Button({
            x = 13, y = 18, width = 5, height = 1,
            text = '[E]xp', event = 'action_export',
            backgroundColor = colors.orange,
            backgroundFocusColor = colors.yellow,
            textColor = colors.white, textFocusColor = colors.white,
        }),
        nodesBtn = UI.Button({
            x = 19, y = 18, width = 8, height = 1,
            text = '[N]Cmd', event = 'action_nodes',
            backgroundColor = colors.gray,
            backgroundFocusColor = colors.lightGray,
            textColor = colors.white, textFocusColor = colors.white,
        }),

        -- Button row 2 (y=19): V(8) gap U(8) gap L(8) = 26
        vaultBtn = UI.Button({
            x = 1, y = 19, width = 8, height = 1,
            text = '[V]ault', event = 'action_vault',
            backgroundColor = colors.pink,
            backgroundFocusColor = colors.red,
            textColor = colors.white, textFocusColor = colors.white,
        }),
        updateBtn = UI.Button({
            x = 10, y = 19, width = 8, height = 1,
            text = '[U]pdate', event = 'action_update',
            backgroundColor = colors.orange,
            backgroundFocusColor = colors.yellow,
            textColor = colors.white, textFocusColor = colors.white,
        }),
        logoutBtn = UI.Button({
            x = 19, y = 19, width = 8, height = 1,
            text = '[L]ogout', event = 'action_logout',
            backgroundColor = colors.gray,
            backgroundFocusColor = colors.lightGray,
            textColor = colors.white, textFocusColor = colors.white,
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
            local bal = string.format('%.2f', (n.balance or 0) / 1e6):sub(1, 7)
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
                name   = (n.name or '?'):sub(1, 10),
                bal    = bal,
                status = status,
                _err   = _err,
                _fpbad = _fpbad,
                _new   = _new,
            }
        end
    end
    page.nodeGrid:setValues(rows)

    -- Update [N]Cmd label with live node count
    local nBtn = page.nodesBtn
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

-- ── Command Center page ───────────────────────────────────────────────────────

local function buildCmdRows(nodes, perNode)
    local rows = {}
    for i, node in ipairs(nodes) do
        local pn   = perNode and perNode[i]
        local bal  = pn and string.format('%.2f', (pn.balance or 0) / 1e6) or '?'
        local ping = (pn and pn.latency) and string.format('%dms', pn.latency) or '---'
        local fp, _err, _fpbad, _new
        if pn and pn.err then
            fp = '[ERR]'; _err = true
        elseif node.fp_mismatch then
            fp = '[!FP]'; _fpbad = true
        elseif pn and pn.fp_ok == 'tofc' then
            fp = '[NEW]'; _new = true
        elseif node.known_fp then
            fp = '[OK]'
        else
            fp = '[?]'; _new = true
        end
        rows[i] = {
            name   = (node.name or '?'):sub(1, 9),
            bal    = bal:sub(1, 7),
            ping   = ping:sub(1, 5),
            fp     = fp,
            _err   = _err, _fpbad = _fpbad, _new = _new,
        }
    end
    return rows
end

function WalletUI.createCmdCtr()
    return UI.Page({
        backgroundColor = colors.black,

        titleBar = UI.TitleBar({
            title = 'Command Center',
            backgroundColor = colors.red,
            textColor = colors.white,
        }),

        -- Node grid rows 2-10 (9 rows: 1 header + 8 data)
        -- Columns: Node(9) Bal(7) Ping(5) FP(5) = 26
        nodeGrid = UI.ScrollingGrid({
            x = 1, y = 2, width = -1, height = 9,
            backgroundColor = colors.black,
            textColor = colors.white,
            textSelectedColor = colors.white,
            headerBackgroundColor = colors.red,
            headerTextColor = colors.white,
            backgroundSelectedColor = colors.gray,
            unfocusedBackgroundSelectedColor = colors.black,
            columns = {
                { heading = 'Node', key = 'name', width = 9 },
                { heading = 'Bal',  key = 'bal',  width = 7, align = 'right' },
                { heading = 'Ping', key = 'ping', width = 5, align = 'right' },
                { heading = 'FP',   key = 'fp',   width = 5 },
            },
            values = {},
            getRowTextColor = function(self, row, selected)
                if selected and self.focused then return self.textSelectedColor end
                if row._err   then return colors.red    end
                if row._fpbad then return colors.orange end
                if row._new   then return colors.yellow end
                return colors.lime
            end,
        }),

        -- Row 11: info strip (online count + total balance)
        infoBar = UI.Window({
            x = 1, y = 11, width = -1, height = 1,
            backgroundColor = colors.gray,
            _info = 'No nodes configured',
            draw = function(self)
                self:clear(colors.gray)
                self:write(1, 1, (' ' .. self._info):sub(1, self.width),
                    colors.gray, colors.white)
            end,
        }),

        -- Row 12: Add(12) gap(1) Del(13)
        addBtn = UI.Button({
            x = 1, y = 12, width = 12, height = 1,
            text = '[A]dd node', event = 'action_add',
            backgroundColor = colors.orange, backgroundFocusColor = colors.yellow,
            textColor = colors.white, textFocusColor = colors.white,
        }),
        delBtn = UI.Button({
            x = 14, y = 12, width = 13, height = 1,
            text = '[D]el node', event = 'action_del',
            backgroundColor = colors.red, backgroundFocusColor = colors.orange,
            textColor = colors.white, textFocusColor = colors.white,
        }),

        -- Row 13: Integrity(12) gap(1) Gossip(13)
        integBtn = UI.Button({
            x = 1, y = 13, width = 12, height = 1,
            text = '[I]ntegrity', event = 'action_integ',
            backgroundColor = colors.yellow, backgroundFocusColor = colors.orange,
            textColor = colors.black, textFocusColor = colors.black,
        }),
        gossipBtn = UI.Button({
            x = 14, y = 13, width = 13, height = 1,
            text = '[G]ossip DNS', event = 'action_gossip',
            backgroundColor = colors.cyan, backgroundFocusColor = colors.lightBlue,
            textColor = colors.black, textFocusColor = colors.black,
        }),

        -- Row 14: Consolidate (full width)
        consolidateBtn = UI.Button({
            x = 1, y = 14, width = 26, height = 1,
            text = '[C]onsolidate Balances', event = 'action_consolidate',
            backgroundColor = colors.lime, backgroundFocusColor = colors.green,
            textColor = colors.black, textFocusColor = colors.black,
        }),

        -- Row 15: Back (full width)
        backBtn = UI.Button({
            x = 1, y = 15, width = 26, height = 1,
            text = '[B]ack to Wallet', event = 'action_back',
            backgroundColor = colors.gray, backgroundFocusColor = colors.lightGray,
            textColor = colors.white, textFocusColor = colors.white,
        }),

        statusBar = UI.StatusBar({
            backgroundColor = colors.red,
            textColor = colors.white,
        }),
    })
end

function WalletUI.updateCmdCtr(page, nodes, perNode)
    page.nodeGrid:setValues(buildCmdRows(nodes, perNode))

    local online, totalBal = 0, 0
    for i = 1, #nodes do
        local pn = perNode and perNode[i]
        if pn and not pn.err then online = online + 1 end
        if pn then totalBal = totalBal + (pn.balance or 0) end
    end

    if #nodes == 0 then
        page.infoBar._info = 'No nodes -- press [A]dd'
    else
        page.infoBar._info = string.format('%d/%d online  |  %.4f AMI total',
            online, #nodes, totalBal / 1e6)
    end

    page.statusBar:setStatus(
        #nodes == 0 and 'No nodes configured'
        or string.format('%d/%d nodes online', online, #nodes)
    )

    page:draw()
    page:sync()
end

-- ── Send page ─────────────────────────────────────────────────────────────────

-- nodes:   wallet node list ({ name, key }); balance: total uAMI or nil.
-- Emits 'send_submit' (Send/Confirm/Done button) and 'send_cancel' (Back).
function WalletUI.createSend(nodes, balance)
    local nodeChoices = {}
    for i, node in ipairs(nodes) do
        nodeChoices[i] = { name = (node.name or '?'):sub(1, 20), value = i }
    end

    local function label(y, text)
        return UI.Text({
            x = 2, y = y, value = text,
            backgroundColor = colors.black, textColor = colors.lightGray,
        })
    end

    return UI.Page({
        backgroundColor = colors.black,

        titleBar = UI.TitleBar({
            title = 'Send AMI', event = 'send_cancel',
            backgroundColor = colors.red,
            textColor = colors.white,
        }),

        -- Rows 3-4: recipient
        toLabel = label(3, 'To (name or address):'),
        toEntry = UI.TextEntry({
            x = 1, y = 4, width = -1, limit = 128,
            shadowText = 'Ami-DNS name / 128-hex',
            backgroundColor = colors.gray, backgroundFocusColor = colors.gray,
            textColor = colors.white, shadowTextColor = colors.lightGray,
        }),

        -- Rows 6-7: amount(15) gap(1) unit(10)
        amountLabel = label(6, 'Amount:'),
        amountEntry = UI.TextEntry({
            x = 1, y = 7, width = 15, limit = 20,
            shadowText = '0.0',
            backgroundColor = colors.gray, backgroundFocusColor = colors.gray,
            textColor = colors.white, shadowTextColor = colors.lightGray,
        }),
        unitChooser = UI.Chooser({
            x = 17, y = 7, width = 10,
            choices = {
                { name = 'AMI',  value = 'ami'  },
                { name = 'uAMI', value = 'uami' },
            },
            value = 'ami',
            backgroundColor = colors.lightGray, backgroundFocusColor = colors.white,
            textColor = colors.black,
        }),

        -- Rows 9-10: node to send through (fixed when there is only one)
        nodeLabel = label(9, 'Via node:'),
        nodeChooser = UI.Chooser({
            x = 1, y = 10, width = -1,
            choices = nodeChoices,
            value = nodeChoices[1] and 1 or nil,
            nochoice = 'No nodes',
            inactive = #nodes < 2,
            backgroundColor = colors.lightGray, backgroundFocusColor = colors.white,
            textColor = colors.black,
        }),

        -- Rows 12-16: lookup / confirmation / result text
        message = messagePanel(12, 5),

        -- Row 18: Send(12) gap(1) Back(13)
        sendBtn = UI.Button({
            x = 1, y = 18, width = 12, height = 1,
            text = 'Send', event = 'send_submit',
            inactive = #nodes == 0,
            backgroundColor = colors.red, backgroundFocusColor = colors.orange,
            textColor = colors.white, textFocusColor = colors.white,
        }),
        backBtn = UI.Button({
            x = 14, y = 18, width = 13, height = 1,
            text = 'Back', event = 'send_cancel',
            backgroundColor = colors.gray, backgroundFocusColor = colors.lightGray,
            textColor = colors.white, textFocusColor = colors.white,
        }),

        statusBar = UI.StatusBar({
            backgroundColor = colors.red,
            textColor = colors.white,
            values = balance
                and string.format('Bal: %.5f AMI', balance / 1e6)
                or  'Balance unknown',
        }),
    })
end

-- ── Invoice page ──────────────────────────────────────────────────────────────

-- info: { shop, item, qty, total (uAMI), txId, via (node name or nil) }
-- Emits 'invoice_pay' and 'invoice_decline'.
function WalletUI.createInvoice(info)
    local page = UI.Page({
        backgroundColor = colors.black,

        titleBar = UI.TitleBar({
            title = 'Incoming Invoice',
            backgroundColor = colors.red,
            textColor = colors.white,
        }),

        -- Invoice details (rows 3-9, gray background)
        infoPanel = UI.Window({
            x = 1, y = 3, width = -1, height = 7,
            backgroundColor = colors.gray,

            draw = function(self)
                local bg = colors.gray
                self:clear(bg)
                self:write(1, 1, (' Shop : ' .. info.shop):sub(1, self.width), bg, colors.orange)
                self:write(1, 2, (' Item : ' .. info.item):sub(1, self.width), bg, colors.white)
                self:write(1, 3, (' Qty  : ' .. info.qty):sub(1, self.width),  bg, colors.white)
                writeAmiText(self, 1, 4,
                    string.format(' Total: %.6f AMI', info.total / 1e6), bg, colors.yellow)
                writeAmiText(self, 1, 5,
                    string.format('        %d uAMI', info.total), bg, colors.yellow)
                self:write(1, 7, (' TX: ' .. info.txId):sub(1, self.width), bg, colors.lightGray)
            end,
        }),

        -- Rows 11-15: payment progress / result text
        message = messagePanel(11, 5),

        -- Row 18: Pay(12) gap(1) Decline(13)
        payBtn = UI.Button({
            x = 1, y = 18, width = 12, height = 1,
            text = '[Y] Pay', event = 'invoice_pay',
            backgroundColor = colors.lime, backgroundFocusColor = colors.green,
            textColor = colors.black, textFocusColor = colors.black,
        }),
        declineBtn = UI.Button({
            x = 14, y = 18, width = 13, height = 1,
            text = '[N] Decline', event = 'invoice_decline',
            backgroundColor = colors.red, backgroundFocusColor = colors.orange,
            textColor = colors.white, textFocusColor = colors.white,
        }),

        statusBar = UI.StatusBar({
            backgroundColor = colors.red,
            textColor = colors.white,
            values = info.via and ('Pay via ' .. info.via) or 'No nodes configured',
        }),
    })

    -- Start on Decline so a stray Enter can never pay.
    page.focused = page.declineBtn
    return page
end

-- Invoice is settled (paid, failed or expired): show the outcome and leave
-- only a Back button.
function WalletUI.finishInvoice(page, text, color)
    page.payBtn:disable()
    page.declineBtn.text = '[B]ack'
    page:setFocus(page.declineBtn)
    WalletUI.setMessage(page, text, color)
end

return WalletUI
