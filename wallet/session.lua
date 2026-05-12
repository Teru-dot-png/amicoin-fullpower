-- wallet/session.lua
-- Manages the local login session so the user doesn't re-enter their key
-- on every reboot.  The session is stored as an XTEA-encrypted JSON file.
--
-- The session file is encrypted with a device-derived key (based on the
-- computer's ID) so it cannot trivially be copied to another Pad and read.

local xtea = require("/shared/xtea")

local session = {}

local SESSION_FILE = "/wallet_data/session.enc"
local DATA_DIR     = "/wallet_data"

-- Derive a 32-hex-char device key from the computer ID.
local function deviceKey()
    local id = os.getComputerID()
    -- Mix the integer ID through a simple expansion to produce 32 hex chars.
    local mixed = {}
    for i = 1, 32 do
        mixed[i] = (id * (i * 31 + 7) + i * 17) % 16
    end
    local hex = ""
    for _, n in ipairs(mixed) do
        hex = hex .. string.format("%x", n)
    end
    return hex
end

local function ensureDir()
    if not fs.exists(DATA_DIR) then fs.makeDir(DATA_DIR) end
end

-- Save session data (table) to encrypted disk.
function session.save(data)
    ensureDir()
    local plain  = textutils.serialiseJSON(data)
    local dKey   = deviceKey()
    local cipher = xtea.encrypt(plain, dKey)
    local f = fs.open(SESSION_FILE, "w")
    f.write(cipher)
    f.close()
end

-- Load and decrypt the session; returns table or nil.
function session.load()
    if not fs.exists(SESSION_FILE) then return nil end
    local f = fs.open(SESSION_FILE, "r")
    local cipher = f.readAll()
    f.close()
    local dKey = deviceKey()
    local ok, plain = pcall(xtea.decrypt, cipher, dKey)
    if not ok then return nil end
    local data = textutils.unserialiseJSON(plain)
    return type(data) == "table" and data or nil
end

-- Clear the saved session (logout).
function session.clear()
    if fs.exists(SESSION_FILE) then fs.delete(SESSION_FILE) end
end

-- Returns true if a valid session exists on disk.
function session.exists()
    return fs.exists(SESSION_FILE)
end

return session
