-- installnode.lua
-- AmiCoin Node installer for CC:Tweaked Advanced Computer + Ender Router.
-- Run this script on the node computer to download all required files.
-- Usage: paste this file into the computer then run it, or fetch it with:
--   pastebin run <code>   (if hosted on Pastebin)
--   wget run https://raw.githubusercontent.com/Teru-dot-png/amicoin/main/installnode.lua

local REPO_BASE = "https://raw.githubusercontent.com/Teru-dot-png/amicoin/main"

local FILES = {
    -- Shared library
    { src = "/shared/xtea.lua",         dst = "/shared/xtea.lua"         },
    -- Node software
    { src = "/node/startup.lua",        dst = "/startup.lua"             },
    { src = "/node/ledger.lua",         dst = "/ledger.lua"              },
    { src = "/node/miner_daemon.lua",   dst = "/miner_daemon.lua"        },
    { src = "/node/xtea.lua",           dst = "/xtea.lua"                },
}

local function printBanner()
    term.setTextColor(colors.yellow)
    print("===========================================")
    print("  AmiCoin Node Installer")
    print("===========================================")
    term.setTextColor(colors.white)
end

local function download(url, path)
    local dir = path:match("^(.*)/[^/]+$")
    if dir and dir ~= "" and not fs.exists(dir) then
        fs.makeDir(dir)
    end

    local res = http.get(url)
    if not res then
        return false, "HTTP request failed for: " .. url
    end
    local content = res.readAll()
    res.close()

    if fs.exists(path) then fs.delete(path) end
    local f = fs.open(path, "w")
    f.write(content)
    f.close()
    return true
end

printBanner()
print("")
print("This will WIPE and reinstall all AmiCoin node")
print("files on this computer.")
print("")
term.setTextColor(colors.red)
io.write("Type YES to continue: ")
term.setTextColor(colors.white)
local confirm = io.read()
if confirm ~= "YES" then
    print("Aborted.")
    return
end

print("")
print("Cleaning old files…")
local toWipe = { "/shared", "/data" }
for _, path in ipairs(toWipe) do
    -- Only remove amicoin-specific directories, not startup.lua yet
    if fs.exists(path) then
        fs.delete(path)
        print("  Removed " .. path)
    end
end

print("")
print("Downloading files from GitHub…")

local failed = false
for _, entry in ipairs(FILES) do
    local url = REPO_BASE .. entry.src
    io.write("  " .. entry.dst .. " … ")
    local ok, err = download(url, entry.dst)
    if ok then
        term.setTextColor(colors.green)
        print("OK")
    else
        term.setTextColor(colors.red)
        print("FAILED")
        print("    " .. (err or ""))
        failed = true
    end
    term.setTextColor(colors.white)
end

print("")
if failed then
    term.setTextColor(colors.red)
    print("Some files failed to download.")
    print("Check your internet connection and the REPO_BASE URL at the top of this script.")
else
    term.setTextColor(colors.green)
    print("Installation complete!")
    print("")
    term.setTextColor(colors.cyan)
    print("Next steps:")
    print("  1. Attach an Ender Router peripheral.")
    print("  2. Reboot this computer (type: reboot)")
    print("  3. Note the XTEA Node Key printed on first boot.")
    print("  4. Enter that key into each Wallet Pad.")
end
term.setTextColor(colors.white)
