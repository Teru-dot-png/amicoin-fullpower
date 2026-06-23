-- installshop.lua  v3.1
-- AmiStore -- Merchant Node Installer
-- Supports Hard Update, Force Update, Clean Install, and Fresh Install.
--
-- Modes (chosen at runtime):
--   Hard Update    : Delta-checks hashes -- skips unchanged .lua files.
--                    .json data files are never touched.
--   Force Update   : Reinstalls ALL .lua files regardless of local hash.
--                    .json data files are never touched.
--   Clean Install  : Wipes /ami/shop/ and /shared/xtea.lua then does a
--                    full fresh install including JSON templates.
--   Fresh Install  : (auto, when /ami/shop/ is absent) same as above but
--                    without wiping.

local VERSION   = "3.1"
local REPO_BASE = "https://raw.githubusercontent.com/Teru-dot-png/amicoin-fullpower/refs/heads/main"

local FILES = {
    -- === Shop Service Files ===
    { src = "/shared/xtea.lua",       dst = "/shared/xtea.lua"       },
    { src = "/ami/shop/shop_api.lua", dst = "/ami/shop/shop_api.lua" },
    { src = "/ami/shop/shop_ui.lua",  dst = "/ami/shop/shop_ui.lua"  },
    { src = "/ami/shop/startup.lua",  dst = "/ami/shop/startup.lua"  },
    
    -- === Opus UI Framework - Core ===
    { src = "/ami/lib/ui/class.lua",      dst = "/ami/lib/ui/class.lua"      },
    { src = "/ami/lib/ui/ui.lua",         dst = "/ami/lib/ui/ui.lua"         },
    { src = "/ami/lib/ui/canvas.lua",     dst = "/ami/lib/ui/canvas.lua"     },
    { src = "/ami/lib/ui/event.lua",      dst = "/ami/lib/ui/event.lua"      },
    { src = "/ami/lib/ui/input.lua",      dst = "/ami/lib/ui/input.lua"      },
    { src = "/ami/lib/ui/region.lua",     dst = "/ami/lib/ui/region.lua"     },
    { src = "/ami/lib/ui/terminal.lua",   dst = "/ami/lib/ui/terminal.lua"   },
    { src = "/ami/lib/ui/transition.lua", dst = "/ami/lib/ui/transition.lua" },
    { src = "/ami/lib/ui/tween.lua",      dst = "/ami/lib/ui/tween.lua"      },
    { src = "/ami/lib/ui/util.lua",       dst = "/ami/lib/ui/util.lua"       },
    { src = "/ami/lib/ui/sound.lua",      dst = "/ami/lib/ui/sound.lua"      },
    { src = "/ami/lib/ui/entry.lua",      dst = "/ami/lib/ui/entry.lua"      },
    { src = "/ami/lib/ui/init.lua",       dst = "/ami/lib/ui/init.lua"       },
    
    -- === Opus UI Framework - Theme & Glyphs ===
    { src = "/ami/lib/ui/theme.lua",  dst = "/ami/lib/ui/theme.lua"  },
    { src = "/ami/lib/ui/glyphs.lua", dst = "/ami/lib/ui/glyphs.lua" },
    
    -- === Opus UI Framework - Components ===
    { src = "/ami/lib/ui/components/ActiveLayer.lua",    dst = "/ami/lib/ui/components/ActiveLayer.lua"    },
    { src = "/ami/lib/ui/components/Button.lua",         dst = "/ami/lib/ui/components/Button.lua"         },
    { src = "/ami/lib/ui/components/Checkbox.lua",       dst = "/ami/lib/ui/components/Checkbox.lua"       },
    { src = "/ami/lib/ui/components/Chooser.lua",        dst = "/ami/lib/ui/components/Chooser.lua"        },
    { src = "/ami/lib/ui/components/Dialog.lua",         dst = "/ami/lib/ui/components/Dialog.lua"         },
    { src = "/ami/lib/ui/components/DropMenu.lua",       dst = "/ami/lib/ui/components/DropMenu.lua"       },
    { src = "/ami/lib/ui/components/DropMenuItem.lua",   dst = "/ami/lib/ui/components/DropMenuItem.lua"   },
    { src = "/ami/lib/ui/components/Embedded.lua",       dst = "/ami/lib/ui/components/Embedded.lua"       },
    { src = "/ami/lib/ui/components/Form.lua",           dst = "/ami/lib/ui/components/Form.lua"           },
    { src = "/ami/lib/ui/components/Grid.lua",           dst = "/ami/lib/ui/components/Grid.lua"           },
    { src = "/ami/lib/ui/components/Image.lua",          dst = "/ami/lib/ui/components/Image.lua"          },
    { src = "/ami/lib/ui/components/Menu.lua",           dst = "/ami/lib/ui/components/Menu.lua"           },
    { src = "/ami/lib/ui/components/MenuBar.lua",        dst = "/ami/lib/ui/components/MenuBar.lua"        },
    { src = "/ami/lib/ui/components/MenuItem.lua",       dst = "/ami/lib/ui/components/MenuItem.lua"       },
    { src = "/ami/lib/ui/components/NftImage.lua",       dst = "/ami/lib/ui/components/NftImage.lua"       },
    { src = "/ami/lib/ui/components/Notification.lua",   dst = "/ami/lib/ui/components/Notification.lua"   },
    { src = "/ami/lib/ui/components/ProgressBar.lua",    dst = "/ami/lib/ui/components/ProgressBar.lua"    },
    { src = "/ami/lib/ui/components/ScrollBar.lua",      dst = "/ami/lib/ui/components/ScrollBar.lua"      },
    { src = "/ami/lib/ui/components/ScrollingGrid.lua",  dst = "/ami/lib/ui/components/ScrollingGrid.lua"  },
    { src = "/ami/lib/ui/components/SlideOut.lua",       dst = "/ami/lib/ui/components/SlideOut.lua"       },
    { src = "/ami/lib/ui/components/Slider.lua",         dst = "/ami/lib/ui/components/Slider.lua"         },
    { src = "/ami/lib/ui/components/StatusBar.lua",      dst = "/ami/lib/ui/components/StatusBar.lua"      },
    { src = "/ami/lib/ui/components/Tab.lua",            dst = "/ami/lib/ui/components/Tab.lua"            },
    { src = "/ami/lib/ui/components/TabBar.lua",         dst = "/ami/lib/ui/components/TabBar.lua"         },
    { src = "/ami/lib/ui/components/TabBarMenuItem.lua", dst = "/ami/lib/ui/components/TabBarMenuItem.lua" },
    { src = "/ami/lib/ui/components/Tabs.lua",           dst = "/ami/lib/ui/components/Tabs.lua"           },
    { src = "/ami/lib/ui/components/Text.lua",           dst = "/ami/lib/ui/components/Text.lua"           },
    { src = "/ami/lib/ui/components/TextArea.lua",       dst = "/ami/lib/ui/components/TextArea.lua"       },
    { src = "/ami/lib/ui/components/TextEntry.lua",      dst = "/ami/lib/ui/components/TextEntry.lua"      },
    { src = "/ami/lib/ui/components/Throttle.lua",       dst = "/ami/lib/ui/components/Throttle.lua"       },
    { src = "/ami/lib/ui/components/TitleBar.lua",       dst = "/ami/lib/ui/components/TitleBar.lua"       },
    { src = "/ami/lib/ui/components/VerticalMeter.lua",  dst = "/ami/lib/ui/components/VerticalMeter.lua"  },
    { src = "/ami/lib/ui/components/Viewport.lua",       dst = "/ami/lib/ui/components/Viewport.lua"       },
    { src = "/ami/lib/ui/components/Wizard.lua",         dst = "/ami/lib/ui/components/Wizard.lua"         },
    { src = "/ami/lib/ui/components/WizardPage.lua",     dst = "/ami/lib/ui/components/WizardPage.lua"     },
    
    -- === Opus UI Framework - Widgets ===
    { src = "/ami/lib/ui/widgets/fan.lua",   dst = "/ami/lib/ui/widgets/fan.lua"   },
    { src = "/ami/lib/ui/widgets/gauge.lua", dst = "/ami/lib/ui/widgets/gauge.lua" },
    { src = "/ami/lib/ui/widgets/card.lua",  dst = "/ami/lib/ui/widgets/card.lua"  },
}

local TEMPLATE_LISTINGS = { listings = {} }
local TEMPLATE_CONFIG   = {
    nodes          = {},
    sweep_pct      = 5,
    vault_addr     = "",
    vault_node_key = "",
}

-- JSON data paths that belong to this service.
local DATA_PATHS = {
    "/ami/shop/listings.json",
    "/ami/shop/config.json",
}

-- Paths wiped on Clean Install (lua + data dirs, NOT /shared/xtea.lua which
-- is shared across services and will be overwritten by the download loop).
local CLEAN_DIRS  = { "/ami/shop", "/ami/lib/ui" }
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
    { side = "top",    expect = "monitor",   role = "3x3 Advanced Monitor (UI)"     },
    { side = "left",   expect = "printer",   role = "Printer (Receipts)"            },
    { side = "right",  expect = "me_bridge", role = "ME Bridge / AE2 Storage"       },
    { side = "bottom", expect = "inventory", role = "Chest / Barrel (Vending Tray)" },
    { side = "back",   expect = "modem",     role = "Modem (Mesh Comms)"            },
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
    if not allOK then
        print("\n  Some peripherals missing. Install will continue.")
    end
    return allOK
end

-- ── Banner ────────────────────────────────────────────────────────────────────
term.setTextColor(colors.orange)
print("============================================")
print("  AmiStore v" .. VERSION .. " -- Merchant Node Installer")
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
for _, d in ipairs({"/shared", "/ami", "/ami/shop", "/ami/shop/data"}) do
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
    { path = "/ami/shop/listings.json", tbl = TEMPLATE_LISTINGS,
      note = "(empty -- add listings via Admin panel)" },
    { path = "/ami/shop/config.json",   tbl = TEMPLATE_CONFIG,
      note = "(template -- add nodes, vault, sweep)" },
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
    io.write("Set AmiStore as auto-start on reboot? [y/n]: ")
    if (io.read() or ""):lower():sub(1, 1) == "y" then
        if fs.exists("/startup.lua") then
            fs.copy("/startup.lua", "/startup.lua.bak")
            print("  Backed up /startup.lua -> /startup.lua.bak")
        end
        local f = fs.open("/startup.lua", "w")
        f.write("-- Auto-generated by installshop.lua\n")
        f.write('shell.run("/ami/shop/startup")\n')
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
        print("  1. Register on your node via [N] > Node Manager.")
        print("  2. Edit /ami/shop/config.json -- add witness nodes and vault.")
        print("  3. Run:  /ami/shop/startup")
        print("     (or reboot if auto-start was enabled)")
    end
end

-- ── Post-update: apply changes ────────────────────────────────────────────────
if not failed and (MODE == "update" or MODE == "force") then
    print("")
    term.setTextColor(colors.orange)
    print("Apply changes:")
    term.setTextColor(colors.white)
    print("  [S]  Soft restart (re-run /ami/shop/startup)")
    print("  [H]  Hard reboot")
    print("  [N]  Do nothing (apply later)")
    io.write("Choice: ")
    local ch = (io.read() or ""):lower():sub(1, 1)
    if ch == "s" then
        term.setTextColor(colors.yellow)
        print("Launching /ami/shop/startup...")
        term.setTextColor(colors.white)
        shell.run("/ami/shop/startup")
    elseif ch == "h" then
        os.reboot()
    end
end

term.setTextColor(colors.white)
