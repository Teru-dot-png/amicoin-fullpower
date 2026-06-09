-- installcasino.lua  v1.0
-- AmiCasino Installer for CC:Tweaked.
-- Supports Update, Force Update, and Clean Install.
--
-- Modes:
--   Update       : Delta-checks hashes -- skips unchanged .lua files.
--                  /ami/casino/data/ preserved.
--   Force Update : Reinstalls ALL .lua files regardless of local hash.
--                  /ami/casino/data/ preserved.
--   Clean Install: Wipes /ami/casino/ then fresh install.

local VERSION   = "1.0"
local REPO_BASE = "https://raw.githubusercontent.com/Teru-dot-png/amicoin-fullpower/refs/heads/main"

local FILES = {
    { src = "/shared/xtea.lua",        dst = "/shared/xtea.lua"        },
    { src = "/ami/casino/startup.lua", dst = "/ami/casino/startup.lua" },
    { src = "/ami/casino/games.lua",   dst = "/ami/casino/games.lua"   },
    { src = "/ami/casino/ui.lua",      dst = "/ami/casino/ui.lua"      },
}

-- Paths wiped on Clean Install.
local CLEAN_DIRS  = { "/ami/casino" }
local CLEAN_FILES = { "/shared/xtea.lua" }

-- ── Smart Update Engine ───────────────────────────────────────────────────────

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
        if hashFile(dst) == remoteHash then return "skip", nil end
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

-- ── Banner ─────────────────────────────────────────────────────────────────────
term.setTextColor(colors.yellow)
print("============================================")
print("  AmiCasino v" .. VERSION .. " -- Installer")
print("============================================")
term.setTextColor(colors.white)
print("")
print("Repository : " .. REPO_BASE)
print("")

-- ── Mode selection ─────────────────────────────────────────────────────────────
local MODE
local forceWrite = false

print("  [U]  Update         (delta-check; skip unchanged .lua)")
print("  [F]  Force Update   (reinstall ALL .lua; keep data)")
term.setTextColor(colors.red)
print("  [I]  Install        (WIPE /ami/casino/ + fresh install)")
term.setTextColor(colors.white)
print("  [Q]  Cancel")
print("")
io.write("Choice [U/F/I/Q]: ")
local ch = (io.read() or ""):gsub("%s", ""):lower()
if ch == "u" then
    MODE = "update"
elseif ch == "f" then
    MODE = "force"; forceWrite = true
elseif ch == "i" then
    MODE = "clean"
else
    print("Aborted."); return
end

-- ── Pre-install steps ──────────────────────────────────────────────────────────
if MODE == "clean" then
    print("")
    term.setTextColor(colors.red)
    print("  WARNING: Install will permanently delete:")
    for _, d in ipairs(CLEAN_DIRS)  do print("    " .. d .. "/  (entire directory)") end
    for _, p in ipairs(CLEAN_FILES) do print("    " .. p) end
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
end

-- Ensure directories exist.
for _, d in ipairs({"/shared", "/ami", "/ami/casino", "/ami/casino/data"}) do
    if not fs.exists(d) then
        fs.makeDir(d)
        term.setTextColor(colors.lightGray); print("  mkdir " .. d)
        term.setTextColor(colors.white)
    end
end

-- ── Download and install .lua files ───────────────────────────────────────────
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
            print("FAILED"); print("    " .. (instErr or "unknown"))
            term.setTextColor(colors.white)
            counts.fail = counts.fail + 1; failed = true
        elseif action == "skip" then
            term.setTextColor(colors.gray)
            print("skip  [" .. remoteHash .. "]")
            term.setTextColor(colors.white)
            counts.skip = counts.skip + 1
            allHashes[#allHashes + 1] = remoteHash
        else
            term.setTextColor(colors.green)
            print(action .. "  [" .. remoteHash .. "]")
            term.setTextColor(colors.white)
            counts[action] = (counts[action] or 0) + 1
            allHashes[#allHashes + 1] = remoteHash
        end
    end
end

-- ── Write startup script ───────────────────────────────────────────────────────
-- Create /startup.lua only on fresh installs (or if it doesn't exist yet)
-- so we don't overwrite a node's or shop's own startup.
if not fs.exists("/startup.lua") or MODE == "clean" then
    local launcher = 'shell.run("/ami/casino/startup")\n'
    local f = fs.open("/startup.lua", "w"); f.write(launcher); f.close()
    term.setTextColor(colors.cyan); print("\nWrote /startup.lua (auto-launch on reboot)")
    term.setTextColor(colors.white)
else
    term.setTextColor(colors.yellow)
    print("\n/startup.lua already exists — not overwritten.")
    print("To launch manually: shell.run(\"/ami/casino/startup\")")
    term.setTextColor(colors.white)
end

-- ── Summary ────────────────────────────────────────────────────────────────────
print("")
local fp = fnv1a(table.concat(allHashes, ":"))
term.setTextColor(colors.lightGray)
print(string.format("  Files: %d skip  %d fresh  %d updated  %d failed",
    counts.skip, counts.fresh or 0, counts.updated or 0, counts.fail))
print("  Install fingerprint: " .. fp)
term.setTextColor(colors.white)

if failed then
    term.setTextColor(colors.red)
    print("\nInstall finished with errors. Check your connection and retry.")
    term.setTextColor(colors.white)
else
    term.setTextColor(colors.lime)
    print("\nAmiCasino installed successfully!")
    term.setTextColor(colors.white)
    print("Reboot or run: shell.run(\"/ami/casino/startup\")")
    print("")
    print("First steps:")
    print("  1. Run the casino, press [A] to add your node(s).")
    print("  2. Fund the casino wallet with enough AMI to cover payouts.")
    print("  3. Players type their Ami-DNS name and choose a game.")
end
