-- fix_ui.lua - Emergency UI Framework Hotfix
-- Run this if installnode.lua failed to download UI dependencies
-- 
-- Usage: wget run https://raw.githubusercontent.com/Teru-dot-png/amicoin-fullpower/main/fix_ui.lua

local REPO = "https://raw.githubusercontent.com/Teru-dot-png/amicoin-fullpower/refs/heads/main"

local MISSING_FILES = {
    { src = "/ami/lib/ui/transition.lua", dst = "/ami/lib/ui/transition.lua" },
    { src = "/ami/lib/ui/tween.lua",      dst = "/ami/lib/ui/tween.lua"      },
    { src = "/ami/lib/ui/sound.lua",      dst = "/ami/lib/ui/sound.lua"      },
}

print("========================================")
print("  AmiCoin UI Framework Hotfix v1.0")
print("========================================")
print("")
print("Downloading missing dependencies...")
print("")

local success = true

for _, file in ipairs(MISSING_FILES) do
    io.write("  " .. file.dst .. " ... ")
    local url = REPO .. file.src
    local res = http.get(url)
    
    if not res then
        print("FAILED (HTTP error)")
        success = false
    else
        local content = res.readAll()
        res.close()
        
        -- Ensure directory exists
        local dir = file.dst:match("^(.*)/[^/]+$")
        if dir and not fs.exists(dir) then
            fs.makeDir(dir)
        end
        
        local f = fs.open(file.dst, "w")
        f.write(content)
        f.close()
        print("OK")
    end
end

print("")
if success then
    print("Hotfix complete! Rebooting in 3 seconds...")
    sleep(3)
    os.reboot()
else
    print("Some files failed to download.")
    print("Check your internet connection and try again.")
end
