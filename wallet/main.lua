-- wallet/main.lua
-- AmiCoin Wallet App -- Ender Router Pad GUI
--
-- Screens:
--   WELCOME      -- first run; Create or Import
--   DASHBOARD    -- balance (all nodes summed), send, refresh, export key, nodes, logout
--   NODE MANAGER -- list nodes, add, remove
--
-- Navigation: number/letter keys shown on each screen.

local sm    = require("secret_manager")
local sess  = require("session")
local comms = require("comms")

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

local function pmsg(text, y, color)
    term.setCursorPos(1, y)
    term.setTextColor(color or colors.white)
    if #text > W then text = text:sub(1, W) end
    term.write(text)
end

local function prompt(label, y, secret)
    term.setCursorPos(1, y)
    term.setTextColor(colors.yellow)
    term.write(label)
    term.setTextColor(colors.white)
    if secret then return read("*") else return read() end
end

local function waitKey()
    term.setTextColor(colors.gray)
    term.setCursorPos(1, H)
    term.write(string.rep(" ", W))
    term.setCursorPos(1, H)
    term.write("Press any key...")
    os.pullEvent("key")
end

-- ── Node list storage ─────────────────────────────────────────────────────────
-- Format: array of { name="...", key="..." }
local NODES_FILE = "/wallet_data/nodes.json"
local LEGACY_KEY = "/wallet_data/node_key.txt"

local function loadNodes()
    -- Auto-migrate old single node_key.txt
    if not fs.exists(NODES_FILE) and fs.exists(LEGACY_KEY) then
        local f = fs.open(LEGACY_KEY, "r")
        local k = f.readAll():gsub("%s", "")
        f.close()
        if #k == 32 then
            local migrated = { { name="Default Node", key=k } }
            if not fs.exists("/wallet_data") then fs.makeDir("/wallet_data") end
            local out = fs.open(NODES_FILE, "w")
            out.write(textutils.serialiseJSON(migrated))
            out.close()
            return migrated
        end
    end
    if not fs.exists(NODES_FILE) then return {} end
    local f = fs.open(NODES_FILE, "r")
    local raw = f.readAll()
    f.close()
    local t = textutils.unserialiseJSON(raw)
    return type(t) == "table" and t or {}
end

local function saveNodes(nodes)
    if not fs.exists("/wallet_data") then fs.makeDir("/wallet_data") end
    local f = fs.open(NODES_FILE, "w")
    f.write(textutils.serialiseJSON(nodes))
    f.close()
end

-- ── Screens ───────────────────────────────────────────────────────────────────

local function screenWelcome()
    banner("Welcome")
    pmsg("No wallet found on this Pad.", 5)
    pmsg("", 6)
    pmsg("  [1] Create a new wallet", 7, colors.cyan)
    pmsg("  [2] Import existing key",  8, colors.cyan)
    pmsg("  [Q] Quit",                 9, colors.gray)
    while true do
        local _, key = os.pullEvent("key")
        if key == keys.one or key == keys.n1 then return "CREATE"
        elseif key == keys.two or key == keys.n2 then return "IMPORT"
        elseif key == keys.q then return "QUIT"
        end
    end
end

local function screenCreate()
    banner("Create Wallet")
    pmsg("Enter your Minecraft player name:", 5)
    local playerName = prompt("> ", 7)
    playerName = playerName:gsub("^%s*(.-)%s*$", "%1")
    if #playerName == 0 then
        pmsg("Name cannot be empty!", 9, colors.red)
        waitKey()
        return nil, nil, nil
    end
    pmsg("Generating your Secret Key...", 11, colors.yellow)
    local secretKey, address = sm.generate(playerName)
    os.sleep(0.3)
    cls()
    banner("Your New Wallet")
    pmsg("Player: " .. playerName, 5, colors.cyan)
    pmsg("SECRET KEY (write this down!):", 7, colors.red)
    pmsg(secretKey:sub(1, 16),  8, colors.yellow)
    pmsg(secretKey:sub(17, 32), 9, colors.yellow)
    pmsg("PUBLIC ADDRESS:",          11, colors.lightGray)
    pmsg(address:sub(1, 32),         12, colors.white)
    pmsg(address:sub(33, 64),        13, colors.white)
    pmsg("KEEP YOUR SECRET KEY SAFE.", 15, colors.red)
    waitKey()
    return secretKey, address, playerName
end

local function screenImport()
    banner("Import Key")
    pmsg("Paste your 32-char Secret Key:", 5)
    local raw = prompt("> ", 7, true)
    local addr, err = sm.importKey(raw)
    if not addr then
        pmsg("Error: " .. (err or "unknown"), 9, colors.red)
        waitKey()
        return nil, nil, nil
    end
    pmsg("Key imported! Enter player name:", 9, colors.green)
    local playerName = prompt("> ", 11)
    playerName = playerName:gsub("^%s*(.-)%s*$", "%1")
    if #playerName > 0 then sm.saveName(playerName) end
    pmsg("Wallet ready!", 13, colors.green)
    os.sleep(1)
    return raw:gsub("%s",""):lower(), addr, playerName
end

-- ── Node Manager ──────────────────────────────────────────────────────────────
local function screenNodeManager(nodes, secretKey, address)
    while true do
        banner("Node Manager")
        if #nodes == 0 then
            pmsg("No nodes configured.", 5, colors.gray)
        else
            for i, node in ipairs(nodes) do
                local label = string.format("  [%d] %s  (%s...)", i, node.name, node.key:sub(1,8))
                pmsg(label, 4 + i, colors.white)
            end
        end
        local base = 6 + #nodes
        pmsg("  [A] Add node",    base,     colors.cyan)
        if #nodes > 0 then
            pmsg("  [D] Remove node", base + 1, colors.red)
        end
        pmsg("  [B] Back",        base + 2, colors.gray)

        local _, key = os.pullEvent("key")

        if key == keys.a then
            banner("Add Node")
            pmsg("Node name (e.g. 'Main Server'):", 5)
            local nodeName = prompt("> ", 7)
            nodeName = nodeName:gsub("^%s*(.-)%s*$", "%1")
            if #nodeName == 0 then nodeName = "Node " .. (#nodes + 1) end
            pmsg("How to add?", 9, colors.yellow)
            pmsg("  [1] Enter 32-char key manually", 10, colors.white)
            pmsg("  [2] Fetch via setup password",   11, colors.cyan)

            local addKey
            while true do
                local _, ak = os.pullEvent("key")
                if ak == keys.one or ak == keys.n1 then
                    -- Manual entry
                    pmsg("32-char XTEA key from node boot:", 13)
                    local k = prompt("> ", 15)
                    k = k:gsub("%s",""):lower()
                    if #k == 0 then
                        pmsg("Cancelled.", 17, colors.gray)
                        os.sleep(0.8)
                    elseif #k ~= 32 then
                        pmsg("Invalid (must be 32 hex chars).", 17, colors.red)
                        waitKey()
                    else
                        addKey = k
                    end
                    break
                elseif ak == keys.two or ak == keys.n2 then
                    -- Password-based auto-fetch
                    pmsg("Setup password for this node:", 13, colors.cyan)
                    local pw = prompt("> ", 15, true)
                    if #pw == 0 then
                        pmsg("Cancelled.", 17, colors.gray)
                        os.sleep(0.8)
                    else
                        pmsg("Contacting node...", 17, colors.yellow)
                        -- secretKey/address not in scope here; passed via closure
                        local ok, k, err = comms.fetchNodeKey(secretKey, address, pw)
                        if ok and k then
                            addKey = k
                            pmsg("Got key!", 17, colors.green)
                            os.sleep(0.5)
                        else
                            pmsg("Failed: " .. (err or "unknown"), 17, colors.red)
                            waitKey()
                        end
                    end
                    break
                end
            end

            if addKey then
                nodes[#nodes + 1] = { name=nodeName, key=addKey }
                saveNodes(nodes)
                pmsg("Node '" .. nodeName .. "' added!", 19, colors.green)
                os.sleep(0.8)
            end

        elseif key == keys.d and #nodes > 0 then
            banner("Remove Node")
            for i, node in ipairs(nodes) do
                pmsg(string.format("  [%d] %s", i, node.name), 4 + i, colors.white)
            end
            local inp = prompt("Number to remove (0=cancel): ", 6 + #nodes)
            local idx = tonumber(inp)
            if idx and idx >= 1 and idx <= #nodes then
                local removed = nodes[idx].name
                table.remove(nodes, idx)
                saveNodes(nodes)
                pmsg("Removed '" .. removed .. "'.", 8 + #nodes, colors.green)
                os.sleep(0.8)
            end

        elseif key == keys.b then
            return nodes
        end
    end
end

-- ── Dashboard ─────────────────────────────────────────────────────────────────
local function screenDashboard(secretKey, address, nodes, playerName)
    local totalBalance = nil
    local perNode      = {}
    local balErr       = nil

    local function refreshBalance()
        if #nodes == 0 then
            totalBalance = nil
            balErr = "No nodes - press [N] to add one"
            return
        end
        balErr = nil
        local total, breakdown = comms.getAllBalances(secretKey, address, nodes)
        totalBalance = total
        perNode      = breakdown
        local allFailed = true
        for _, n in ipairs(perNode) do
            if not n.err then allFailed = false end
        end
        if allFailed and #perNode > 0 then
            balErr = "All nodes unreachable"
        end
    end

    local function draw()
        banner("Dashboard")
        local nameStr = playerName and ("Player: " .. playerName) or "Player: (unknown)"
        pmsg(nameStr, 5, colors.cyan)
        pmsg("Addr: " .. address:sub(1, 16) .. "...", 6, colors.lightGray)

        if balErr then
            pmsg("Balance: [" .. balErr .. "]", 7, colors.red)
        elseif totalBalance then
            local ami = totalBalance / 1000000
            pmsg(string.format("Balance: %.6f AMI (%d uAMI)", ami, totalBalance), 7, colors.green)
            if #perNode > 1 then
                for i, n in ipairs(perNode) do
                    if n.err then
                        pmsg(string.format("  %s: [err]", n.name:sub(1,12)), 7 + i, colors.red)
                    else
                        pmsg(string.format("  %s: %.4f AMI", n.name:sub(1,12), n.balance/1000000), 7 + i, colors.lightGray)
                    end
                end
            end
        else
            pmsg("Balance: (press R to refresh)", 7, colors.gray)
        end

        local base = (#perNode > 1) and (8 + #perNode) or 9
        pmsg("  [S] Send coins",                  base,     colors.cyan)
        pmsg("  [R] Refresh balance",              base + 1, colors.cyan)
        pmsg("  [E] Export / View Key",            base + 2, colors.cyan)
        pmsg("  [N] Nodes (" .. #nodes .. ")",     base + 3, colors.cyan)
        pmsg("  [L] Logout",                       base + 4, colors.gray)
    end

    draw()

    while true do
        local ev, p1 = os.pullEvent()

        if ev == "key" then

            if p1 == keys.r then
                draw()  -- redraw first to clear stale per-node lines
                pmsg("Refreshing...", 7, colors.yellow)
                refreshBalance()
                draw()

            elseif p1 == keys.s then
                banner("Send AMI")
                if #nodes == 0 then
                    pmsg("No nodes configured.", 5, colors.red)
                    pmsg("Add a node first with [N].", 6)
                    waitKey()
                    draw()
                else
                    pmsg("Recipient (player name or address):", 5)
                    local toRaw = prompt("> ", 7)
                    toRaw = toRaw:gsub("^%s*(.-)%s*$", "%1")
                    local toAddr  = nil
                    local toLabel = toRaw

                    if #toRaw == 128 and toRaw:match("^[0-9a-fA-F]+$") then
                        toAddr = toRaw:lower()
                    else
                        pmsg("Looking up '" .. toRaw .. "'...", 9, colors.yellow)
                        local ok, data, err = comms.lookupAll(secretKey, address, toRaw, nodes)
                        if ok and data and data.address then
                            toAddr = data.address
                            pmsg("Found: " .. toAddr:sub(1,16) .. "...", 10, colors.green)
                        else
                            pmsg("Not found: " .. (err or "unknown"), 9, colors.red)
                            waitKey()
                            draw()
                        end
                    end

                    if toAddr then
                        -- Node selection for multi-node setups
                        local chosenNode = nodes[1]
                        if #nodes > 1 then
                            pmsg("Send via which node?", 11, colors.yellow)
                            for i, n in ipairs(nodes) do
                                pmsg(string.format("  [%d] %s", i, n.name), 11 + i, colors.white)
                            end
                            local inp = prompt("> ", 12 + #nodes)
                            local idx = tonumber(inp)
                            if idx and idx >= 1 and idx <= #nodes then
                                chosenNode = nodes[idx]
                            end
                        end

                        local amtRow = (#nodes > 1) and (14 + #nodes) or 12
                        pmsg("Amount (in AMI):", amtRow)
                        local rawAmt = prompt("> ", amtRow + 2)
                        local amt = tonumber(rawAmt)
                        if not amt or amt <= 0 then
                            pmsg("Invalid amount.", amtRow + 4, colors.red)
                            waitKey()
                        else
                            local microAmt = math.floor(amt * 1000000)
                            pmsg("Sending via " .. chosenNode.name .. "...", amtRow + 4, colors.yellow)
                            local ok, _, err = comms.transfer(secretKey, chosenNode.key, address, toAddr, microAmt)
                            if ok then
                                pmsg("Transfer sent!", amtRow + 4, colors.green)
                            else
                                pmsg("Failed: " .. (err or "unknown"), amtRow + 4, colors.red)
                            end
                            waitKey()
                            refreshBalance()
                        end
                    end
                    draw()
                end

            elseif p1 == keys.e then
                banner("Export Secret Key")
                if playerName then pmsg("Player: " .. playerName, 5, colors.cyan) end
                pmsg("Your SECRET KEY is:", 7, colors.red)
                pmsg(secretKey:sub(1, 16),  9, colors.yellow)
                pmsg(secretKey:sub(17, 32), 10, colors.yellow)
                pmsg("Never share this with anyone.",  12, colors.red)
                pmsg("Use it to migrate to a new Pad.", 13, colors.lightGray)
                waitKey()
                draw()

            elseif p1 == keys.n then
                nodes = screenNodeManager(nodes, secretKey, address)
                draw()

            elseif p1 == keys.l then
                sess.clear()
                pmsg("Logged out.", H - 1, colors.gray)
                os.sleep(1)
                return
            end

        elseif ev == "timer" then
            comms.heartbeatAll(secretKey, address, nodes)
            os.startTimer(60)
        end
    end
end

-- ── Boot ──────────────────────────────────────────────────────────────────────
local function boot()
    cls()
    local secretKey, address, playerName

    -- 1. Resume session
    local savedSess = sess.load()
    if savedSess and savedSess.logged_in then
        local k, a, n = sm.load()
        if k then secretKey=k; address=a; playerName=n end
    end

    -- 2. Welcome flow if no session
    if not secretKey then
        if sm.exists() then
            secretKey, address, playerName = sm.load()
        else
            local choice = screenWelcome()
            if choice == "QUIT" then return end
            if choice == "CREATE" then
                secretKey, address, playerName = screenCreate()
            elseif choice == "IMPORT" then
                secretKey, address, playerName = screenImport()
            end
        end
    end

    if not secretKey then
        cls()
        pmsg("No wallet available. Rebooting...", 1, colors.red)
        os.sleep(2)
        os.reboot()
        return
    end

    -- 3. Persist session
    sess.save({ address=address, logged_in=true })

    -- 4. Load nodes (auto-migrates legacy node_key.txt)
    local nodes = loadNodes()

    -- 5. First-run: prompt to add a node (skippable)
    if #nodes == 0 then
        banner("Add First Node")
        pmsg("No nodes configured yet.", 5)
        pmsg("  [1] Enter 32-char key manually", 7, colors.white)
        pmsg("  [2] Fetch via setup password",   8, colors.cyan)
        pmsg("  [S] Skip for now",               9, colors.gray)

        local firstKey, firstName
        while true do
            local _, fk = os.pullEvent("key")
            if fk == keys.s then
                pmsg("Skipped. Add nodes via [N].", 11, colors.gray)
                os.sleep(1.2)
                break
            elseif fk == keys.one or fk == keys.n1 then
                pmsg("32-char key from node boot:", 11)
                local k = prompt("> ", 13)
                k = k:gsub("%s",""):lower()
                if #k == 32 then
                    firstKey = k
                else
                    pmsg("Invalid key.", 15, colors.red); os.sleep(1)
                end
                break
            elseif fk == keys.two or fk == keys.n2 then
                pmsg("Setup password for the node:", 11, colors.cyan)
                local pw = prompt("> ", 13, true)
                if #pw > 0 then
                    pmsg("Contacting node...", 15, colors.yellow)
                    local ok, k, err = comms.fetchNodeKey(secretKey, address, pw)
                    if ok and k then
                        firstKey = k
                        pmsg("Got key!", 15, colors.green); os.sleep(0.5)
                    else
                        pmsg("Failed: " .. (err or "?"), 15, colors.red); os.sleep(1.2)
                    end
                end
                break
            end
        end

        if firstKey then
            banner("Name this node")
            pmsg("Node name (e.g. 'Main Server'):", 5)
            local nodeName = prompt("> ", 7)
            nodeName = nodeName:gsub("^%s*(.-)%s*$", "%1")
            if #nodeName == 0 then nodeName = "Node 1" end
            nodes = { { name=nodeName, key=firstKey } }
            saveNodes(nodes)
            pmsg("Node saved!", 9, colors.green)
            os.sleep(0.8)
        end
    end

    -- 6. Register on all nodes (idempotent, fire-and-forget via timer)
    comms.registerAll(secretKey, address, playerName, nodes)

    -- 7. First heartbeat + start 60s timer
    comms.heartbeatAll(secretKey, address, nodes)
    os.startTimer(60)

    -- 8. Main dashboard
    screenDashboard(secretKey, address, nodes, playerName)

    os.reboot()
end

boot()
