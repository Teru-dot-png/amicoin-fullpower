-- installpad.lua  v3.0
-- AmiCoin Wallet Installer for CC:Tweaked Ender Router Pad.
-- Supports Fresh Install and non-destructive Hard Update mode.
--
-- Modes:
--   Fresh Install  : Downloads all modules and boots the wallet.
--   Hard Update    : Overwrites .lua files only; wallet data preserved.
--                    Delta-checks hashes -- skips unchanged files.
--                    Backs up each .lua to .lua.bak before overwriting.
--                    Restores .bak automatically if download or write fails.

local VERSION   = "3.0"
local REPO_BASE = "https://raw.githubusercontent.com/Teru-dot-png/amicoin-fullpower/refs/heads/main"

local FILES = {
    { src = "/shared/xtea.lua",           dst = "/shared/xtea.lua"    },
    { src = "/wallet/main.lua",           dst = "/startup.lua"        },
    { src = "/wallet/secret_manager.lua", dst = "/secret_manager.lua" },
    { src = "/wallet/session.lua",        dst = "/session.lua"        },
    { src = "/wallet/comms.lua",          dst = "/comms.lua"          },
}

-- \u2500\u2500 Smart Update Engine \u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500

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

local function smartInstall(dst, content, remoteHash)
    if not dst:match("%.lua$") then
        return nil, "Refusing to overwrite non-.lua file: " .. dst
    end
    local dir = dst:match("^(.*)/[^/]+$")
    if dir and dir ~= "" and not fs.exists(dir) then fs.makeDir(dir) end

    local existed = fs.exists(dst)
    local bakPath = dst .. ".bak"

    if existed then
        if hashFile(dst) == remoteHash then
            return "skip", nil
        end
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

-- \u2500\u2500 Mode detection \u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500
-- The wallet is "installed" when startup.lua (main.lua) and comms.lua both exist.
local isUpdate = fs.exists("/startup.lua") and fs.exists("/comms.lua")

-- \u2500\u2500 Banner \u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500
term.setTextColor(colors.red)
print("===========================================")
print("  AmiCoin Wallet Installer  v" .. VERSION)
print("===========================================")
term.setTextColor(colors.white)
print("")
print("Repository : " .. REPO_BASE)
print("")

if isUpdate then
    term.setTextColor(colors.yellow)
    print("  [UPDATE MODE] Wallet already installed.")
    print("  .lua files will be delta-checked and updated.")
    print("  Your keys and wallet data will NOT be touched.")
    term.setTextColor(colors.white)
    print("")
    io.write("Proceed with update? [y/n]: ")
    if (io.read() or ""):lower():sub(1, 1) ~= "y" then
        print("Aborted."); return
    end
else
    term.setTextColor(colors.lime)
    print("  [FRESH INSTALL] No wallet found on this Pad.")
    term.setTextColor(colors.white)
    print("")
    io.write("Press Enter to install or Ctrl+T to abort... ")
    io.read()
end

-- \u2500\u2500 Download and install .lua files \u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500
print("\n" .. (isUpdate and "Checking for updates..." or "Downloading wallet..."))

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
            local action, instErr = smartInstall(entry.dst, content, remoteHash)
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

-- \u2500\u2500 Summary \u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500
print("")
if failed then
    term.setTextColor(colors.red)
    print("Some files failed. Check connectivity and REPO_BASE, then re-run.")
    if isUpdate then
        term.setTextColor(colors.yellow)
        print("Backup files (.lua.bak) were preserved for any failed file.")
    end
else
    term.setTextColor(colors.green)
    if isUpdate then
        print(string.format(
            "Update complete!  %d updated  %d skipped  %d new",
            counts.updated, counts.skip, counts.fresh))
    else
        print("Wallet installed!")
    end
    print("")
    if #allHashes > 0 then
        local masterHash = fnv1a(table.concat(allHashes, ":"))
        term.setTextColor(colors.yellow)
        print("Install fingerprint : " .. masterHash)
        print("Verify at           : github.com/Teru-dot-png/amicoin-fullpower")
    end
end

-- \u2500\u2500 Post-install/update: apply changes \u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500
if not failed then
    print("")
    if isUpdate then
        term.setTextColor(colors.orange)
        print("Apply changes:")
        term.setTextColor(colors.white)
        print("  [S]  Soft restart (re-run wallet)")
        print("  [H]  Hard reboot")
        print("  [N]  Do nothing")
        io.write("Choice: ")
        local ch = (io.read() or ""):lower():sub(1, 1)
        if ch == "s" then
            term.setTextColor(colors.yellow)
            print("Launching wallet...")
            term.setTextColor(colors.white)
            shell.run("/startup")
        elseif ch == "h" then
            os.reboot()
        end
    else
        term.setTextColor(colors.orange)
        print("Next steps:")
        term.setTextColor(colors.white)
        print("  1. Reboot this Pad (type: reboot)")
        print("  2. The wallet will launch automatically.")
        print("  3. Create or import your Secret Key.")
        print("  4. Enter the Node XTEA Key when prompted.")
        print("")
        io.write("Reboot now? [y/n]: ")
        if (io.read() or ""):lower():sub(1, 1) == "y" then
            os.reboot()
        end
    end
end

term.setTextColor(colors.white)
