-- shared/xtea.lua
-- XTEA cipher implementation for CC:Tweaked
-- Used for lightweight packet encryption across the Ender Router mesh.
-- Key must be a table of 4 unsigned 32-bit integers.

local xtea = {}

local DELTA = 0x9E3779B9
local NUM_ROUNDS = 32

-- Clamp a Lua number to an unsigned 32-bit integer.
local function u32(n)
    return n % 0x100000000
end

-- Encrypt a 64-bit block (two 32-bit halves v0, v1) with the 128-bit key.
function xtea.encryptBlock(v0, v1, key)
    local sum = 0
    for _ = 1, NUM_ROUNDS do
        v0 = u32(v0 + u32(u32(u32(v1 * 16) ~ u32(v1 / 32)) + v1) ~ u32(sum + key[u32(sum % 4) + 1]))
        sum = u32(sum + DELTA)
        v1 = u32(v1 + u32(u32(u32(v0 * 16) ~ u32(v0 / 32)) + v0) ~ u32(sum + key[u32(math.floor(sum / 0x800) % 4) + 1]))
    end
    return v0, v1
end

-- Decrypt a 64-bit block.
function xtea.decryptBlock(v0, v1, key)
    local sum = u32(DELTA * NUM_ROUNDS)
    for _ = 1, NUM_ROUNDS do
        v1 = u32(v1 - u32(u32(u32(v0 * 16) ~ u32(v0 / 32)) + v0) ~ u32(sum + key[u32(math.floor(sum / 0x800) % 4) + 1]))
        sum = u32(sum - DELTA)
        v0 = u32(v0 - u32(u32(u32(v1 * 16) ~ u32(v1 / 32)) + v1) ~ u32(sum + key[u32(sum % 4) + 1]))
    end
    return v0, v1
end

-- Convert a 128-bit hex string (32 hex chars) into a key table of 4 u32s.
function xtea.keyFromHex(hex)
    assert(#hex == 32, "XTEA key must be a 32-character hex string (128 bits)")
    local key = {}
    for i = 1, 4 do
        local chunk = hex:sub((i - 1) * 8 + 1, i * 8)
        key[i] = tonumber(chunk, 16)
    end
    return key
end

-- Encode a UTF-8 string into a byte array padded to a multiple of 8.
local function stringToBytes(s)
    local bytes = {}
    for i = 1, #s do
        bytes[i] = string.byte(s, i)
    end
    -- Pad with zeros to multiple of 8, prepend 4-byte length
    local len = #s
    local padded = {}
    padded[1] = math.floor(len / 0x1000000) % 256
    padded[2] = math.floor(len / 0x10000) % 256
    padded[3] = math.floor(len / 0x100) % 256
    padded[4] = len % 256
    for _, b in ipairs(bytes) do
        padded[#padded + 1] = b
    end
    while #padded % 8 ~= 0 do
        padded[#padded + 1] = 0
    end
    return padded
end

local function bytesToU32(bytes, offset)
    return u32(bytes[offset] * 0x1000000 + bytes[offset + 1] * 0x10000 + bytes[offset + 2] * 0x100 + bytes[offset + 3])
end

local function u32ToBytes(n)
    return {
        math.floor(n / 0x1000000) % 256,
        math.floor(n / 0x10000) % 256,
        math.floor(n / 0x100) % 256,
        n % 256
    }
end

-- Encrypt a plaintext string; returns a hex-encoded ciphertext string.
function xtea.encrypt(plaintext, keyHex)
    local key = xtea.keyFromHex(keyHex)
    local bytes = stringToBytes(plaintext)
    local out = {}
    for i = 1, #bytes, 8 do
        local v0 = bytesToU32(bytes, i)
        local v1 = bytesToU32(bytes, i + 4)
        local e0, e1 = xtea.encryptBlock(v0, v1, key)
        for _, b in ipairs(u32ToBytes(e0)) do out[#out + 1] = b end
        for _, b in ipairs(u32ToBytes(e1)) do out[#out + 1] = b end
    end
    -- Encode output as hex
    local hex = ""
    for _, b in ipairs(out) do
        hex = hex .. string.format("%02x", b)
    end
    return hex
end

-- Decrypt a hex-encoded ciphertext; returns the original plaintext string.
function xtea.decrypt(cipherhex, keyHex)
    local key = xtea.keyFromHex(keyHex)
    -- Decode hex
    local bytes = {}
    for i = 1, #cipherhex, 2 do
        bytes[#bytes + 1] = tonumber(cipherhex:sub(i, i + 1), 16)
    end
    local out = {}
    for i = 1, #bytes, 8 do
        local v0 = bytesToU32(bytes, i)
        local v1 = bytesToU32(bytes, i + 4)
        local d0, d1 = xtea.decryptBlock(v0, v1, key)
        for _, b in ipairs(u32ToBytes(d0)) do out[#out + 1] = b end
        for _, b in ipairs(u32ToBytes(d1)) do out[#out + 1] = b end
    end
    -- Read length prefix
    local len = out[1] * 0x1000000 + out[2] * 0x10000 + out[3] * 0x100 + out[4]
    local result = ""
    for i = 5, 4 + len do
        result = result .. string.char(out[i])
    end
    return result
end

return xtea
