-- node/ledger.lua
-- Manages the on-disk wallet address -> balance database and name registry.
-- All balances are stored in microcoins (1 AMI = 1,000,000 microcoins).

local ledger = {}

local LEDGER_FILE = "/data/ledger.json"
local NAMES_FILE  = "/data/names.json"   -- playerName (lower) -> address

-- ── Name registry helpers ─────────────────────────────────────────────────────

local function loadNames()
    if not fs.exists(NAMES_FILE) then return {} end
    local f = fs.open(NAMES_FILE, "r")
    local raw = f.readAll()
    f.close()
    return textutils.unserialiseJSON(raw) or {}
end

local function saveNames(db)
    if not fs.exists("/data") then fs.makeDir("/data") end
    local f = fs.open(NAMES_FILE, "w")
    f.write(textutils.serialiseJSON(db))
    f.close()
end

-- Register or update a player name -> address mapping.
function ledger.registerName(name, address)
    if type(name) ~= "string" or #name == 0 then return false end
    if type(address) ~= "string" or #address ~= 128 then return false end
    local db = loadNames()
    db[name:lower()] = address
    saveNames(db)
    return true
end

-- Look up an address by player name. Returns address string or nil.
function ledger.lookupName(name)
    if type(name) ~= "string" then return nil end
    local db = loadNames()
    return db[name:lower()]
end

-- Return the registered name for an address, or nil.
function ledger.getNameByAddress(address)
    local db = loadNames()
    for name, addr in pairs(db) do
        if addr == address then return name end
    end
    return nil
end

local function load()
    if not fs.exists(LEDGER_FILE) then
        return {}
    end
    local f = fs.open(LEDGER_FILE, "r")
    local raw = f.readAll()
    f.close()
    return textutils.unserialiseJSON(raw) or {}
end

local function save(db)
    if not fs.exists("/data") then
        fs.makeDir("/data")
    end
    local f = fs.open(LEDGER_FILE, "w")
    f.write(textutils.serialiseJSON(db))
    f.close()
end

-- Return the balance (in microcoins) for a given address.
function ledger.getBalance(address)
    local db = load()
    return db[address] or 0
end

-- Credit microcoins to an address.
function ledger.credit(address, amount)
    assert(type(address) == "string" and #address == 128, "Invalid address")
    assert(type(amount) == "number" and amount > 0, "Amount must be positive")
    local db = load()
    db[address] = (db[address] or 0) + amount
    save(db)
end

-- Transfer microcoins between two addresses.
-- Returns true on success, or false + error string on failure.
function ledger.transfer(fromAddress, toAddress, amount)
    assert(type(fromAddress) == "string" and #fromAddress == 128, "Invalid sender address")
    assert(type(toAddress) == "string" and #toAddress == 128, "Invalid recipient address")
    assert(type(amount) == "number" and amount > 0, "Amount must be positive")

    local db = load()
    local senderBal = db[fromAddress] or 0
    if senderBal < amount then
        return false, "Insufficient funds"
    end
    db[fromAddress] = senderBal - amount
    db[toAddress] = (db[toAddress] or 0) + amount
    save(db)
    return true
end

-- Return a snapshot of the entire ledger (address -> balance table).
function ledger.snapshot()
    return load()
end

-- Register a new address with a zero balance if it doesn't exist yet.
function ledger.register(address)
    assert(type(address) == "string" and #address == 128, "Invalid address")
    local db = load()
    if not db[address] then
        db[address] = 0
        save(db)
        return true
    end
    return false -- already exists
end

return ledger
