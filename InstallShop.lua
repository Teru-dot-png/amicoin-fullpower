-- InstallShop.lua
-- AmiStore v1.1 — Merchant Node Installer
-- Run this on the computer that will become your Merchant Node.
-- Downloads all /ami/shop/ modules from GitHub, verifies FNV-1a fingerprints,
-- and creates starter config / listings templates.
--
-- Usage:
--   wget run <url>   (or paste this file and run it)

local REPO_BASE = "https://raw.githubusercontent.com/Teru-dot-png/amicoin-fullpower/refs/heads/main"

-- Files to download.
local FILES = {
    { src = "/shared/xtea.lua",        dst = "/shared/xtea.lua"        },
    { src = "/ami/shop/shop_api.lua",  dst = "/ami/shop/shop_api.lua"  },
    { src = "/ami/shop/shop_ui.lua",   dst = "/ami/shop/shop_ui.lua"   },
    { src = "/ami/shop/startup.lua",   dst = "/ami/shop/startup.lua"   },
}

-- Template listings written if listings.json is absent.
local TEMPLATE_LISTINGS = {
    listings = {
        { type = "WTS", item = "minecraft:diamond",         price = 50000  },
        { type = "WTS", item = "minecraft:emerald",         price = 25000  },
        { type = "WTB", item = "minecraft:iron_ingot",      price = 500    },
        { type = "WTB", item = "minecraft:gold_ingot",      price = 2000   },
    }
}

-- Template config written if config.json is absent.
-- Edit vault_addr and vault_node_key to enable profit sweeps.
local TEMPLATE_CONFIG = {
    nodes          = {},     -- add witness nodes: {{name="X", key="abc..."}, ...}
    sweep_pct      = 5,      -- percent of each sale swept to AmiVault
    vault_addr     = "",     -- 128-hex AmiVault owner address
    vault_node_key = "",     -- 32-hex key of the node hosting the vault
}

-- ── Helpers ───────────────────────────────────────────────────────────────────
local function fnv1a(s)
    local hash = 2166136261
    for i = 1, #s do
        hash = bit32.bxor(hash, string.byte(s, i))
        hash = (hash * 16777619) % 4294967296
    end
    return string.format("%08x", hash)
end

local function download(url, path)
    -- Ensure parent directory exists.
    local dir = path:match("^(.*)/[^/]+$")
    if dir and dir ~= "" and not fs.exists(dir) then fs.makeDir(dir) end

    local res = http.get(url)
    if not res then
        return false, nil, "HTTP request failed: " .. url
    end
    local content = res.readAll(); res.close()
    if #content < 64 then
        return false, nil, string.format(
            "Response only %d bytes — likely a 404 page", #content)
    end
    if fs.exists(path) then fs.delete(path) end
    local f = fs.open(path, "w"); f.write(content); f.close()
    return true, fnv1a(content), nil
end

local function writeJSON(path, tbl)
    local f = fs.open(path, "w")
    f.write(textutils.serialiseJSON(tbl))
    f.close()
end

-- ── Hardware checklist ────────────────────────────────────────────────────────
local SIDE_CHECKS = {
    { side = "top",    expect = "monitor",   role = "3x3 Advanced Monitor (UI)"     },
    { side = "left",   expect = "printer",   role = "Printer (Receipts)"            },
    { side = "right",  expect = "meBridge",  role = "ME Bridge / AE2 Storage"       },
    { side = "bottom", expect = "inventory", role = "Chest / Barrel (Vending Tray)" },
    { side = "back",   expect = "modem",     role = "Modem (Mesh Comms)"            },
}

local function checkHardware()
    local allOK = true
    print("\nHardware verification:")
    for _, c in ipairs(SIDE_CHECKS) do
        local present = peripheral.isPresent(c.side)
        local ptype   = present and peripheral.getType(c.side) or "absent"
        -- Accept any peripheral whose type contains the expected substring,
        -- except modem which can be "modem" or "ender_modem".
        local pass
        if not present then
            pass = false
        elseif c.expect == "modem" then
            pass = ptype == "modem" or ptype == "ender_modem"
                   or ptype:find("modem") ~= nil
        elseif c.expect == "inventory" then
            pass = ptype:find("inventory") ~= nil or ptype:find("chest") ~= nil
                   or ptype:find("barrel") ~= nil
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
    if not allOK then
        print("")
        print("  Some peripherals are missing or on the wrong side.")
        print("  Installation will continue but those features will be")
        print("  disabled until the hardware is attached.")
    end
    return allOK
end

-- ── Banner ────────────────────────────────────────────────────────────────────
term.setTextColor(colors.orange)
print("============================================")
print("  AmiStore v1.1 — Merchant Node Installer")
print("============================================")
term.setTextColor(colors.white)
print("")
print("Repository : " .. REPO_BASE)
print("")

checkHardware()

print("")
term.setTextColor(colors.red)
io.write("Type YES to install (this overwrites existing shop files): ")
term.setTextColor(colors.white)
local confirm = io.read()
if confirm ~= "YES" then print("Aborted."); return end

-- ── Directory scaffold ────────────────────────────────────────────────────────
print("\nCreating directories...")
for _, d in ipairs({"/shared", "/ami", "/ami/shop", "/ami/shop/data"}) do
    if not fs.exists(d) then
        fs.makeDir(d)
        term.setTextColor(colors.lightGray); print("  mkdir " .. d)
        term.setTextColor(colors.white)
    end
end

-- ── Download core modules ─────────────────────────────────────────────────────
print("\nDownloading modules...")
local failed      = false
local fileHashes  = {}

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
        print("    " .. (err or "unknown error"))
        failed = true
    end
    term.setTextColor(colors.white)
end

-- ── Write starter data files (only if absent) ─────────────────────────────────
if not fs.exists("/ami/shop/listings.json") then
    writeJSON("/ami/shop/listings.json", TEMPLATE_LISTINGS)
    term.setTextColor(colors.lightGray)
    print("  /ami/shop/listings.json  (template)")
    term.setTextColor(colors.white)
end

if not fs.exists("/ami/shop/config.json") then
    writeJSON("/ami/shop/config.json", TEMPLATE_CONFIG)
    term.setTextColor(colors.lightGray)
    print("  /ami/shop/config.json    (template)")
    term.setTextColor(colors.white)
end

-- ── Optional: set as auto-start ───────────────────────────────────────────────
if not failed then
    print("")
    io.write("Set AmiStore as auto-start on reboot? (y/n): ")
    local ans = (io.read() or ""):lower():sub(1, 1)
    if ans == "y" then
        if fs.exists("/startup.lua") then
            fs.copy("/startup.lua", "/startup.lua.bak")
            print("  Backed up existing /startup.lua → /startup.lua.bak")
        end
        local f = fs.open("/startup.lua", "w")
        f.write('-- Auto-generated by InstallShop.lua\n')
        f.write('shell.run("/ami/shop/startup")\n')
        f.close()
        print("  /startup.lua written.")
    end
end

-- ── Final summary ─────────────────────────────────────────────────────────────
print("")
if failed then
    term.setTextColor(colors.red)
    print("Some files failed to download.")
    print("Check your internet connection and REPO_BASE URL, then re-run.")
else
    local combined   = table.concat(fileHashes, ":")
    local masterHash = fnv1a(combined)
    term.setTextColor(colors.green)
    print("Installation complete!")
    print("")
    term.setTextColor(colors.yellow)
    print("Install fingerprint : " .. masterHash)
    print("Verify at           : github.com/Teru-dot-png/amicoin-fullpower")
    print("")
    term.setTextColor(colors.orange)
    print("Next steps:")
    print("  1. Register this shop on your node network via [N] > Node Manager.")
    print("     Merchant Key: " ..
          (fs.exists("/ami/shop/data/shop_addr.txt") and (function()
              local f = fs.open("/ami/shop/data/shop_addr.txt", "r")
              local a = f.readAll(); f.close(); return a:sub(1, 16) .. "..."
          end)() or "(generated on first run)"))
    print("  2. Edit /ami/shop/config.json — add witness nodes and vault address.")
    print("  3. Edit /ami/shop/listings.json — configure your WTS / WTB prices.")
    print("  4. Run:  /ami/shop/startup")
    print("     (or reboot if auto-start was enabled)")
end
term.setTextColor(colors.white)
