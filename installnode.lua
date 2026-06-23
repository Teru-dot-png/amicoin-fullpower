-- installnode.lua  v3.1
-- AmiCoin Node Installer for CC:Tweaked Advanced Computer + Ender Router.
-- Supports Hard Update, Force Update, Clean Install, and Fresh Install.
--
-- Modes (chosen at runtime):
--   Hard Update    : Delta-checks hashes -- skips unchanged .lua files.
--                    /data/ (ledger, keys, miner state) preserved.
--   Force Update   : Reinstalls ALL .lua files regardless of local hash.
--                    /data/ preserved.
--   Clean Install  : Wipes /data/ and all .lua files then fresh install.
--   Fresh Install  : (auto, when node absent) standard first-time setup.

local VERSION   = "3.5"
local REPO_BASE = "https://raw.githubusercontent.com/Teru-dot-png/amicoin-fullpower/refs/heads/main"

local FILES = {
    -- === Node Service Files ===
    { src = "/shared/xtea.lua",       dst = "/shared/xtea.lua"   },
    { src = "/node/startup.lua",      dst = "/startup.lua"       },
    { src = "/node/node_ui.lua",      dst = "/node_ui.lua"       },
    { src = "/node/ledger.lua",       dst = "/ledger.lua"        },
    { src = "/node/miner_daemon.lua", dst = "/miner_daemon.lua"  },
    { src = "/node/xtea.lua",         dst = "/xtea.lua"          },
    { src = "/node/upgrades.lua",     dst = "/upgrades.lua"      },
    
    -- === Opus UI Framework - Core (Minimal for Fan Widget) ===
    { src = "/ami/lib/ui/class.lua",    dst = "/ami/lib/ui/class.lua"    },
    { src = "/ami/lib/ui/ui.lua",       dst = "/ami/lib/ui/ui.lua"       },
    { src = "/ami/lib/ui/canvas.lua",   dst = "/ami/lib/ui/canvas.lua"   },
    { src = "/ami/lib/ui/event.lua",    dst = "/ami/lib/ui/event.lua"    },
    { src = "/ami/lib/ui/terminal.lua", dst = "/ami/lib/ui/terminal.lua" },
    { src = "/ami/lib/ui/region.lua",   dst = "/ami/lib/ui/region.lua"   },
    { src = "/ami/lib/ui/input.lua",      dst = "/ami/lib/ui/input.lua"      },
    { src = "/ami/lib/ui/util.lua",       dst = "/ami/lib/ui/util.lua"       },
    { src = "/ami/lib/ui/entry.lua",      dst = "/ami/lib/ui/entry.lua"      },
    { src = "/ami/lib/ui/transition.lua", dst = "/ami/lib/ui/transition.lua" },
    { src = "/ami/lib/ui/tween.lua",      dst = "/ami/lib/ui/tween.lua"      },
    
    -- === Opus UI Framework - Theme & Glyphs ===
    { src = "/ami/lib/ui/theme.lua",  dst = "/ami/lib/ui/theme.lua"  },
    { src = "/ami/lib/ui/glyphs.lua", dst = "/ami/lib/ui/glyphs.lua" },
    
    -- === Opus UI Framework - Widgets ===
    { src = "/ami/lib/ui/widgets/fan.lua",   dst = "/ami/lib/ui/widgets/fan.lua"   },
    { src = "/ami/lib/ui/widgets/gauge.lua", dst = "/ami/lib/ui/widgets/gauge.lua" },
}

-- Files/dirs wiped on Clean Install.
local CLEAN_LUAS = {
    "/startup.lua", "/ledger.lua", "/miner_daemon.lua", "/xtea.lua",
    "/shared/xtea.lua", "/upgrades.lua", "/node_ui.lua",
}
local CLEAN_DIRS = { "/data", "/ami/lib/ui" }

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

-- ── Banner ────────────────────────────────────────────────────────────────────
term.setTextColor(colors.red)
print("===========================================")
print("  AmiCoin Node Installer  v" .. VERSION)
print("===========================================")
term.setTextColor(colors.white)
print("")
print("Repository : " .. REPO_BASE)
print("")

-- ── Mode selection ────────────────────────────────────────────────────────────
local MODE   -- "update" | "force" | "clean"
local forceWrite = false

print("  [U]  Update         (delta-check; skip unchanged .lua)")
print("  [F]  Force Update   (reinstall ALL .lua; keep /data/)")
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
    for _, p in ipairs(CLEAN_LUAS) do print("    " .. p) end
    for _, d in ipairs(CLEAN_DIRS) do print("    " .. d .. "/  (ledger, keys, miner state)") end
    print("")
    print("  All wallet balances on this node will be ERASED.")
    io.write("  Type YES to confirm wipe + reinstall: ")
    term.setTextColor(colors.white)
    if io.read() ~= "YES" then print("Aborted."); return end

    print("\nWiping...")
    for _, p in ipairs(CLEAN_LUAS) do
        if fs.exists(p) then
            fs.delete(p)
            term.setTextColor(colors.red); print("  deleted " .. p)
            term.setTextColor(colors.white)
        end
    end
    for _, d in ipairs(CLEAN_DIRS) do
        if fs.exists(d) then
            fs.delete(d)
            term.setTextColor(colors.red); print("  deleted " .. d .. "/")
            term.setTextColor(colors.white)
        end
    end
    forceWrite = true
end

-- Ensure directories exist for all modes (no-op if already present).
for _, d in ipairs({"/shared", "/data"}) do
    if not fs.exists(d) then
        fs.makeDir(d)
        term.setTextColor(colors.lightGray); print("  mkdir " .. d)
        term.setTextColor(colors.white)
    end
end

-- ── Download and install .lua files ──────────────────────────────────────────
local modeLabel = ({
    update = "Checking for updates...",
    force  = "Force-reinstalling node software...",
    clean  = "Downloading node software (clean install)...",
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
        print("  1. Attach an Ender Router peripheral.")
        print("  2. Reboot (type: reboot)")
        print("  3. Note the XTEA Node Key printed on first boot.")
        print("  4. Enter that key into each Wallet Pad.")
    end
end

-- ── Post-update: apply changes ────────────────────────────────────────────────
if not failed and (MODE == "update" or MODE == "force") then
    print("")
    term.setTextColor(colors.orange)
    print("Apply changes:")
    term.setTextColor(colors.white)
    print("  [S]  Soft restart (re-run /startup.lua)")
    print("  [H]  Hard reboot")
    print("  [N]  Do nothing")
    io.write("Choice: ")
    local ch = (io.read() or ""):lower():sub(1, 1)
    if ch == "s" then
        term.setTextColor(colors.yellow)
        print("Launching /startup.lua...")
        term.setTextColor(colors.white)
        shell.run("/startup")
    elseif ch == "h" then
        os.reboot()
    end
elseif not failed and MODE == "clean" then
    print("")
    io.write("Reboot now to start the node? [y/n]: ")
    if (io.read() or ""):lower():sub(1, 1) == "y" then
        os.reboot()
    end
end

term.setTextColor(colors.white)
