-- node/upgrade_ui.lua
-- Opus UI page for the AmiCoin node Upgrade Shop ([P]).
-- A scrolling grid of every upgrade (no pagination), a buyer-name TextEntry, a
-- live details panel, and clickable Buy/Back buttons. Driven by the node's
-- existing UI:pullEvents loop; the page turns clicks into custom os events the
-- shop sub-flow in startup.lua reacts to:
--   Buy button / Enter / double-click -> os.queueEvent('shop_buy')
--   Back button / [B]                 -> os.queueEvent('shop_close')

local UI   = require('ami.lib.ui.ui')
local Util = require('ami.lib.ui.util')
local colors = _G.colors

local DETAIL_W   = 21    -- right details panel inner width
local DESC_LINES = 6     -- wrapped description lines in the details panel

local UpgradeUI = {}

-- Build the (static) upgrade-shop page. Fill it with setCatalog() afterwards.
function UpgradeUI.createPage(nodeVersion)
    local page
    page = UI.Page({
        backgroundColor = colors.black,

        titleBar = UI.TitleBar({
            title = 'AmiCoin Node Upgrades',
            backgroundColor = colors.red, textColor = colors.white,
        }),

        -- Buyer Ami-DNS name field (row 2).
        buyerLabel = UI.Text({
            x = 1, y = 2, value = 'Buyer:', textColor = colors.white,
        }),
        buyerEntry = UI.TextEntry({
            x = 8, y = 2, width = 30, limit = 32,
            shadowText = 'Ami-DNS name',
            backgroundColor = colors.gray, backgroundFocusColor = colors.gray,
            textColor = colors.white,
        }),

        -- Left: scrolling catalog (rows 3..16). pageSize < 16 -> scrollbar shows.
        catalogGrid = UI.ScrollingGrid({
            x = 1, y = 3, width = 28, height = 14,
            columns = {
                { heading = 'Upgrade', key = 'short'   },          -- auto-fill
                { heading = 'Lv',      key = 'lvStr',  width = 3 },
                { heading = 'Cost',    key = 'costStr', width = 9 },
            },
            sortColumn = 'idx',
            values = {},
        }),

        -- Right: details for the selected upgrade.
        detailPanel = (function()
            local p = {
                x = 30, y = 3, width = 22, height = 14,
                backgroundColor = colors.gray,
                nameText = UI.Text({
                    x = 1, y = 1, width = DETAIL_W, value = '', textColor = colors.orange,
                }),
                levelText = UI.Text({
                    x = 1, y = 2, width = DETAIL_W, value = '', textColor = colors.white,
                }),
                costText = UI.Text({
                    x = 1, y = 3, width = DETAIL_W, value = '', textColor = colors.yellow,
                }),
            }
            for i = 1, DESC_LINES do
                p['descLine' .. i] = UI.Text({
                    x = 1, y = 4 + i, width = DETAIL_W,
                    value = '', textColor = colors.lightGray,
                })
            end
            return UI.Window(p)
        end)(),

        -- Footer: clickable Buy / Back (row 18) + hint (row 19).
        footerBar = UI.Window({
            x = 1, y = 18, width = 51, height = 1, backgroundColor = colors.black,
            buyBtn = UI.Button({
                x = 1, y = 1, width = 14, text = 'Buy [Enter]', event = 'shop_buy_evt',
                backgroundColor = colors.green, textColor = colors.black,
                backgroundFocusColor = colors.lime, textFocusColor = colors.black,
            }),
            backBtn = UI.Button({
                x = 16, y = 1, width = 11, text = '[B]ack', event = 'shop_back_evt',
                backgroundColor = colors.red, textColor = colors.white,
                backgroundFocusColor = colors.orange, textFocusColor = colors.white,
            }),
        }),
        hint = UI.StatusBar({
            backgroundColor = colors.gray, textColor = colors.lightGray,
            columns = { { key = 'message', width = -1 } },
            values = { message = 'Click a row or use arrows - scroll for more' },
        }),
    })

    -- Update the details panel for a catalog entry (a row's value table).
    local function showDetails(entry)
        local dp = page.detailPanel
        if not entry then
            dp.nameText.value = ''
            dp.levelText.value = ''
            dp.costText.value = ''
            for i = 1, DESC_LINES do dp['descLine' .. i].value = '' end
            return
        end
        dp.nameText.value  = entry.name
        dp.levelText.value = string.format('Level %d / %d', entry.level, entry.max)
        if entry.maxed then
            dp.costText.value = '*** MAX ***'
            dp.costText.textColor = colors.lime
        elseif entry.burn then
            dp.costText.value = string.format('BURN %.4f AMI', entry.nextCost / 1e6)
            dp.costText.textColor = colors.red
        else
            dp.costText.value = string.format('Cost %.4f AMI', entry.nextCost / 1e6)
            dp.costText.textColor = colors.yellow
        end
        local wrapped = Util.wordWrap(entry.desc, DETAIL_W)
        for i = 1, DESC_LINES do
            dp['descLine' .. i].value = wrapped[i] or ''
        end
    end
    page._showDetails = showDetails

    -- Route grid selection + button clicks. Falls through to the default Page
    -- handler (focus traversal, scroll) for everything else.
    page.eventHandler = function(self, event)
        if event.type == 'grid_focus_row' then
            showDetails(event.selected)
            self:draw(); self:sync()
            return true
        elseif event.type == 'shop_buy_evt' or event.type == 'key_enter' then
            os.queueEvent('shop_buy')
            return true
        elseif event.type == 'shop_back_evt' then
            os.queueEvent('shop_close')
            return true
        end
        return UI.Page.eventHandler(self, event)
    end

    return page
end

-- Fill / refresh the grid from a catalog (list from upgrades.getCatalog()).
function UpgradeUI.setCatalog(page, catalog)
    local rows = {}
    for _, e in ipairs(catalog) do
        -- Put every field the details panel needs directly on the row, so the
        -- grid_focus_row event (which carries the row table) is self-contained.
        rows[#rows + 1] = {
            idx      = e.idx,
            short    = e.short,
            name     = e.name,
            desc     = e.desc,
            level    = e.level,
            max      = e.max,
            maxed    = e.maxed,
            burn     = e.burn,
            nextCost = e.nextCost,
            lvStr    = tostring(e.level),
            costStr  = e.maxed and 'MAX' or string.format('%.3f', e.nextCost / 1e6),
        }
    end
    page.catalogGrid:setValues(rows)
    page.catalogGrid:setIndex(1)
    if rows[1] and page._showDetails then
        page._showDetails(rows[1])
    end
end

-- Currently selected catalog index (or nil).
function UpgradeUI.selectedIndex(page)
    local sel = page.catalogGrid:getSelected()
    return sel and sel.idx or nil
end

return UpgradeUI
