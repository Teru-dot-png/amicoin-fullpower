-- wallet/secret_manager.lua
-- Generates, stores, and retrieves the user's 128-bit Secret Key.
-- The Secret Key is the master identity for the AmiCoin wallet.
--
-- Storage layout on the Ender Pad:
--   /wallet_data/secret.key  – plaintext hex key (kept local, never transmitted)
--   /wallet_data/address.txt – the wallet's public address (SHA-256 of key)
--
-- Security: The key file is stored in plain text because CC:Tweaked has no OS-
-- level filesystem encryption.  Users must keep physical access to the Pad
-- controlled.  The key is NEVER sent over the network in any form.

local sm = {}

local KEY_FILE     = "/wallet_data/secret.key"
local ADDR_FILE    = "/wallet_data/address.txt"
local NAME_FILE    = "/wallet_data/playername.txt"
local DATA_DIR     = "/wallet_data"

-- ── Helpers ───────────────────────────────────────────────────────────────────

local function ensureDir()
    if not fs.exists(DATA_DIR) then
        fs.makeDir(DATA_DIR)
    end
end

-- Simple non-cryptographic hash to derive a 64-hex-char public address from
-- the 32-hex-char secret key.  In production you would use SHA-256; CC has no
-- built-in hash, so we use a deterministic mixing function that is good enough
-- for this environment's threat model.
local function deriveAddress(keyHex)
    -- Mix the key with a fixed salt through several rounds to produce 64 hex chars.
    local state = {}
    for i = 1, #keyHex do
        state[i] = string.byte(keyHex, i)
    end
    -- Expand to 64 bytes via simple diffusion
    local expanded = {}
    for i = 1, 64 do
        local a = state[((i - 1) % #state) + 1]
        local b = state[((i)     % #state) + 1]
        local c = state[((i + 7) % #state) + 1]
        expanded[i] = (a * 31 + b * 17 + c * 7 + i * 13) % 256
    end
    -- A second diffusion pass
    for i = 1, 64 do
        expanded[i] = bit32.bxor(expanded[i], expanded[(i % 64) + 1]) % 256
    end
    local addr = ""
    for _, b in ipairs(expanded) do
        addr = addr .. string.format("%02x", b)
    end
    return addr
end

-- ── Public API ────────────────────────────────────────────────────────────────

-- Returns true if a secret key already exists on this Pad.
function sm.exists()
    return fs.exists(KEY_FILE)
end

-- Generate a fresh random 128-bit secret key, persist it, and return it.
-- name: the player's chosen display name (string).
function sm.generate(name)
    ensureDir()
    math.randomseed(os.epoch("utc"))
    local key = ""
    for _ = 1, 32 do
        key = key .. string.format("%x", math.random(0, 15))
    end
    -- Pad to exactly 32 chars (in case of single-digit hex)
    local f = fs.open(KEY_FILE, "w")
    f.write(key)
    f.close()

    local addr = deriveAddress(key)
    local af = fs.open(ADDR_FILE, "w")
    af.write(addr)
    af.close()

    if type(name) == "string" and #name > 0 then
        local nf = fs.open(NAME_FILE, "w")
        nf.write(name)
        nf.close()
    end

    return key, addr
end

-- Load the existing secret key.  Returns key, address, playerName or nil, nil, nil.
function sm.load()
    if not sm.exists() then return nil, nil, nil end
    local kf = fs.open(KEY_FILE, "r")
    local key = kf.readAll():gsub("%s", "")
    kf.close()

    local addr
    if fs.exists(ADDR_FILE) then
        local af = fs.open(ADDR_FILE, "r")
        addr = af.readAll():gsub("%s", "")
        af.close()
    else
        addr = deriveAddress(key)
        local af = fs.open(ADDR_FILE, "w")
        af.write(addr)
        af.close()
    end

    local name = nil
    if fs.exists(NAME_FILE) then
        local nf = fs.open(NAME_FILE, "r")
        name = nf.readAll():gsub("%s+$", "")
        nf.close()
    end

    return key, addr, name
end

-- Save or update the stored player name.
function sm.saveName(name)
    ensureDir()
    local nf = fs.open(NAME_FILE, "w")
    nf.write(name)
    nf.close()
end

-- Import a secret key manually entered by the user (migration).
-- Returns address on success, or nil + error string.
function sm.importKey(keyHex)
    keyHex = keyHex:gsub("%s", ""):lower()
    if #keyHex ~= 32 then
        return nil, "Secret key must be exactly 32 hexadecimal characters"
    end
    for c in keyHex:gmatch(".") do
        if not c:match("[0-9a-f]") then
            return nil, "Secret key contains invalid characters (must be hex)"
        end
    end
    ensureDir()
    local f = fs.open(KEY_FILE, "w")
    f.write(keyHex)
    f.close()

    local addr = deriveAddress(keyHex)
    local af = fs.open(ADDR_FILE, "w")
    af.write(addr)
    af.close()
    return addr
end

-- Delete the stored key (factory reset / logout).
function sm.wipe()
    if fs.exists(KEY_FILE)  then fs.delete(KEY_FILE)  end
    if fs.exists(ADDR_FILE) then fs.delete(ADDR_FILE) end
    if fs.exists(NAME_FILE) then fs.delete(NAME_FILE) end
end

-- Derive address from key without storing anything.
function sm.addressFromKey(keyHex)
    return deriveAddress(keyHex)
end

return sm
