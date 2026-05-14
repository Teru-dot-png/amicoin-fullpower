-- installpad.lua
-- AmiCoin Wallet installer for CC:Tweaked Ender Router Pad.
-- Run this script on the Pad to download the wallet app.
-- Usage:
--   wget run https://raw.githubusercontent.com/Teru-dot-png/amicoin/main/installpad.lua

local REPO_BASE = "https://raw.githubusercontent.com/Teru-dot-png/amicoin-fullpower/refs/heads/main"

local FILES = {
    -- Shared library
    { src = "/shared/xtea.lua",           dst = "/shared/xtea.lua"           },
    -- Wallet app
    { src = "/wallet/main.lua",           dst = "/startup.lua"               },
    { src = "/wallet/secret_manager.lua", dst = "/secret_manager.lua"        },
    { src = "/wallet/session.lua",        dst = "/session.lua"               },
    { src = "/wallet/comms.lua",          dst = "/comms.lua"                 },
}

local function printBanner()
    term.setTextColor(colors.red)
    print("===========================================")
    print("  AmiCoin Wallet Installer")
    print("===========================================")
    term.setTextColor(colors.white)
end

-- ── Source verification (FNV-1a 32-bit) ─────────────────────────────────────
local function fnv1a(s)
    local hash = 2166136261
    for i = 1, #s do
        hash = bit32.bxor(hash, string.byte(s, i))
        hash = (hash * 16777619) % 4294967296
    end
    return string.format("%08x", hash)
end

local function download(url, path)
    local dir = path:match("^(.*)/[^/]+$")
    if dir and dir ~= "" and not fs.exists(dir) then
        fs.makeDir(dir)
    end

    local res = http.get(url)
    if not res then
        return false, nil, "HTTP request failed for: " .. url
    end
    local content = res.readAll()
    res.close()

    if #content < 64 then
        return false, nil, "Response too small (" .. #content .. " bytes) - likely a 404"
    end

    if fs.exists(path) then fs.delete(path) end
    local f = fs.open(path, "w")
    f.write(content)
    f.close()
    return true, fnv1a(content), nil
end

printBanner()
print("")
print("This will install the AmiCoin Wallet app on")
print("this Ender Router Pad.")
print("")
term.setTextColor(colors.yellow)
print("Your wallet data (/wallet_data/) will NOT")
print("be deleted if it already exists.")
term.setTextColor(colors.white)
print("")
io.write("Press Enter to continue or Ctrl+T to abort… ")
io.read()

print("")
print("Downloading files from GitHub…")

local failed = false
local fileHashes = {}
for _, entry in ipairs(FILES) do
    local url = REPO_BASE .. entry.src
    io.write("  " .. entry.dst .. " ... ")
    local ok, hash, err = download(url, entry.dst)
    if ok then
        term.setTextColor(colors.green)
        print("OK  [" .. hash .. "]")
        fileHashes[#fileHashes + 1] = hash
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
    print("Some files failed. Check connectivity and REPO_BASE.")
else
    term.setTextColor(colors.green)
    print("Wallet installed!")
    print("")
    local combined = table.concat(fileHashes, ":")
    local fingerprint = fnv1a(combined)
    term.setTextColor(colors.yellow)
    print("Install fingerprint: " .. fingerprint)
    print("Compare against: github.com/Teru-dot-png/amicoin-fullpower")
    print("")
    term.setTextColor(colors.orange)
    print("Next steps:")
    print("  1. Reboot this Pad (type: reboot)")
    print("  2. The wallet will launch automatically.")
    print("  3. Create or import your Secret Key.")
    print("  4. Enter the Node XTEA Key when prompted.")
end
term.setTextColor(colors.white)
