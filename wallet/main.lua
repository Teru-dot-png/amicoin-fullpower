-- wallet/main.lua
-- AmiCoin Wallet App – Ender Router Pad GUI
--
-- Screens:
--   WELCOME   – first run; offers "Create Wallet" or "Import Key"
--   LOGIN     – fast local PIN login (skipped if session is active)
--   DASHBOARD – balance, send, receive, export key, logout
--
-- Navigation: use the arrow keys or number keys shown on each screen.

local sm      = require("secret_manager")
local sess    = require("session")
local comms   = require("comms")

-- ── Display helpers ───────────────────────────────────────────────────────────
local W, H = term.getSize()

local function cls()
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
    term.clear()
    term.setCursorPos(1, 1)
end

local function center(text, y, fg, bg)
    fg = fg or colors.white
    bg = bg or colors.black
    local x = math.floor((W - #text) / 2) + 1
    term.setCursorPos(x, y)
    term.setTextColor(fg)
    term.setBackgroundColor(bg)
    term.write(text)
end

local function banner(title)
    cls()
    term.setBackgroundColor(colors.blue)
    term.setTextColor(colors.yellow)
    term.setCursorPos(1, 1)
    term.clearLine()
    center(" AmiCoin Wallet ", 1, colors.yellow, colors.blue)
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
    if title then
        center(title, 3, colors.cyan, colors.black)
    end
end

local function prompt(msg, y, secret)
    term.setCursorPos(1, y)
    term.setTextColor(colors.yellow)
    term.write(msg)
    term.setTextColor(colors.white)
    if secret then
        return read("*")
    else
        return read()
    end
end

local function msg(text, y, color)
    term.setCursorPos(1, y)
    term.setTextColor(color or colors.white)
    term.write(text)
end

local function waitKey()
    term.setTextColor(colors.gray)
    term.setCursorPos(1, H)
    term.write("Press any key…")
    os.pullEvent("key")
end

-- ── Node key storage ──────────────────────────────────────────────────────────
local NODE_KEY_FILE = "/wallet_data/node_key.txt"

local function loadNodeKey()
    if not fs.exists(NODE_KEY_FILE) then return nil end
    local f = fs.open(NODE_KEY_FILE, "r")
    local k = f.readAll():gsub("%s", "")
    f.close()
    return #k == 32 and k or nil
end

local function saveNodeKey(k)
    if not fs.exists("/wallet_data") then fs.makeDir("/wallet_data") end
    local f = fs.open(NODE_KEY_FILE, "w")
    f.write(k)
    f.close()
end

-- ── Screens ───────────────────────────────────────────────────────────────────

local function screenSetNodeKey()
    banner("Node Setup")
    msg("Enter the 32-char XTEA key", 5)
    msg("shown on your AmiCoin Node.", 6)
    local k = prompt("> ", 8)
    k = k:gsub("%s", ""):lower()
    if #k ~= 32 then
        msg("Invalid key length!", 10, colors.red)
        waitKey()
        return nil
    end
    saveNodeKey(k)
    msg("Node key saved.", 10, colors.green)
    os.sleep(1)
    return k
end

local function screenWelcome()
    banner("Welcome")
    msg("No wallet found on this Pad.", 5)
    msg("", 6)
    msg("  [1] Create a new wallet", 7, colors.cyan)
    msg("  [2] Import existing key", 8, colors.cyan)
    msg("  [Q] Quit", 9, colors.gray)

    while true do
        local _, key = os.pullEvent("key")
        if key == keys.one or key == keys.n1 then
            return "CREATE"
        elseif key == keys.two or key == keys.n2 then
            return "IMPORT"
        elseif key == keys.q then
            return "QUIT"
        end
    end
end

local function screenCreate()
    banner("Create Wallet")
    msg("Generating your Secret Key…", 5)
    local secretKey, address = sm.generate()
    os.sleep(0.5)
    cls()
    banner("Your New Wallet")
    msg("SECRET KEY (write this down!):", 5, colors.red)
    -- Split key across two lines for readability
    msg(secretKey:sub(1, 16), 6, colors.yellow)
    msg(secretKey:sub(17, 32), 7, colors.yellow)
    msg("PUBLIC ADDRESS:", 9, colors.lightGray)
    msg(address:sub(1, 32), 10, colors.white)
    msg(address:sub(33, 64), 11, colors.white)
    msg("KEEP YOUR SECRET KEY SAFE.", 13, colors.red)
    msg("Anyone with it controls your coins.", 14, colors.red)
    waitKey()
    return secretKey, address
end

local function screenImport()
    banner("Import Key")
    msg("Paste your 32-char Secret Key:", 5)
    local raw = prompt("> ", 7, true)
    local addr, err = sm.importKey(raw)
    if not addr then
        msg("Error: " .. (err or "unknown"), 9, colors.red)
        waitKey()
        return nil, nil
    end
    msg("Wallet imported!", 9, colors.green)
    os.sleep(1)
    return raw:gsub("%s",""):lower(), addr
end

local function screenDashboard(secretKey, address, nodeKey)
    local balance = nil
    local balErr  = nil

    local function refreshBalance()
        if not nodeKey then
            balance = nil
            balErr  = "Node key not configured"
            return
        end
        local ok, data, err = comms.getBalance(secretKey, nodeKey, address)
        if ok and data then
            balance = data.balance
            balErr  = nil
        else
            balErr = err or "No response from node"
        end
    end

    local function draw()
        banner("Dashboard")
        local shortAddr = address:sub(1, 16) .. "…"
        msg("Address: " .. shortAddr, 5, colors.lightGray)
        if balance then
            local ami = balance / 1000000
            msg(string.format("Balance: %.6f AMI  (%d uAMI)", ami, balance), 6, colors.green)
        elseif balErr then
            msg("Balance: [" .. balErr .. "]", 6, colors.red)
        else
            msg("Balance: (press R to refresh)", 6, colors.gray)
        end
        msg("", 8)
        msg("  [S] Send coins", 9, colors.cyan)
        msg("  [R] Refresh balance", 10, colors.cyan)
        msg("  [E] Export / View Key", 11, colors.cyan)
        msg("  [N] Set node key", 12, colors.cyan)
        msg("  [L] Logout", 13, colors.gray)
    end

    draw()

    while true do
        local ev, p1 = os.pullEvent()

        if ev == "key" then
            if p1 == keys.r then
                refreshBalance()
                draw()

            elseif p1 == keys.s then
                -- Send screen
                banner("Send AMI")
                msg("Recipient address (64 hex):", 5)
                local to = prompt("> ", 7)
                to = to:gsub("%s", ""):lower()
                if #to ~= 64 then
                    msg("Invalid address.", 9, colors.red)
                    waitKey()
                else
                    msg("Amount (in AMI):", 10)
                    local rawAmt = prompt("> ", 12)
                    local amt = tonumber(rawAmt)
                    if not amt or amt <= 0 then
                        msg("Invalid amount.", 14, colors.red)
                        waitKey()
                    else
                        if not nodeKey then
                            msg("No node key set.", 14, colors.red)
                            waitKey()
                        else
                            local microAmt = math.floor(amt * 1000000)
                            msg("Sending…", 14, colors.yellow)
                            local ok, data, err = comms.transfer(secretKey, nodeKey, address, to, microAmt)
                            if ok then
                                msg("Transfer sent!", 14, colors.green)
                            else
                                msg("Failed: " .. (err or "unknown"), 14, colors.red)
                            end
                            waitKey()
                            refreshBalance()
                        end
                    end
                end
                draw()

            elseif p1 == keys.e then
                -- Export / View Key
                banner("Export Secret Key")
                msg("Your SECRET KEY is:", 5, colors.red)
                msg(secretKey:sub(1, 16), 7, colors.yellow)
                msg(secretKey:sub(17, 32), 8, colors.yellow)
                msg("", 10)
                msg("Never share this with anyone.", 11, colors.red)
                msg("Use it to migrate to a new Pad.", 12, colors.lightGray)
                waitKey()
                draw()

            elseif p1 == keys.n then
                local nk = screenSetNodeKey()
                if nk then nodeKey = nk end
                draw()

            elseif p1 == keys.l then
                sess.clear()
                msg("Logged out.", H - 1, colors.gray)
                os.sleep(1)
                return
            end

        elseif ev == "timer" then
            -- Heartbeat every 60 seconds (timer set below)
            comms.heartbeat(secretKey, address)
        end
    end
end

-- ── Heartbeat timer ───────────────────────────────────────────────────────────
local heartbeatTimer = nil

local function startHeartbeat(secretKey, address)
    heartbeatTimer = os.startTimer(60)
    comms.heartbeat(secretKey, address)
end

-- ── Boot flow ─────────────────────────────────────────────────────────────────
local function boot()
    cls()

    local secretKey, address

    -- 1. Try to resume from saved session
    local savedSess = sess.load()
    if savedSess and savedSess.address and savedSess.logged_in then
        local loadedKey, loadedAddr = sm.load()
        if loadedKey then
            secretKey = loadedKey
            address   = loadedAddr
        end
    end

    -- 2. No session – go through welcome flow
    if not secretKey then
        if sm.exists() then
            -- Key exists but no session: just load it
            secretKey, address = sm.load()
        else
            local choice = screenWelcome()
            if choice == "QUIT" then return end
            if choice == "CREATE" then
                secretKey, address = screenCreate()
            elseif choice == "IMPORT" then
                secretKey, address = screenImport()
            end
        end
    end

    if not secretKey then
        cls()
        msg("No wallet available. Rebooting…", 1, colors.red)
        os.sleep(2)
        os.reboot()
        return
    end

    -- 3. Persist session
    sess.save({ address = address, logged_in = true })

    -- 4. Load node key
    local nodeKey = loadNodeKey()
    if not nodeKey then
        nodeKey = screenSetNodeKey()
    end

    -- 5. Register wallet on node (idempotent)
    if nodeKey then
        comms.register(secretKey, nodeKey, address)
    end

    -- 6. Start heartbeat
    startHeartbeat(secretKey, address)

    -- 7. Main dashboard
    screenDashboard(secretKey, address, nodeKey)

    -- After logout, reboot to clear RAM
    os.reboot()
end

boot()
