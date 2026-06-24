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

-- Opus UI framework
local UI       = require('ami.lib.ui.ui')
local Theme    = require('ami.lib.ui.theme')
local Event    = require('ami.lib.ui.event')

-- Set demon theme
Theme.setTheme('demon')

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
-- Format: array of { name="...", key="...", known_fp="..." }
local NODES_FILE  = "/wallet_data/nodes.json"
local LEGACY_KEY  = "/wallet_data/node_key.txt"
local NAMES_CACHE = "/wallet_data/names_cache.json"
local CONFIG_FILE = "/wallet_data/config.json"

-- ── Wallet config (auto-sweep etc.) ──────────────────────────────────────────
local _config = nil
local function loadConfig()
    if _config then return _config end
    if fs.exists(CONFIG_FILE) then
        local f = fs.open(CONFIG_FILE, "r")
        _config = textutils.unserialiseJSON(f.readAll()) or {}
        f.close()
    else
        _config = {}
    end
    -- Apply defaults
    if _config.autoSweep      == nil   then _config.autoSweep      = false   end
    if not _config.sweepThreshold      then _config.sweepThreshold = 1000000 end  -- 1 AMI
    if not _config.sweepDuration       then _config.sweepDuration  = 3600    end  -- 1 hour
    return _config
end
local function saveConfig()
    if not fs.exists("/wallet_data") then fs.makeDir("/wallet_data") end
    local f = fs.open(CONFIG_FILE, "w")
    f.write(textutils.serialiseJSON(_config or {}))
    f.close()
end

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
-- Reverse-resolve: scan the cache for a name match (case-insensitive).
-- Returns the 128-hex address string, or nil if not found.
local function reverseResolve(name)
    if type(name) ~= "string" or #name == 0 then return nil end
    local c = loadNameCache()
    local lower = name:lower()
    for addr, n in pairs(c) do
        if n:lower() == lower then return addr end
    end
    return nil
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
local RATE_URL  = "https://dumpcafe.amie-whoogle.app/DUMP/reward_rate.txt"
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

-- ── Command Center ───────────────────────────────────────────────────────────
-- Single hub for node management, integrity checks, and DNS propagation.
local function screenCommandCenter(nodes, secretKey, address, perNodeBalances)
    while true do
        banner("Command Center")
        if #nodes == 0 then
            pmsg("No nodes configured.", 5, colors.gray)
        else
            for i, node in ipairs(nodes) do
                local fp_badge = ""
                if node.fp_mismatch      then fp_badge = " [!]"
                elseif not node.known_fp then fp_badge = " [?]"
                end
                local col = node.fp_mismatch and colors.red or colors.white
                -- Show per-node balance if available from last refresh
                local balStr = ""
                if perNodeBalances and perNodeBalances[i] then
                    local bal = perNodeBalances[i].balance or 0
                    balStr = string.format(" %duAMI", bal)
                end
                local label = string.format("[%d] %-9s%s%s",
                    i, node.name:sub(1, 9), balStr, fp_badge)
                pmsg(label:sub(1, W), 4 + i, col)
            end
        end
        local base = 6 + #nodes
        pmsg("  [A] Add node",    base,     colors.orange)
        if #nodes > 0 then
            pmsg("  [D] Remove node",           base + 1, colors.red)
            pmsg("  [I] Integrity Handshake",   base + 2, colors.yellow)
            pmsg("  [G] Gossip DNS cache",       base + 3, colors.cyan)
            pmsg("  [C] Consolidate balances",  base + 4, colors.lime)
        end
        pmsg("  [B] Back", base + (#nodes > 0 and 5 or 1), colors.gray)

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
                    pmsg("32-char XTEA key from node boot:", 13)
                    local k = prompt("> ", 15)
                    k = k:gsub("%s",""):lower()
                    if #k == 0 then
                        pmsg("Cancelled.", 17, colors.gray); os.sleep(0.8)
                    elseif #k ~= 32 then
                        pmsg("Invalid (must be 32 hex chars).", 17, colors.red); waitKey()
                    else
                        addKey = k
                    end
                    break
                elseif ak == keys.two or ak == keys.n2 then
                    pmsg("Setup password for this node:", 13, colors.orange)
                    local pw = prompt("> ", 15, true)
                    if #pw == 0 then
                        pmsg("Cancelled.", 17, colors.gray); os.sleep(0.8)
                    else
                        pmsg("Contacting node...", 17, colors.yellow)
                        local ok, k, err = comms.fetchNodeKey(secretKey, address, pw)
                        if ok and k then
                            addKey = k
                            pmsg("Got key!", 17, colors.green); os.sleep(0.5)
                        else
                            pmsg("Failed: " .. (err or "unknown"), 17, colors.red); waitKey()
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
                pmsg(string.format("  [%d] %s", i, node.name), 5 + i, colors.white)
            end
            local promptRow = 6 + #nodes
            pmsg("Enter number (0=cancel):", promptRow, colors.yellow)
            local inp = prompt("> ", promptRow + 1)
            local idx = tonumber(inp)
            if idx and idx >= 1 and idx <= #nodes then
                local removed = nodes[idx].name
                table.remove(nodes, idx)
                saveNodes(nodes)
                banner("Remove Node")
                pmsg("Removed '" .. removed .. "'.", 5, colors.green)
                os.sleep(0.8)
            else
                pmsg("Cancelled.", promptRow + 2, colors.gray)
                os.sleep(0.5)
            end

        elseif key == keys.i and #nodes > 0 then
            -- ── Integrity Handshake ─────────────────────────────────────────
            -- Processes nodes strictly in priority order (list position 1…N).
            -- send() now ignores replies that don't decrypt with the target
            -- node's key, so other nodes on the mesh cannot interfere.
            -- Live [idx/total] progress is shown before each blocking call.
            local ok_ct  = 0
            local mis_ct = 0
            local results = {}   -- accumulate so we can redraw as we go

            for idx, node in ipairs(nodes) do
                -- Show progress header BEFORE the blocking network call
                banner("Integrity Handshake")
                pmsg(string.format("[%d/%d] Querying '%s'...",
                    idx, #nodes, node.name:sub(1,14)), 5, colors.yellow)
                -- Re-draw already-completed results above the fold
                local rrow = 7
                for _, r in ipairs(results) do
                    pmsg(r.line, rrow, r.col); rrow = rrow + 1
                    if r.sub1 then pmsg(r.sub1, rrow, r.col2);   rrow = rrow + 1 end
                    if r.sub2 then pmsg(r.sub2, rrow, colors.orange); rrow = rrow + 1 end
                end

                -- Blocking call — only accepts a reply encrypted with node.key
                local ok, data, err = comms.getFingerprint(secretKey, node.key, address)

                local entry = {}
                if ok and data and data.fingerprint then
                    local fp = data.fingerprint
                    if not node.known_fp then
                        node.known_fp    = fp
                        node.fp_mismatch = false
                        ok_ct = ok_ct + 1
                        entry.line = string.format("  [%d] %-12s TOFC  %s",
                            idx, node.name:sub(1,12), fp)
                        entry.col  = colors.yellow
                    elseif node.known_fp == fp then
                        node.fp_mismatch = false
                        ok_ct = ok_ct + 1
                        entry.line = string.format("  [%d] %-12s OK    %s",
                            idx, node.name:sub(1,12), fp)
                        entry.col  = colors.green
                    else
                        node.fp_mismatch = true
                        mis_ct = mis_ct + 1
                        entry.line     = string.format("  [%d] %-12s !! MISM",
                            idx, node.name:sub(1,10))
                        entry.col      = colors.red
                        entry.sub1     = string.format("       got:  %s", fp)
                        entry.col2     = colors.red
                        entry.sub2     = string.format("       want: %s", node.known_fp)
                        entry.new_fp   = fp       -- new hash from node
                        entry.node_idx = idx      -- so Trust can update the right slot
                    end
                else
                    entry.line = string.format("  [%d] %-12s ERR   %s",
                        idx, node.name:sub(1,12), err or "?")
                    entry.col  = colors.red
                end
                results[#results + 1] = entry
            end

            -- Final full render with summary
            banner("Integrity Handshake")
            local rrow = 5
            for _, r in ipairs(results) do
                pmsg(r.line, rrow, r.col); rrow = rrow + 1
                if r.sub1 then pmsg(r.sub1, rrow, r.col2);      rrow = rrow + 1 end
                if r.sub2 then pmsg(r.sub2, rrow, colors.orange); rrow = rrow + 1 end
            end
            rrow = rrow + 1
            pmsg(string.format("Done: %d/%d OK  %d mismatch", ok_ct, #nodes, mis_ct),
                rrow, mis_ct > 0 and colors.red or colors.green)
            if mis_ct > 0 then
                rrow = rrow + 1
                pmsg("[T] Trust new  [any] Back", rrow, colors.yellow)
            end
            saveNodes(nodes)
            if mis_ct > 0 then
                -- Wait: if user presses T, accept all new fingerprints.
                local _, tkey = os.pullEvent("key")
                if tkey == keys.t then
                    for _, r in ipairs(results) do
                        if r.new_fp and r.node_idx then
                            nodes[r.node_idx].known_fp    = r.new_fp
                            nodes[r.node_idx].fp_mismatch = false
                        end
                    end
                    saveNodes(nodes)
                    banner("Integrity Handshake")
                    pmsg("Fingerprints updated and trusted.", 5, colors.green)
                    pmsg("Re-run handshake to confirm.", 6, colors.lightGray)
                    os.sleep(1.5)
                end
            else
                waitKey()
            end

        elseif key == keys.g and #nodes > 0 then
            -- ── Gossip DNS cache ────────────────────────────────────────────
            -- Propagates every locally-cached name→address pair to all nodes
            -- so the whole mesh shares the same directory.
            banner("Gossip DNS")
            local cache = loadNameCache()
            local names = {}
            for addr, name in pairs(cache) do
                names[#names + 1] = { addr=addr, name=name }
            end
            if #names == 0 then
                pmsg("Name cache is empty. Nothing to gossip.", 5, colors.gray)
            else
                pmsg(string.format("Gossiping %d name(s) to %d node(s)...",
                    #names, #nodes), 5, colors.yellow)
                for _, entry in ipairs(names) do
                    comms.gossipDnsAll(secretKey, address, nodes, entry.name, entry.addr)
                end
                pmsg(string.format("Sent %d entries to all nodes.", #names), 7, colors.green)
            end
            waitKey()

        elseif key == keys.c and #nodes > 1 then
            -- ── Consolidate: sweep all balances into one node ───────────────
            -- 1. Fetch the live balance from every node.
            -- 2. Show the per-node breakdown and let the operator pick the
            --    target node (default = highest-balance node).
            -- 3. For every other node that has a non-zero balance, issue a
            --    TRANSFER of its full balance to the target node's address.
            banner("Consolidate Balances")
            pmsg("Fetching balances...", 5, colors.yellow)

            -- Build per-node balance table.
            local nodeBalances = {}
            local highestBal   = 0
            local defaultIdx   = 1
            for i, node in ipairs(nodes) do
                local ok, data = comms.getBalance(secretKey, node.key, address)
                local bal = (ok and data and data.balance) or 0
                nodeBalances[i] = bal
                if bal > highestBal then highestBal = bal; defaultIdx = i end
            end

            -- Show breakdown.
            banner("Consolidate Balances")
            for i, node in ipairs(nodes) do
                local bstr = string.format("%.4f AMI", nodeBalances[i] / 1000000)
                pmsg(string.format("  [%d] %-14s %s",
                    i, node.name:sub(1,14), bstr), 4 + i,
                    i == defaultIdx and colors.lime or colors.white)
            end

            local promptRow = 5 + #nodes
            pmsg(string.format("Target node? [1-%d] (Enter=%d):",
                #nodes, defaultIdx), promptRow, colors.yellow)
            local inp = prompt("> ", promptRow + 1)
            inp = inp:gsub("%s", "")
            local targetIdx = (#inp > 0 and tonumber(inp)) or defaultIdx
            if not targetIdx or targetIdx < 1 or targetIdx > #nodes then
                targetIdx = defaultIdx
            end

            local targetNode = nodes[targetIdx]

            -- Fetch the target node's registered address (its shop/wallet addr).
            -- We look up the target node key itself as the recipient address:
            -- "which address does this node hold coins for this wallet?" = our
            -- own address.  Consolidate moves OUR balance from each source
            -- node into the target node by doing a TRANSFER from our wallet
            -- on the source node TO our own address on the target node.
            -- Because all nodes share the same ledger mesh, this is a simple
            -- on-chain transfer — the sending node deducts, the target node
            -- credits the same address via mesh consensus.

            banner("Consolidate Balances")
            pmsg(string.format("Target: %s", targetNode.name), 5, colors.lime)
            local moved = 0
            local errs  = 0
            local row   = 7
            for i, node in ipairs(nodes) do
                if i ~= targetIdx then
                    -- Dust fix: ensure integer microcoins.
                    local bal = math.floor(nodeBalances[i] or 0)
                    if bal > 0 then
                        -- ── Step 1: DRAIN source node ────────────────────────
                        pmsg(string.format("  [1/2] DRAIN  %s  %d uAMI...",
                            node.name:sub(1, 10), bal), row, colors.yellow)
                        row = row + 1
                        local dok, ddata, derr = comms.consolidateOut(
                            secretKey, node.key, address, bal)
                        if not dok then
                            errs = errs + 1
                            pmsg("    DRAIN FAILED: " .. (derr or "?"), row, colors.red)
                            row = row + 1
                        else
                            local actual  = math.floor((ddata and ddata.amount) or bal)
                            local receipt = ddata and ddata.receipt
                            pmsg(string.format("    drained %d uAMI  [%s]",
                                actual, tostring(receipt):sub(1, 8)), row, colors.lime)
                            row = row + 1
                            -- ── Step 2: CREDIT target node ───────────────────
                            pmsg(string.format("  [2/2] CREDIT %s  %d uAMI...",
                                targetNode.name:sub(1, 10), actual), row, colors.yellow)
                            row = row + 1
                            local cok, _, cerr = comms.consolidateIn(
                                secretKey, targetNode.key, address, actual, receipt)
                            if cok then
                                moved = moved + actual
                                pmsg(string.format("    credited %d uAMI OK", actual),
                                    row, colors.green)
                            else
                                errs = errs + 1
                                pmsg("    CREDIT FAILED: " .. (cerr or "?"),
                                    row, colors.red)
                            end
                            row = row + 1
                        end
                    else
                        pmsg(string.format("  %s: 0 balance, skip",
                            node.name:sub(1, 14)), row, colors.gray)
                        row = row + 1
                    end
                end
            end
            row = row + 1
            pmsg(string.format("Consolidated %d uAMI  (%d error(s))",
                moved, errs),
                row, errs > 0 and colors.red or colors.green)
            waitKey()

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
        pmsg("  [L] Lock new coins", base, colors.orange)

        -- Auto-Sweep toggle line
        local cfg = loadConfig()
        local sweepAMI = string.format("%.4f", cfg.sweepThreshold / 1000000)
        local sweepLabel = cfg.autoSweep
            and string.format("  [T] Auto-Sweep ON >%s AMI", sweepAMI)
            or  "  [T] Auto-Sweep OFF"
        pmsg(sweepLabel, base + 1, cfg.autoSweep and colors.lime or colors.gray)
        pmsg("  [B] Back", base + 2, colors.gray)

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

        elseif key == keys.t then
            -- Auto-Sweep: toggle on/off and configure threshold/duration
            local cfg2 = loadConfig()
            cfg2.autoSweep = not cfg2.autoSweep
            banner("Auto-Sweep")
            if cfg2.autoSweep then
                pmsg("Auto-Sweep ENABLED.", 5, colors.lime)
                pmsg("Safety limit (AMI):", 7, colors.white)
                pmsg("Coins earned ABOVE this are auto-locked.", 8, colors.lightGray)
                local tRaw = prompt("> ", 10)
                local t = tonumber(tRaw)
                if t and t > 0 then
                    cfg2.sweepThreshold = math.floor(t * 1000000)
                    pmsg(string.format("Threshold: %.4f AMI", t), 12, colors.green)
                else
                    pmsg("Keeping: " .. string.format("%.4f AMI", cfg2.sweepThreshold / 1000000), 12, colors.gray)
                end
                pmsg("Vault duration in seconds (0=1hr):", 14, colors.white)
                local dRaw = prompt("> ", 15)
                local d = tonumber(dRaw)
                cfg2.sweepDuration = (d and d > 0) and math.floor(d) or 3600
                pmsg(string.format("Duration: %ds", cfg2.sweepDuration), 16, colors.green)
            else
                pmsg("Auto-Sweep DISABLED.", 5, colors.gray)
            end
            saveConfig()
            os.sleep(1.2)

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

-- ── AmiStore invoice popup ───────────────────────────────────────────────────
-- Called when a plaintext INVOICE packet arrives on channel 1338 addressed
-- to this wallet's address. Returns after the player accepts or declines.
local function invoicePopup(pkt, secretKey, address, nodes)
    -- Validate required fields before displaying anything.
    if type(pkt) ~= "table"
        or type(pkt.tx_id)     ~= "string"
        or type(pkt.shop_addr) ~= "string"
        or type(pkt.total)     ~= "number"
        or type(pkt.item)      ~= "string" then
        return  -- malformed packet — silently ignore
    end

    local shopName  = tostring(pkt.shop_name or "Unknown Shop")
    local itemShort = (pkt.item:match(":(.+)$") or pkt.item)
    local qty       = math.max(1, math.floor(tonumber(pkt.qty) or 1))
    local total     = pkt.total
    local amiStr    = string.format("%.4f AMI", total / 1000000)

    -- Draw the interrupt screen.
    cls()
    banner("Incoming Invoice")
    term.setCursorPos(1, 4); term.setTextColor(colors.gray)
    term.write(string.rep("-", W))

    term.setCursorPos(1, 5); term.setTextColor(colors.orange)
    term.write(("Shop : " .. shopName):sub(1, W))
    term.setCursorPos(1, 6); term.setTextColor(colors.white)
    term.write(("Item : " .. itemShort):sub(1, W))
    term.setCursorPos(1, 7)
    term.write(("Qty  : " .. qty):sub(1, W))
    term.setCursorPos(1, 8); term.setTextColor(colors.yellow)
    term.write(("Total: " .. total .. " uAMI  (" .. amiStr .. ")"):sub(1, W))

    term.setCursorPos(1, 9); term.setTextColor(colors.gray)
    term.write(string.rep("-", W))
    term.setCursorPos(1, 10); term.setTextColor(colors.lime)
    term.write("[Y] Accept & pay")
    term.setCursorPos(1, 11); term.setTextColor(colors.red)
    term.write("[N] Decline")
    term.setCursorPos(1, 13); term.setTextColor(colors.gray)
    term.write(("TX: " .. pkt.tx_id:sub(1, W - 4)):sub(1, W))

    -- Wait for Y or N key.
    while true do
        local _, k = os.pullEvent("key")
        if k == keys.y then
            if #nodes == 0 then
                cls(); banner("Invoice Error")
                pmsg("No nodes configured -- cannot pay.", 5, colors.red)
                os.sleep(2)
                return
            end
            cls(); banner("Paying...")
            term.setCursorPos(1, 5); term.setTextColor(colors.yellow)
            term.write("Sending " .. total .. " uAMI to shop...")
            local ok, result, err = comms.transfer(
                secretKey, nodes[1].key, address, pkt.shop_addr, total)
            if ok then
                -- Notify the shop so it can dispense immediately.
                comms.sendPaymentAck(address, pkt.tx_id)
                term.setCursorPos(1, 7); term.setTextColor(colors.lime)
                term.write("Payment sent! Awaiting item dispensing.")
            else
                term.setCursorPos(1, 7); term.setTextColor(colors.red)
                term.write(("Failed: " .. (err or "unknown")):sub(1, W))
            end
            os.sleep(2)
            return
        elseif k == keys.n then
            -- Decline -- let the invoice expire naturally on the shop side.
            return
        end
    end
end

-- ── Dashboard (Glass Cockpit) ─────────────────────────────────────────────────
local function screenDashboard(secretKey, address, nodes, playerName)
    -- Cache our own name immediately
    if playerName then cacheName(address, playerName) end

    -- Load wallet UI module
    local WalletUI = require("wallet_ui")
    
    -- ── State ────────────────────────────────────────────────────────────────
    local totalBalance  = nil
    local perNode       = {}   -- {name, balance, err, latency, stats}
    local balErr        = nil
    local netStats      = nil  -- {active_wallets, total_supply, current_rate, total_ticks}
    local liveRate      = nil  -- fetched from GitHub reward_rate.txt
    -- Track which nodes we've successfully registered on so we can retry
    -- nodes that were offline at boot.
    local registered    = {}
    
    -- Dashboard UI page
    -- disableEffects() is REQUIRED: it makes Device:sync() skip runTransitions(),
    -- whose `while true ... os.sleep(0)` loop otherwise hangs forever on setPage
    -- (the same "zombie UI" deadlock the node hit). See repo memory / node startup.
    UI:disableEffects()
    local dashboardPage = WalletUI.createDashboard(address, playerName)
    
    -- ── Data refresh ─────────────────────────────────────────────────────────
    local function fetchLiveRate()
        local ok, res = pcall(http.get, RATE_URL)
        if not ok or not res then return end
        local body = res.readAll()
        res.close()
        local clean_body = (body or ""):gsub("%s", "")
        local n = tonumber(clean_body)
        if n and n >= 1 and n <= 100000 then
            liveRate = math.floor(n)
        end
    end

    local function refreshBalance()
        if #nodes == 0 then
            totalBalance = nil; balErr = "No nodes - press [N]"; return
        end
        balErr = nil
        local total    = 0
        local newNodes = {}
        local anyOk    = false
        local cfg      = loadConfig()
        for i, node in ipairs(nodes) do
            local ok, data, err = comms.getBalance(secretKey, node.key, address)
            local entry = { name=node.name, balance=0, err=nil, latency=nil, stats=nil, fp_ok=nil }
            if ok and data and data.balance then
                entry.balance = data.balance
                entry.latency = data._latency
                total = total + data.balance
                anyOk = true
                -- Re-register on any node we haven't confirmed yet (catches nodes
                -- that were offline when the wallet first booted).
                if not registered[node.key] then
                    comms.register(secretKey, node.key, address, playerName)
                    registered[node.key] = true
                end
                -- Fetch STATS per-node so every node gets its fingerprint checked.
                -- netStats keeps the first healthy node's aggregate data for the
                -- dashboard network row; fingerprint is validated independently.
                local sok, sdata = comms.getStats(secretKey, node.key, address)
                if sok and sdata then
                    if not netStats then netStats = sdata end
                    entry.stats = sdata  -- store per-node so we can sum rates
                    -- Integrity: Trust-On-First-Connect or mismatch detection
                    if sdata.fingerprint then
                        local fp = sdata.fingerprint
                        if not node.known_fp then
                            node.known_fp    = fp
                            node.fp_mismatch = false
                            saveNodes(nodes)
                            entry.fp_ok = "tofc"
                        elseif node.known_fp == fp then
                            node.fp_mismatch = false
                            entry.fp_ok = true
                        else
                            node.fp_mismatch = true
                            saveNodes(nodes)
                            entry.fp_ok = false
                        end
                    end
                end
            else
                entry.err = err or "no response"
            end
            if node.fp_mismatch then entry.fp_ok = false end
            newNodes[#newNodes + 1] = entry
        end
        totalBalance = total
        perNode      = newNodes
        if not anyOk then balErr = "All nodes unreachable" end
        fetchLiveRate()
        -- Auto-Sweep: lock excess balance if enabled
        if cfg.autoSweep and totalBalance and totalBalance > cfg.sweepThreshold and #nodes > 0 then
            local sweepAmt = totalBalance - cfg.sweepThreshold
            if sweepAmt > 0 then
                comms.vaultLock(secretKey, nodes[1].key, address, sweepAmt, cfg.sweepDuration)
            end
        end
    end
    
    -- ── Update UI ────────────────────────────────────────────────────────────
    local function updateDashboard()
        local onlineCount = 0
        for _, n in ipairs(perNode) do
            if not n.err then onlineCount = onlineCount + 1 end
        end
        WalletUI.updateDashboard(dashboardPage, totalBalance, onlineCount, #nodes, netStats, perNode)
    end
    
    -- ── Event handlers ───────────────────────────────────────────────────────
    function dashboardPage:eventHandler(event)
        if event.type == 'action_refresh' then
            refreshBalance()
            updateDashboard()
            return true

        elseif event.type == 'action_send' then
            -- Send AMI (fallback to text UI)
            term.clear()
            term.setCursorPos(1, 1)
            term.setBackgroundColor(colors.black)
            term.setTextColor(colors.white)
            banner("Send AMI")
            if #nodes == 0 then
                pmsg("No nodes configured.", 5, colors.red)
                pmsg("Add a node first with Nodes.", 6)
                waitKey()
            else
                pmsg("Recipient (player name or address):", 5)
                local toRaw = prompt("> ", 7)
                toRaw = toRaw:gsub("^%s*(.-)%s*$", "%1")
                local toAddr = nil

                if #toRaw == 128 and toRaw:match("^[0-9a-fA-F]+$") then
                    toAddr = toRaw:lower()
                else
                    -- 1. Check local Ami-DNS cache first (instant, works offline)
                    local cached = reverseResolve(toRaw)
                    if cached then
                        toAddr = cached
                        pmsg("Found (local): " .. resolveAddr(toAddr), 9, colors.lime)
                    else
                        -- 2. Fall back to querying all nodes
                        pmsg("Looking up '" .. toRaw .. "'...", 9, colors.yellow)
                        local ok, data, err = comms.lookupAll(secretKey, address, toRaw, nodes)
                        if ok and data and data.address then
                            toAddr = data.address
                            cacheName(toAddr, toRaw)
                            comms.gossipDnsAll(secretKey, address, nodes, toRaw, toAddr)
                            pmsg("Found: " .. resolveAddr(toAddr), 10, colors.green)
                        else
                            pmsg("Not found: " .. (err or "unknown"), 9, colors.red)
                            pmsg("Enter 128-hex address (blank=cancel):", 10, colors.yellow)
                            local raw2 = (prompt("> ", 11) or ""):gsub("%s", ""):lower()
                            if #raw2 == 128 and raw2:match("^[0-9a-fA-F]+$") then
                                toAddr = raw2
                                pmsg("Using raw address.", 12, colors.lime)
                            end
                        end
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
                    -- Unit selection
                    pmsg("Unit? [A]MI or [U]uAMI:", amtRow, colors.white)
                    local unitIn = prompt("> ", amtRow + 1)
                    local useUAMI = (unitIn:lower():sub(1,1) == "u")
                    local unitLabel = useUAMI and "uAMI" or "AMI"
                    pmsg("Amount (" .. unitLabel .. "):", amtRow + 3)
                    local rawAmt = prompt("> ", amtRow + 4)
                    local amt = tonumber(rawAmt)
                    if not amt or amt <= 0 then
                        pmsg("Invalid amount.", amtRow + 6, colors.red); waitKey()
                    else
                        local microAmt = useUAMI
                            and math.floor(amt)
                            or  math.floor(amt * 1000000)
                        pmsg("Sending via " .. chosenNode.name .. "...", amtRow + 6, colors.yellow)
                        local ok, _, err = comms.transfer(secretKey, chosenNode.key, address, toAddr, microAmt)
                        if ok then
                            local display = useUAMI
                                and string.format("%d uAMI", microAmt)
                                or  string.format("%.4f AMI", amt)
                            pmsg("Sent " .. display .. " to " .. resolveAddr(toAddr), amtRow + 6, colors.green)
                        else
                            pmsg("Failed: " .. (err or "unknown"), amtRow + 6, colors.red)
                        end
                        waitKey(); refreshBalance()
                    end
                end
            end
            UI:setPage(dashboardPage)
            updateDashboard()
            return true
            
        elseif event.type == 'action_receive' then
            -- Receive dialog (show address)
            term.clear()
            term.setCursorPos(1, 1)
            term.setBackgroundColor(colors.black)
            term.setTextColor(colors.white)
            banner("Receive AMI")
            pmsg("Share this address to receive AMI:", 5, colors.white)
            pmsg(address:sub(1, 64), 7, colors.yellow)
            pmsg(address:sub(65, 128), 8, colors.yellow)
            if playerName then
                pmsg("Ami-DNS: " .. playerName, 10, colors.lime)
            else
                pmsg("No Ami-DNS name registered", 10, colors.gray)
            end
            waitKey()
            UI:setPage(dashboardPage)
            updateDashboard()
            return true
            
        elseif event.type == 'action_export' then
            -- Export secret key
            term.clear()
            term.setCursorPos(1, 1)
            term.setBackgroundColor(colors.black)
            term.setTextColor(colors.white)
            banner("Export Secret Key")
            if playerName then pmsg("Player: " .. playerName, 5, colors.orange) end
            pmsg("Your SECRET KEY is:", 7, colors.red)
            pmsg(secretKey:sub(1, 16),  9, colors.yellow)
            pmsg(secretKey:sub(17, 32), 10, colors.yellow)
            pmsg("Never share this with anyone.",  12, colors.red)
            pmsg("Use it to migrate to a new Pad.", 13, colors.lightGray)
            waitKey()
            UI:setPage(dashboardPage)
            updateDashboard()
            return true
            
        elseif event.type == 'action_nodes' then
            -- Command Center
            nodes = screenCommandCenter(nodes, secretKey, address, perNode)
            UI:setPage(dashboardPage)
            updateDashboard()
            return true
            
        elseif event.type == 'action_vault' then
            -- Vault screen
            screenVault(secretKey, address, nodes)
            UI:setPage(dashboardPage)
            updateDashboard()
            return true
            
        elseif event.type == 'action_update' then
            -- Software update
            screenUpdate()
            return true
            
        elseif event.type == 'action_logout' then
            -- Logout
            sess.clear()
            os.reboot()
            return true
        end
    end
    
    -- Open the AmiStore broadcast channel so we receive INVOICE packets.
    comms.openShopChannel()
    
    -- Set UI page
    UI:setPage(dashboardPage)
    
    -- Initial data fetch
    refreshBalance()
    updateDashboard()
    
    -- Run all coroutines in parallel
    parallel.waitForAll(
        -- Balance refresh loop
        function()
            while true do
                sleep(5)
                refreshBalance()
                updateDashboard()
            end
        end,
        
        -- Heartbeat loop
        function()
            while true do
                sleep(60)
                comms.heartbeatAll(secretKey, address, nodes)
            end
        end,
        
        -- Invoice listener (network messages)
        function()
            while true do
                local ev, p1, p2, p3, p4 = os.pullEvent("modem_message")
                -- Only handle plaintext INVOICE broadcasts on SHOP_CHANNEL (1338).
                if p2 == 1338 and type(p4) == "string" and p4:sub(1,1) == "{" then
                    local ok2, pkt = pcall(textutils.unserialiseJSON, p4)
                    if ok2 and type(pkt) == "table"
                        and pkt.type == "INVOICE"
                        and pkt.to   == address then
                        invoicePopup(pkt, secretKey, address, nodes)
                        UI:setPage(dashboardPage)
                        updateDashboard()
                    end
                end
            end
        end,
        
        -- UI event loop
        function()
            UI:pullEvents()
        end,
        
        -- Keyboard shortcuts (legacy support)
        function()
            while true do
                local _, key = os.pullEvent("key")
                if key == keys.r then
                    refreshBalance()
                    updateDashboard()
                elseif key == keys.s then
                    dashboardPage:eventHandler({type = 'action_send'})
                elseif key == keys.e then
                    dashboardPage:eventHandler({type = 'action_export'})
                elseif key == keys.n then
                    dashboardPage:eventHandler({type = 'action_nodes'})
                elseif key == keys.v then
                    dashboardPage:eventHandler({type = 'action_vault'})
                elseif key == keys.u then
                    dashboardPage:eventHandler({type = 'action_update'})
                elseif key == keys.l then
                    dashboardPage:eventHandler({type = 'action_logout'})
                end
            end
        end
    )
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
