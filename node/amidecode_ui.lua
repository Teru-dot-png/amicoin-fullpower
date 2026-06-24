-- node/amidecode_ui.lua
-- Opus UI page for the AMIdecode hacking minigame ([T]). Keeps the green
-- Fallout "ACCESS TERMINAL" look, built from Opus components instead of
-- hand-drawn term writes. 8 clickable password Buttons + a feedback log + Back.
-- The node's UI:pullEvents loop drives it; clicks queue os events the [T] flow
-- in startup.lua reacts to:
--   word button / number key -> os.queueEvent('amd_guess', pickIndex)
--   Back button / [B]         -> os.queueEvent('amd_close')

local UI   = require('ami.lib.ui.ui')
local Util = require('ami.lib.ui.util')
local colors = _G.colors

local FEED_LINES = 5
local FEED_W     = 49

local AmiDecodeUI = {}

function AmiDecodeUI.createPage(level)
    local page
    page = UI.Page({
        backgroundColor = colors.black,

        titleBar = UI.TitleBar({
            title = 'AMIdecode v' .. tostring(level) .. ' // ACCESS TERMINAL',
            backgroundColor = colors.green, textColor = colors.lime,
        }),

        attemptsText = UI.Text({
            x = 2, y = 2, width = 30, value = 'ATTEMPTS: 3', textColor = colors.lime,
        }),
        promptText = UI.Text({
            x = 2, y = 3, width = 49, value = 'SELECT PASSWORD:', textColor = colors.green,
        }),

        -- 8 password buttons in 2 columns x 4 rows (rows 5,7,9,11).
        wordPanel = (function()
            local p = { x = 1, y = 4, width = 51, height = 9, backgroundColor = colors.black }
            for i = 1, 8 do
                local col = (i - 1) % 2          -- 0 left, 1 right
                local row = math.floor((i - 1) / 2)
                p['word' .. i] = UI.Button({
                    x = 2 + col * 25, y = 1 + row * 2, width = 22,
                    text = '[' .. i .. '] ......', event = 'amd_pick',
                    pick = i,
                    backgroundColor = colors.gray, textColor = colors.lime,
                    backgroundFocusColor = colors.green, textFocusColor = colors.white,
                })
            end
            return UI.Window(p)
        end)(),

        -- Feedback log (rows 13..17).
        feedPanel = (function()
            local p = { x = 1, y = 13, width = 51, height = 5, backgroundColor = colors.black }
            for i = 1, FEED_LINES do
                p['feed' .. i] = UI.Text({
                    x = 2, y = i, width = FEED_W, value = '', textColor = colors.lime,
                })
            end
            return UI.Window(p)
        end)(),

        -- Footer: Back button.
        footerBar = UI.Window({
            x = 1, y = 19, width = 51, height = 1, backgroundColor = colors.green,
            backBtn = UI.Button({
                x = 1, y = 1, width = 12, text = '[B]ack', event = 'amd_close_evt',
                backgroundColor = colors.green, textColor = colors.lime,
                backgroundFocusColor = colors.lime, textFocusColor = colors.black,
            }),
            hint = UI.Text({
                x = 14, y = 1, width = 37, value = 'Click a password or press 1-8',
                backgroundColor = colors.green, textColor = colors.lime,
            }),
        }),
    })

    page.eventHandler = function(self, event)
        if event.type == 'amd_pick' and event.button and event.button.pick then
            os.queueEvent('amd_guess', event.button.pick)
            return true
        elseif event.type == 'amd_close_evt' then
            os.queueEvent('amd_close')
            return true
        end
        return UI.Page.eventHandler(self, event)
    end

    return page
end

-- Fill the 8 word buttons and the attempts line for a fresh game.
function AmiDecodeUI.setWords(page, words, guessesLeft)
    for i = 1, 8 do
        local b = page.wordPanel['word' .. i]
        if b then
            b.text = string.format('[%d] %s', i, words[i] or '......')
            b.inactive = false
        end
    end
    page.attemptsText.value = 'ATTEMPTS: ' .. tostring(guessesLeft)
end

-- Push a feedback line (scrolls upward, newest at the bottom).
local feedBuf = setmetatable({}, { __mode = 'k' })
function AmiDecodeUI.addFeed(page, line, color)
    local buf = feedBuf[page]
    if not buf then buf = {}; feedBuf[page] = buf end
    -- wrap each message to the feed width
    for _, wl in ipairs(Util.wordWrap(tostring(line), FEED_W)) do
        buf[#buf + 1] = wl
    end
    while #buf > FEED_LINES do table.remove(buf, 1) end
    for i = 1, FEED_LINES do
        local w = page.feedPanel['feed' .. i]
        if w then
            w.value = buf[i] or ''
            w.textColor = color or colors.lime
        end
    end
end

function AmiDecodeUI.setAttempts(page, n)
    page.attemptsText.value = 'ATTEMPTS: ' .. tostring(n)
end

-- Disable word buttons (after a terminal win/lose).
function AmiDecodeUI.lockWords(page)
    for i = 1, 8 do
        local b = page.wordPanel['word' .. i]
        if b then b.inactive = true end
    end
end

return AmiDecodeUI
