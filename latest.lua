-- latest.lua
-- Runs an AmiCoin installer from the newest commit on main.
--
-- raw.githubusercontent.com caches branch URLs (".../main/...") for about five
-- minutes and ignores "?123" cache-busters, so right after a push the normal
-- install commands can still fetch the previous version. URLs that name a
-- commit hash never change, so they are never stale. This asks the GitHub API
-- which commit main is on, then downloads the installer -- and, through
-- AMI_REPO_BASE, everything the installer fetches -- from that commit.
--
-- Usage:  latest <node|pad|shop|casino|exchange>

local REPO = "Teru-dot-png/amicoin-fullpower"
local RAW  = "https://raw.githubusercontent.com/" .. REPO

local INSTALLERS = { node = true, pad = true, shop = true, casino = true, exchange = true }

local which = tostring((...) or ""):lower()
if not INSTALLERS[which] then
    print("Usage: latest <node|pad|shop|casino|exchange>")
    return
end

io.write("Asking GitHub for the latest commit ... ")
local res, err = http.get("https://api.github.com/repos/" .. REPO .. "/commits/main",
    { Accept = "application/vnd.github.sha" })
if not res then
    term.setTextColor(colors.red)
    print("FAILED")
    print("  " .. tostring(err))
    term.setTextColor(colors.white)
    print("GitHub allows 60 of these per hour per server.")
    print("Wait a few minutes, or use the normal install command.")
    return
end
local sha = res.readAll():gsub("%s", ""); res.close()
if #sha ~= 40 or not sha:match("^%x+$") then
    term.setTextColor(colors.red); print("FAILED (unexpected reply)")
    term.setTextColor(colors.white)
    return
end
term.setTextColor(colors.green); print(sha:sub(1, 7))
term.setTextColor(colors.white)

local base = RAW .. "/" .. sha
local file = "install" .. which .. ".lua"
io.write("Downloading " .. file .. " ... ")
local dl = http.get(base .. "/" .. file)
if not dl then
    term.setTextColor(colors.red); print("FAILED")
    term.setTextColor(colors.white)
    return
end
local src = dl.readAll(); dl.close()
local f = fs.open("/" .. file, "w"); f.write(src); f.close()
print("OK")
print("")

-- The installer reads this instead of its cached "main" URL.
_G.AMI_REPO_BASE = base
shell.run("/" .. file)
_G.AMI_REPO_BASE = nil
