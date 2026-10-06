-- installexchange.lua  v1.0
-- The Great Ami Exchange -- Installer (trimmed from installshop.lua)
-- Supports Hard Update, Force Update, Clean Install, and Fresh Install.
--
-- Modes (chosen at runtime):
--   Hard Update    : Delta-checks hashes -- skips unchanged .lua files.
--                    .json data files are never touched.
--   Force Update   : Reinstalls ALL .lua files regardless of local hash.
--                    .json data files are never touched.
--   Clean Install  : Wipes /ami/exchange/ (INCLUDING the exchange's wallet
--                    key -- move its AMI out first) and reinstalls.

local VERSION   = "1.0"
local REPO_BASE = "https://raw.githubusercontent.com/Teru-dot-png/amicoin-fullpower/refs/heads/main"

local FILES = {
    { src = "/shared/xtea.lua",               dst = "/shared/xtea.lua"               },
    { src = "/ami/exchange/exchange_api.lua", dst = "/ami/exchange/exchange_api.lua" },
    { src = "/ami/exchange/exchange_ui.lua",  dst = "/ami/exchange/exchange_ui.lua"  },
    { src = "/ami/exchange/startup.lua",      dst = "/ami/exchange/startup.lua"      },
}

-- Only the node list is templated; exchange_api.lua fills in every other default.
local TEMPLATE_CONFIG   = {
    nodes = {},
}

-- JSON data paths that belong to this service.
local DATA_PATHS = {
    "/ami/exchange/config.json",
}

-- Paths wiped on Clean Install (lua + data dirs, NOT /shared/xtea.lua which
-- is shared across services and will be overwritten by the download loop).
local CLEAN_DIRS  = { "/ami/exchange" }
local CLEAN_FILES = { "/shared/xtea.lua" }

-- ── Smart Update Engine ──────────────────────────────────────────────────────

local function fnv1a(s)
    local hash = 2166136261
    for i = 1, #s do
        hash = bit32.bxor(hash, string.byte(s, i))
        hash = (hash * 16777619) % 4294967296
    end
    return string.format("%08x", hash)
end

local function hashFile(path)
    if not fs.exists(path) then return nil end
    local f = fs.open(path, "r")
    local c = f.readAll(); f.close()
    return fnv1a(c)
end

local function fetchRemote(url)
    local res = http.get(url)
    if not res then
        return nil, nil, "HTTP request failed: " .. url
    end
    local content = res.readAll(); res.close()
    if #content < 64 then
        return nil, nil, string.format(
            "Response only %d bytes (likely a 404)", #content)
    end
    return content, fnv1a(content), nil
end

-- forceWrite=true bypasses the delta skip (Force Update mode).
local function smartInstall(dst, content, remoteHash, forceWrite)
    if not dst:match("%.lua$") then
        return nil, "Refusing to overwrite non-.lua file: " .. dst
    end
    local dir = dst:match("^(.*)/[^/]+$")
    if dir and dir ~= "" and not fs.exists(dir) then fs.makeDir(dir) end

    local existed = fs.exists(dst)
    local bakPath = dst .. ".bak"

    if existed and not forceWrite then
        if hashFile(dst) == remoteHash then
            return "skip", nil
        end
    end
    if existed then
        if fs.exists(bakPath) then fs.delete(bakPath) end
        if not pcall(fs.copy, dst, bakPath) then
            return nil, "Backup failed for " .. dst
        end
    end

    local writeOk = pcall(function()
        local f = fs.open(dst, "w"); f.write(content); f.close()
    end)
    if not writeOk then
        if existed and fs.exists(bakPath) then
            if fs.exists(dst) then pcall(fs.delete, dst) end
            pcall(fs.copy, bakPath, dst)
        end
        return nil, "Write failed -- restored from backup"
    end

    if hashFile(dst) ~= remoteHash then
        if existed and fs.exists(bakPath) then
            pcall(fs.delete, dst)
            pcall(fs.copy, bakPath, dst)
        end
        return nil, "Hash mismatch after write -- restored from backup"
    end

    return existed and "updated" or "fresh", nil
end

local function writeJSON(path, tbl)
    local dir = path:match("^(.*)/[^/]+$")
    if dir and dir ~= "" and not fs.exists(dir) then fs.makeDir(dir) end
    local f = fs.open(path, "w")
    f.write(textutils.serialiseJSON(tbl))
    f.close()
end

-- ── Hardware checklist ────────────────────────────────────────────────────────
local SIDE_CHECKS = {
    { side = "top",    expect = "monitor",   role = "Monitor (status board, optional)" },
    { side = "back",   expect = "modem",     role = "Modem (Mesh Comms)"               },
}

local function checkHardware()
    local allOK = true
    print("\nHardware verification:")
    for _, c in ipairs(SIDE_CHECKS) do
        local present = peripheral.isPresent(c.side)
        local ptype   = present and peripheral.getType(c.side) or "absent"
        local pass
        if not present then
            pass = false
        elseif c.expect == "modem" then
            pass = ptype:find("modem") ~= nil
        elseif c.expect == "inventory" then
            pass = ptype:find("inventory") ~= nil or ptype:find("chest") ~= nil
                   or ptype:find("barrel") ~= nil
        elseif c.expect == "me_bridge" then
            pass = ptype:find("me_bridge") ~= nil
        else
            pass = ptype:find(c.expect) ~= nil
        end
        local icon = pass and "[OK]" or "[--]"
        term.setTextColor(pass and colors.green or colors.yellow)
        print(string.format("  %s %-7s  %-16s  %s",
              icon, c.side:upper() .. ":", ptype, c.role))
        if not pass then allOK = false end
    end
    term.setTextColor(colors.white)
    local hasCmd = peripheral.find("command") ~= nil or commands ~= nil
    term.setTextColor(hasCmd and colors.green or colors.yellow)
    print(string.format("  %s %-7s  %-16s  %s",
          hasCmd and "[OK]" or "[--]", "ANY:", hasCmd and "command" or "absent",
          "Command block (runs /coins)"))
    term.setTextColor(colors.white)
    if not hasCmd then
        allOK = false
        print("\n  No command block seen. It needs command_block_enabled = true")
        print("  in the CC:Tweaked server config, and must touch this computer.")
    end
    if not allOK then
        print("\n  Some peripherals missing. Install will continue.")
    end
    return allOK
end

-- ── Banner ────────────────────────────────────────────────────────────────────
term.setTextColor(colors.orange)
print("============================================")
print("  The Great Ami Exchange v" .. VERSION .. " -- Installer")
print("============================================")
term.setTextColor(colors.white)
print("")
print("Repository : " .. REPO_BASE)
print("")

-- ── Mode selection ────────────────────────────────────────────────────────────
local MODE   -- "update" | "force" | "clean"
local forceWrite = false

print("  [U]  Update         (delta-check; skip unchanged .lua)")
print("  [F]  Force Update   (reinstall ALL .lua; keep .json data)")
term.setTextColor(colors.red)
print("  [I]  Install        (WIPE everything + fresh install)")
term.setTextColor(colors.white)
print("  [Q]  Cancel")
print("")
io.write("Choice [U/F/I/Q]: ")
local ch = (io.read() or ""):gsub("%s", ""):lower()
if ch == "u" then
    MODE = "update"
elseif ch == "f" then
    MODE       = "force"
    forceWrite = true
elseif ch == "i" then
    MODE = "clean"
else
    print("Aborted."); return
end

-- ── Pre-install steps ─────────────────────────────────────────────────────────
if MODE == "clean" then
    print("")
    term.setTextColor(colors.red)
    print("  WARNING: Install will permanently delete:")
    for _, d in ipairs(CLEAN_DIRS) do print("    " .. d .. "/  (entire directory)") end
    for _, p in ipairs(DATA_PATHS) do print("    " .. p) end
    print("")
    io.write("  Type YES to confirm wipe + reinstall: ")
    term.setTextColor(colors.white)
    if io.read() ~= "YES" then print("Aborted."); return end

    print("\nWiping...")
    for _, d in ipairs(CLEAN_DIRS) do
        if fs.exists(d) then
            fs.delete(d)
            term.setTextColor(colors.red); print("  deleted " .. d)
            term.setTextColor(colors.white)
        end
    end
    for _, p in ipairs(CLEAN_FILES) do
        if fs.exists(p) then
            fs.delete(p)
            term.setTextColor(colors.red); print("  deleted " .. p)
            term.setTextColor(colors.white)
        end
    end
    forceWrite = true

    checkHardware()
end

-- Ensure directories exist for all modes (no-op if already present).
for _, d in ipairs({"/shared", "/ami", "/ami/exchange", "/ami/exchange/data"}) do
    if not fs.exists(d) then
        fs.makeDir(d)
        term.setTextColor(colors.lightGray); print("  mkdir " .. d)
        term.setTextColor(colors.white)
    end
end

-- ── Download and install .lua files ──────────────────────────────────────────
local modeLabel = ({
    update = "Checking for updates...",
    force  = "Force-reinstalling modules...",
    clean  = "Downloading modules (clean install)...",
})[MODE]
print("\n" .. modeLabel)

local failed    = false
local counts    = { skip = 0, fresh = 0, updated = 0, fail = 0 }
local allHashes = {}

for _, entry in ipairs(FILES) do
    if not entry.dst:match("%.lua$") then
        term.setTextColor(colors.yellow)
        print("  SKIP (non-.lua): " .. entry.dst)
        term.setTextColor(colors.white)
    else
        io.write("  " .. entry.dst .. " ... ")
        local url = REPO_BASE .. entry.src
        local content, remoteHash, fetchErr = fetchRemote(url)
        if not content then
            term.setTextColor(colors.red)
            print("FAILED")
            print("    " .. (fetchErr or "unknown"))
            term.setTextColor(colors.white)
            counts.fail = counts.fail + 1
            failed = true
        else
            local action, instErr = smartInstall(entry.dst, content, remoteHash, forceWrite)
            if not action then
                term.setTextColor(colors.red)
                print("FAILED")
                print("    " .. (instErr or "unknown"))
                term.setTextColor(colors.white)
                counts.fail = counts.fail + 1
                failed = true
            elseif action == "skip" then
                term.setTextColor(colors.gray)
                print("skip  [" .. remoteHash .. "]")
                term.setTextColor(colors.white)
                counts.skip = counts.skip + 1
                allHashes[#allHashes + 1] = remoteHash
            elseif action == "updated" then
                term.setTextColor(colors.cyan)
                print("updated  [" .. remoteHash .. "]")
                term.setTextColor(colors.white)
                counts.updated = counts.updated + 1
                allHashes[#allHashes + 1] = remoteHash
            else
                term.setTextColor(colors.green)
                print("OK  [" .. remoteHash .. "]")
                term.setTextColor(colors.white)
                counts.fresh = counts.fresh + 1
                allHashes[#allHashes + 1] = remoteHash
            end
        end
    end
end

-- ── JSON data files (templates only; never overwrite existing) ────────────────
print("")
for _, entry in ipairs({
    { path = "/ami/exchange/config.json", tbl = TEMPLATE_CONFIG,
      note = "(template -- add a node via the Admin panel)" },
}) do
    if not fs.exists(entry.path) then
        writeJSON(entry.path, entry.tbl)
        term.setTextColor(colors.lightGray)
        print("  Created   " .. entry.path .. "  " .. entry.note)
        term.setTextColor(colors.white)
    else
        term.setTextColor(colors.gray)
        print("  Preserved " .. entry.path)
        term.setTextColor(colors.white)
    end
end

-- ── Auto-start (clean / install only) ──────────────────────────────────────────
if not failed and MODE == "clean" then
    print("")
    io.write("Set the exchange as auto-start on reboot? [y/n]: ")
    if (io.read() or ""):lower():sub(1, 1) == "y" then
        if fs.exists("/startup.lua") then
            fs.copy("/startup.lua", "/startup.lua.bak")
            print("  Backed up /startup.lua -> /startup.lua.bak")
        end
        local f = fs.open("/startup.lua", "w")
        f.write("-- Auto-generated by installexchange.lua\n")
        f.write('shell.run("/ami/exchange/startup")\n')
        f.close()
        print("  /startup.lua written.")
    end
end

-- ── Summary ───────────────────────────────────────────────────────────────────
print("")
if failed then
    term.setTextColor(colors.red)
    print("Some files failed. Check connectivity and REPO_BASE, then re-run.")
    if MODE == "update" or MODE == "force" then
        term.setTextColor(colors.yellow)
        print("Backup files (.lua.bak) were preserved for any failed file.")
    end
else
    term.setTextColor(colors.green)
    if MODE == "update" or MODE == "force" then
        print(string.format(
            "Update complete!  %d updated  %d skipped  %d new",
            counts.updated, counts.skip, counts.fresh))
    else
        print("Installation complete!")
    end
    print("")
    if #allHashes > 0 then
        local masterHash = fnv1a(table.concat(allHashes, ":"))
        term.setTextColor(colors.yellow)
        print("Install fingerprint : " .. masterHash)
        print("Verify at           : github.com/Teru-dot-png/amicoin-fullpower")
    end
    if MODE == "clean" then
        print("")
        term.setTextColor(colors.orange)
        print("Next steps:")
        print("  1. Run:  /ami/exchange/startup  (or reboot)")
        print("  2. Set the admin password, then press ` (backtick).")
        print("  3. [N] add your node, then [T] run the safety test.")
        print("  4. Send AMI to the exchange so it can pay for sold coins.")
        print("  See docs/EXCHANGE.md -- protect the build before opening it.")
    end
end

-- ── Post-update: apply changes ────────────────────────────────────────────────
if not failed and (MODE == "update" or MODE == "force") then
    print("")
    term.setTextColor(colors.orange)
    print("Apply changes:")
    term.setTextColor(colors.white)
    print("  [S]  Soft restart (re-run /ami/exchange/startup)")
    print("  [H]  Hard reboot")
    print("  [N]  Do nothing (apply later)")
    io.write("Choice: ")
    local ch = (io.read() or ""):lower():sub(1, 1)
    if ch == "s" then
        term.setTextColor(colors.yellow)
        print("Launching /ami/exchange/startup...")
        term.setTextColor(colors.white)
        shell.run("/ami/exchange/startup")
    elseif ch == "h" then
        os.reboot()
    end
end

term.setTextColor(colors.white)
