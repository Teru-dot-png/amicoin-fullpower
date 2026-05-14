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
    term.setBackgroundColor(colors.red)
    term.setTextColor(colors.white)
    term.setCursorPos(1, 1)
    term.clearLine()
    center(" AmiCoin Wallet ", 1, colors.white, colors.red)
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
    if title then
        center(title, 3, colors.orange, colors.black)
    end
end

-- Write text at (1,y) with inline AMI/uAMI token coloring.
-- "uAMI"  → u=lime  A=pink  M=red    I=pink
-- "AMI"   →         A=pink  M=red    I=pink
-- Everything else is rendered in `color`.
local function pmsg(text, y, color)
    color = color or colors.white
    term.setCursorPos(1, y)
    if #text > W then text = text:sub(1, W) end
    local i = 1
    while i <= #text do
        if text:sub(i, i + 3) == "uAMI" then
            term.setTextColor(colors.lime);  term.write("u")
            term.setTextColor(colors.pink);  term.write("A")
            term.setTextColor(colors.red);   term.write("M")
            term.setTextColor(colors.pink);  term.write("I")
            term.setTextColor(color)
            i = i + 4
        elseif text:sub(i, i + 2) == "AMI" then
            term.setTextColor(colors.pink);  term.write("A")
            term.setTextColor(colors.red);   term.write("M")
            term.setTextColor(colors.pink);  term.write("I")
            term.setTextColor(color)
            i = i + 3
        else
            term.setTextColor(color)
            term.write(text:sub(i, i))
            i = i + 1
        end
    end
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
local NODES_FILE  = "/wallet_data/nodes.json"
local LEGACY_KEY  = "/wallet_data/node_key.txt"
local NAMES_CACHE = "/wallet_data/names_cache.json"

-- ── Ami-DNS name cache ────────────────────────────────────────────────────────
-- Maps address (128-hex) -> player name, persisted locally.
local _nameCache = nil
local function loadNameCache()
    if _nameCache then return _nameCache end
    if not fs.exists(NAMES_CACHE) then _nameCache = {} return _nameCache end
    local f = fs.open(NAMES_CACHE, "r")
    local raw = f.readAll()
    f.close()
    _nameCache = textutils.unserialiseJSON(raw) or {}
    return _nameCache
end
local function saveNameCache()
    if not _nameCache then return end
    if not fs.exists("/wallet_data") then fs.makeDir("/wallet_data") end
    local f = fs.open(NAMES_CACHE, "w")
    f.write(textutils.serialiseJSON(_nameCache))
    f.close()
end
-- Cache address -> name (call after any successful REGISTER or LOOKUP)
local function cacheName(addr, name)
    if type(addr) ~= "string" or #addr ~= 128 then return end
    if type(name) ~= "string" or #name == 0 then return end
    local c = loadNameCache()
    c[addr] = name
    saveNameCache()
end
-- Resolve address to display string: "Name" if known, else "38de...3e9f"
local function resolveAddr(addr)
    if type(addr) ~= "string" or #addr < 16 then return tostring(addr) end
    local c = loadNameCache()
    if c[addr] then return c[addr] end
    return addr:sub(1, 8) .. "..." .. addr:sub(-4)
end

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

-- ── Self-update ──────────────────────────────────────────────────────────────
local REPO_BASE = "https://raw.githubusercontent.com/Teru-dot-png/amicoin-fullpower/refs/heads/main"
local UPDATE_FILES = {
    { src="/shared/xtea.lua",       dst="/shared/xtea.lua"    },
    { src="/wallet/main.lua",       dst="/startup.lua"        },
    { src="/wallet/secret_manager.lua", dst="/secret_manager.lua" },
    { src="/wallet/session.lua",    dst="/session.lua"        },
    { src="/wallet/comms.lua",      dst="/comms.lua"          },
}

local function fnv1a(s)
    local hash = 2166136261
    for i = 1, #s do
        hash = bit32.bxor(hash, string.byte(s, i))
        hash = (hash * 16777619) % 4294967296
    end
    return string.format("%08x", hash)
end

local function screenUpdate()
    banner("Software Update")
    pmsg("Downloading latest from GitHub...", 5, colors.yellow)
    local failed = false
    local hashes = {}
    local row = 7
    for _, entry in ipairs(UPDATE_FILES) do
        pmsg(entry.dst .. "...", row, colors.white)
        local ok, res = pcall(http.get, REPO_BASE .. entry.src)
        if ok and res then
            local content = res.readAll()
            res.close()
            if #content < 64 then
                pmsg(entry.dst .. " REJECTED (too small)", row, colors.red)
                failed = true
            else
                local hash = fnv1a(content)
                hashes[#hashes + 1] = hash
                local dir = entry.dst:match("^(.*)/[^/]+$")
                if dir and dir ~= "" and not fs.exists(dir) then fs.makeDir(dir) end
                if fs.exists(entry.dst) then fs.delete(entry.dst) end
                local f = fs.open(entry.dst, "w")
                f.write(content)
                f.close()
                pmsg(entry.dst .. " OK [" .. hash .. "]", row, colors.green)
            end
        else
            pmsg(entry.dst .. " FAILED", row, colors.red)
            failed = true
        end
        row = row + 1
    end
    if failed then
        pmsg("Some files failed. Check connection.", row + 1, colors.red)
        waitKey()
    else
        local fp = fnv1a(table.concat(hashes, ":"))
        pmsg("Fingerprint: " .. fp, row + 1, colors.yellow)
        pmsg("Update complete! Rebooting...", row + 2, colors.green)
        os.sleep(3)
        os.reboot()
    end
end


-- ── Screens ───────────────────────────────────────────────────────────────────

local function screenWelcome()
    banner("Welcome")
    pmsg("No wallet found on this Pad.", 5)
    pmsg("", 6)
    pmsg("  [1] Create a new wallet", 7, colors.orange)
    pmsg("  [2] Import existing key",  8, colors.orange)
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
    pmsg("Player: " .. playerName, 5, colors.orange)
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
        pmsg("  [A] Add node",    base,     colors.orange)
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
            pmsg("  [2] Fetch via setup password",   11, colors.orange)

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
                    pmsg("Setup password for this node:", 13, colors.orange)
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

-- ── AmiVault ──────────────────────────────────────────────────────────────────
local function screenVault(secretKey, address, nodes)
    if #nodes == 0 then
        banner("AmiVault")
        pmsg("No nodes configured.", 5, colors.red)
        pmsg("Add a node first with [N].", 6)
        waitKey()
        return
    end
    local node = nodes[1]

    local NKEYS = { keys.one, keys.two, keys.three, keys.four, keys.five,
                    keys.six, keys.seven, keys.eight, keys.nine }

    while true do
        banner("AmiVault")
        pmsg("Fetching vaults from " .. node.name .. "...", 5, colors.yellow)
        local ok, data, err = comms.listVaults(secretKey, node.key, address)
        local vaults = (ok and data and type(data.vaults) == "table") and data.vaults or {}
        cls()
        banner("AmiVault")
        pmsg("Node: " .. node.name, 4, colors.gray)

        if not ok then
            pmsg("Error: " .. (err or "failed"), 5, colors.red)
        elseif #vaults == 0 then
            pmsg("No active vaults.", 5, colors.gray)
        else
            for i, v in ipairs(vaults) do
                local ami = string.format("%.4f AMI", v.amount / 1000000)
                if v.locked then
                    local m = math.floor(v.remaining / 60)
                    local s = v.remaining % 60
                    pmsg(string.format("  %d: %s  LOCKED %dm %ds", i, ami, m, s), 5 + i, colors.yellow)
                else
                    pmsg(string.format("  %d: %s  READY [%d] to unlock", i, ami, i), 5 + i, colors.lime)
                end
            end
        end

        local base = 6 + math.max(1, #vaults)
        pmsg("  [L] Lock new coins", base,     colors.orange)
        pmsg("  [B] Back",           base + 1, colors.gray)

        local _, key = os.pullEvent("key")

        if key == keys.l then
            -- Lock flow
            banner("AmiVault - Lock")
            pmsg("Duration:", 5)
            pmsg("  [1] 5 minutes  (300s)",    6, colors.white)
            pmsg("  [2] 30 minutes (1800s)",   7, colors.white)
            pmsg("  [3] 2 hours    (7200s)",   8, colors.white)
            pmsg("  [4] Custom",               9, colors.white)
            local dur = nil
            while not dur do
                local _, dk = os.pullEvent("key")
                if     dk == keys.one  or dk == keys.n1 then dur = 300
                elseif dk == keys.two  or dk == keys.n2 then dur = 1800
                elseif dk == keys.three or dk == keys.n3 then dur = 7200
                elseif dk == keys.four or dk == keys.n4 then
                    local sStr = prompt("Duration (seconds): ", 11)
                    dur = tonumber(sStr)
                    if not dur or dur <= 0 then
                        pmsg("Invalid.", 13, colors.red)
                        os.sleep(1)
                        dur = nil
                    end
                end
            end
            pmsg("Amount to lock (AMI):", 11)
            local rawAmt = prompt("> ", 13)
            local amt = tonumber(rawAmt)
            if not amt or amt <= 0 then
                pmsg("Invalid amount.", 15, colors.red)
                waitKey()
            else
                local micro = math.floor(amt * 1000000)
                local m = math.floor(dur / 60)
                local s = dur % 60
                pmsg(string.format("Locking %.4f AMI for %dm %ds...", amt, m, s), 15, colors.yellow)
                local ok2, data2, err2 = comms.vaultLock(secretKey, node.key, address, micro, dur)
                if ok2 then
                    local vid = (data2 and data2.vault_id) or "?"
                    pmsg("Vault created! ID: " .. vid:sub(1, 12) .. "...", 16, colors.green)
                else
                    pmsg("Failed: " .. (err2 or "unknown"), 16, colors.red)
                end
                waitKey()
            end

        elseif key == keys.b then
            return

        else
            -- Number keys unlock ready vaults
            for i, nk in ipairs(NKEYS) do
                if key == nk and vaults[i] and not vaults[i].locked then
                    banner("AmiVault - Unlock")
                    pmsg("Unlocking vault #" .. i .. "...", 5, colors.yellow)
                    local ok2, data2, err2 = comms.vaultUnlock(secretKey, node.key, address, vaults[i].id)
                    if ok2 then
                        local returned = (data2 and data2.amount) or 0
                        pmsg(string.format("Unlocked! +%.6f AMI", returned / 1000000), 6, colors.green)
                    else
                        pmsg("Failed: " .. (err2 or "unknown"), 6, colors.red)
                    end
                    waitKey()
                    break
                end
            end
        end
    end
end

-- ── Dashboard (Glass Cockpit) ─────────────────────────────────────────────────
local function screenDashboard(secretKey, address, nodes, playerName)
    -- Cache our own name immediately
    if playerName then cacheName(address, playerName) end

    -- ── State ────────────────────────────────────────────────────────────────
    local totalBalance = nil
    local perNode      = {}   -- {name, balance, err, latency, stats}
    local balErr       = nil
    local netStats     = nil  -- {active_wallets, total_supply, current_rate, total_ticks}

    -- ── Data refresh ─────────────────────────────────────────────────────────
    local function refreshBalance()
        if #nodes == 0 then
            totalBalance = nil; balErr = "No nodes - press [N]"; return
        end
        balErr = nil
        local total   = 0
        local newNodes = {}
        local anyOk   = false
        for _, node in ipairs(nodes) do
            local ok, data, err = comms.getBalance(secretKey, node.key, address)
            local entry = { name=node.name, balance=0, err=nil, latency=nil, stats=nil }
            if ok and data and data.balance then
                entry.balance = data.balance
                entry.latency = data._latency
                total = total + data.balance
                anyOk = true
                -- Piggyback STATS from first healthy node
                if not netStats then
                    local sok, sdata = comms.getStats(secretKey, node.key, address)
                    if sok and sdata then netStats = sdata end
                end
            else
                entry.err = err or "no response"
            end
            newNodes[#newNodes + 1] = entry
        end
        totalBalance = total
        perNode      = newNodes
        if not anyOk then balErr = "All nodes unreachable" end
    end

    -- ── Drawing helpers ───────────────────────────────────────────────────────
    local function hRule(y)
        term.setCursorPos(1, y)
        term.setTextColor(colors.gray)
        term.write(string.rep("-", W))
    end

    local function rjust(s, w)
        s = tostring(s)
        if #s >= w then return s:sub(1, w) end
        return string.rep(" ", w - #s) .. s
    end

    -- ── Draw ─────────────────────────────────────────────────────────────────
    local function draw()
        banner("Dashboard")

        -- Row 4: divider
        hRule(4)

        -- Row 5: player + short address
        local dispAddr = address:sub(1,8) .. ".." .. address:sub(-4)
        local nameStr  = (playerName or "(unknown)") .. " | " .. dispAddr
        term.setCursorPos(1, 5)
        term.setTextColor(colors.orange)
        term.write(nameStr:sub(1, W))

        -- Rows 6-7: balance
        if balErr then
            term.setCursorPos(1, 6); term.setTextColor(colors.red)
            term.write(("Balance: [" .. balErr .. "]"):sub(1, W))
            term.setCursorPos(1, 7); term.write(string.rep(" ", W))
        elseif totalBalance then
            term.setCursorPos(1, 6); term.setTextColor(colors.green)
            local ami = string.format("%.4f AMI", totalBalance / 1000000)
            term.write(ami:sub(1, W))
            term.setCursorPos(1, 7); term.setTextColor(colors.lime)
            term.write(rjust(totalBalance .. " uAMI", W))
        else
            term.setCursorPos(1, 6); term.setTextColor(colors.gray)
            term.write("Balance: press [R]")
            term.setCursorPos(1, 7); term.write(string.rep(" ", W))
        end

        -- Row 8: divider + node header
        hRule(8)
        term.setCursorPos(1, 9); term.setTextColor(colors.gray)
        local nodeHdr = string.format("%-12s %9s %6s  %s", "Node", "Balance", "Ping", "St")
        term.write(nodeHdr:sub(1, W))

        -- Rows 10..: per-node table
        local nodeRows = math.max(1, #perNode)
        for i = 1, nodeRows do
            local row = 9 + i
            local n   = perNode[i]
            if not n then
                term.setCursorPos(1, row); term.setTextColor(colors.gray)
                term.write("  (no nodes)")
            elseif n.err then
                term.setCursorPos(1, row); term.setTextColor(colors.red)
                local line = string.format("%-12s %9s %6s  [!]",
                    n.name:sub(1,12), "---", "---")
                term.write(line:sub(1, W))
            else
                local bal     = string.format("%.4f", n.balance / 1000000)
                local ping    = n.latency and (n.latency .. "ms") or "---"
                term.setCursorPos(1, row); term.setTextColor(colors.white)
                local line = string.format("%-12s %9s %6s  ", n.name:sub(1,12), bal, ping)
                term.write(line:sub(1, W - 4))
                term.setTextColor(colors.lime); term.write("[OK]")
            end
        end

        -- Network stats row
        local statsRow = 10 + nodeRows
        hRule(statsRow)
        term.setCursorPos(1, statsRow + 1)
        if netStats then
            term.setTextColor(colors.lightGray)
            local earn_hr = (netStats.current_rate or 0) * 60
            local line = string.format("Net %d active  %d uAMI/tick  +%d/hr",
                netStats.active_wallets or 0,
                netStats.current_rate   or 0,
                earn_hr)
            term.write(line:sub(1, W))
        else
            term.setTextColor(colors.gray)
            term.write("[R] to load network stats")
        end

        -- Menu rows
        local menuRow = statsRow + 2
        hRule(menuRow)
        term.setCursorPos(1, menuRow + 1); term.setTextColor(colors.orange)
        term.write("[S]end [R]efresh [E]xport [N]odes(" .. #nodes .. ")")
        term.setCursorPos(1, menuRow + 2)
        term.setTextColor(colors.pink);   term.write("[V]")
        term.setTextColor(colors.orange); term.write("ault  ")
        term.setTextColor(colors.orange); term.write("[U]pdate  ")
        term.setTextColor(colors.gray);   term.write("[L]ogout")
    end

    refreshBalance()
    draw()

    while true do
        local ev, p1 = os.pullEvent()

        if ev == "key" then

            if p1 == keys.r then
                cls(); banner("Dashboard")
                term.setCursorPos(1, 6); term.setTextColor(colors.yellow)
                term.write("Refreshing...")
                refreshBalance(); draw()

            elseif p1 == keys.s then
                banner("Send AMI")
                if #nodes == 0 then
                    pmsg("No nodes configured.", 5, colors.red)
                    pmsg("Add a node first with [N].", 6)
                    waitKey(); draw()
                else
                    pmsg("Recipient (player name or address):", 5)
                    local toRaw = prompt("> ", 7)
                    toRaw = toRaw:gsub("^%s*(.-)%s*$", "%1")
                    local toAddr = nil

                    if #toRaw == 128 and toRaw:match("^[0-9a-fA-F]+$") then
                        toAddr = toRaw:lower()
                    else
                        pmsg("Looking up '" .. toRaw .. "'...", 9, colors.yellow)
                        local ok, data, err = comms.lookupAll(secretKey, address, toRaw, nodes)
                        if ok and data and data.address then
                            toAddr = data.address
                            cacheName(toAddr, toRaw)  -- Ami-DNS: cache resolved name
                            pmsg("Found: " .. resolveAddr(toAddr), 10, colors.green)
                        else
                            pmsg("Not found: " .. (err or "unknown"), 9, colors.red)
                            waitKey(); draw()
                        end
                    end

                    if toAddr then
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
                        pmsg("Amount (AMI):", amtRow)
                        local rawAmt = prompt("> ", amtRow + 2)
                        local amt = tonumber(rawAmt)
                        if not amt or amt <= 0 then
                            pmsg("Invalid amount.", amtRow + 4, colors.red); waitKey()
                        else
                            local microAmt = math.floor(amt * 1000000)
                            pmsg("Sending via " .. chosenNode.name .. "...", amtRow + 4, colors.yellow)
                            local ok, _, err = comms.transfer(secretKey, chosenNode.key, address, toAddr, microAmt)
                            if ok then
                                pmsg(string.format("Sent %.4f AMI to %s", amt, resolveAddr(toAddr)), amtRow + 4, colors.green)
                            else
                                pmsg("Failed: " .. (err or "unknown"), amtRow + 4, colors.red)
                            end
                            waitKey(); refreshBalance()
                        end
                    end
                    draw()
                end

            elseif p1 == keys.e then
                banner("Export Secret Key")
                if playerName then pmsg("Player: " .. playerName, 5, colors.orange) end
                pmsg("Your SECRET KEY is:", 7, colors.red)
                pmsg(secretKey:sub(1, 16),  9, colors.yellow)
                pmsg(secretKey:sub(17, 32), 10, colors.yellow)
                pmsg("Never share this with anyone.",  12, colors.red)
                pmsg("Use it to migrate to a new Pad.", 13, colors.lightGray)
                waitKey(); draw()

            elseif p1 == keys.n then
                nodes = screenNodeManager(nodes, secretKey, address)
                draw()

            elseif p1 == keys.v then
                screenVault(secretKey, address, nodes); draw()

            elseif p1 == keys.u then
                screenUpdate(); draw()

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
        pmsg("  [2] Fetch via setup password",   8, colors.orange)
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
                pmsg("Setup password for the node:", 11, colors.orange)
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
    if playerName then cacheName(address, playerName) end  -- Ami-DNS: seed local cache

    -- 7. First heartbeat + start 60s timer
    comms.heartbeatAll(secretKey, address, nodes)
    os.startTimer(60)

    -- 8. Main dashboard
    screenDashboard(secretKey, address, nodes, playerName)

    os.reboot()
end

boot()
