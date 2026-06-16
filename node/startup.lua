-- node/startup.lua
-- AmiCoin Node – entry point for the Advanced Computer + Ender Router anchor.
--
-- Responsibilities:
--   1. Discover and open the Ender Router peripheral.
--   2. Start the Proof-of-Uptime miner daemon in a parallel coroutine.
--   3. Listen for incoming XTEA-encrypted packets on the mesh channel.
--   4. Dispatch verified commands: HEARTBEAT, BALANCE, TRANSFER.
--   5. Display a live status dashboard on the terminal.
--
-- Packet format (JSON, encrypted with sender's secret key, 128-bit):
--   { cmd="HEARTBEAT", from="<64-hex address>" }
--   { cmd="BALANCE",   from="<address>", nonce=<int> }
--   { cmd="TRANSFER",  from="<address>", to="<address>" OR toName="PlayerName", amount=<int uAMI>, nonce=<int> }
--   { cmd="REGISTER",  from="<address>", name="PlayerName" }
--   { cmd="LOOKUP",    from="<address>", name="PlayerName" }
--
-- Security note: XTEA here provides confidentiality in transit.
-- The node does NOT store private keys.  Address authenticity relies on
-- the XTEA encryption being keyed from the wallet's secret key; a wallet
-- that can decrypt/encrypt with the correct key effectively proves ownership.
-- (For a production chain you would layer a Schnorr/EdDSA signature on top.)

local xtea     = require("xtea")
local ledger   = require("ledger")
local miner    = require("miner_daemon")
local upgrades = require("upgrades")

-- ── Configuration ────────────────────────────────────────────────────────────
local MESH_CHANNEL    = 1337          -- Ender Router channel all nodes share
local SHOP_CHANNEL    = 1338          -- Plaintext invoice / PAYMENT_ACK channel
local NODE_VERSION    = "1.0.0"
-- nodeFingerprint is declared here so handlePacket, monitorLoop, and main()
-- all share the same upvalue.  computeNodeFingerprint() sets it at boot.
local nodeFingerprint = "unknown"
-- The node's own XTEA key is used to encrypt replies.
-- On first run a random key is generated and persisted to /data/node_key.txt
-- Wallets must be told this key during setup (printed on first boot).

local function loadOrCreateNodeKey()
    local keyFile = "/data/node_key.txt"
    if not fs.exists("/data") then fs.makeDir("/data") end
    if fs.exists(keyFile) then
        local f = fs.open(keyFile, "r")
        local k = f.readAll():gsub("%s", "")
        f.close()
        return k
    end
    -- Generate a random 128-bit key (32 hex chars)
    math.randomseed(os.epoch("utc"))
    local hex = ""
    for _ = 1, 32 do
        hex = hex .. string.format("%x", math.random(0, 15))
    end
    local f = fs.open(keyFile, "w")
    f.write(hex)
    f.close()
    return hex
end

-- ── Password-based key exchange ─────────────────────────────────────────────
-- Derives a 32-hex-char XTEA key from a plain-text password.
-- MUST be identical to the copy in wallet/comms.lua.
local function keyFromPassword(password)
    local bytes = {}
    for i = 1, #password do bytes[i] = string.byte(password, i) end
    if #bytes == 0 then bytes = {0} end
    local out = {}
    for i = 1, 16 do
        local a = bytes[((i - 1) % #bytes) + 1]
        local b = bytes[(i       % #bytes) + 1]
        local c = bytes[((i + 3) % #bytes) + 1]
        out[i] = bit32.bxor(a * 31 + b * 17 + c * 7 + i * 13, i * 97) % 256
    end
    for i = 1, 16 do
        out[i] = bit32.bxor(out[i], out[(i % 16) + 1]) % 256
    end
    local hex = ""
    for _, b in ipairs(out) do hex = hex .. string.format("%02x", b) end
    return hex
end

-- Prompt for (or load) the node setup password used for wallet auto-fetch.
local function loadOrCreateSetupPassword()
    local pwFile = "/data/setup_password.txt"
    if not fs.exists("/data") then fs.makeDir("/data") end
    if fs.exists(pwFile) then
        local f = fs.open(pwFile, "r")
        local pw = f.readAll():gsub("%s+$", "")
        f.close()
        return pw
    end
    -- First boot: ask for a password
    print("")
    print("[!] Set a SETUP PASSWORD for this node.")
    print("    Wallets can use it to auto-fetch your")
    print("    node key without manual copy-paste.")
    print("    Leave blank to disable auto-fetch.")
    io.write("    Password: ")
    local pw = read("*")
    if #pw > 0 then
        local f = fs.open(pwFile, "w")
        f.write(pw)
        f.close()
        print("[!] Password saved. Security = password strength.")
    else
        print("[!] Auto-fetch disabled (manual key entry only).")
    end
    return pw
end

-- ── Ender Router setup ───────────────────────────────────────────────────────
local function findRouter()
    for _, name in ipairs(peripheral.getNames()) do
        if peripheral.getType(name) == "ender_modem" or
           peripheral.getType(name):find("ender") then
            return peripheral.wrap(name)
        end
    end
    -- Fallback: try a wired/wireless modem named "top","back", etc.
    for _, side in ipairs({"top","bottom","left","right","front","back"}) do
        if peripheral.isPresent(side) then
            local t = peripheral.getType(side)
            if t == "modem" or t == "ender_modem" then
                return peripheral.wrap(side)
            end
        end
    end
    return nil
end

-- ── FNV-1a hash ─────────────────────────────────────────────────────────────
local function fnv1a(s)
    local hash = 2166136261
    for i = 1, #s do
        hash = bit32.bxor(hash, string.byte(s, i))
        hash = (hash * 16777619) % 4294967296
    end
    return string.format("%08x", hash)
end

-- ── CONSOLIDATE_IN receipt log ───────────────────────────────────────────────
-- Tracks receipt tokens that have already been used for a CONSOLIDATE_IN on
-- this node.  Prevents a wallet from replaying the same receipt to credit its
-- balance multiple times across different nodes.
-- Stored in /data/consolidate_receipts.json as { [receipt_hex] = true }.
local RECEIPTS_FILE = "/data/consolidate_receipts.json"

local function loadReceipts()
    if not fs.exists(RECEIPTS_FILE) then return {} end
    local f = fs.open(RECEIPTS_FILE, "r")
    local raw = f.readAll(); f.close()
    return textutils.unserialiseJSON(raw) or {}
end

local function markReceiptUsed(receipt)
    if type(receipt) ~= "string" or #receipt == 0 then return end
    if not fs.exists("/data") then fs.makeDir("/data") end
    local db = loadReceipts()
    db[receipt] = true
    local f = fs.open(RECEIPTS_FILE, "w")
    f.write(textutils.serialiseJSON(db)); f.close()
end

local function isReceiptUsed(receipt)
    if type(receipt) ~= "string" or #receipt == 0 then return false end
    return loadReceipts()[receipt] == true
end

-- ── Packet handling ──────────────────────────────────────────────────────────
local function handlePacket(nodeKey, setupPassword, router, senderKey, cipherhex, replyChannel)
    -- Try to decrypt using the sender's key (passed as the first 32 chars of
    -- the raw message before the '|' separator).
    -- Packet wire format: "<senderKeyHex>|<cipherhex>"
    local ok, plain = pcall(xtea.decrypt, cipherhex, senderKey)
    if not ok then
        print("[Net] Decrypt error from channel " .. replyChannel)
        os.sleep(upgrades.getCollisionDelay())
        return
    end

    local pkt = textutils.unserialiseJSON(plain)
    if type(pkt) ~= "table" or not pkt.cmd then
        print("[Net] Malformed packet")
        os.sleep(upgrades.getCollisionDelay())
        return
    end

    local cmd  = pkt.cmd
    local from = pkt.from
    local who  = from and from:sub(1,10) or "???"

    if not from or #from ~= 128 then
        print("[Net] Bad 'from' in " .. tostring(cmd) .. " from key " .. senderKey:sub(1,8) .. "...")
        os.sleep(upgrades.getCollisionDelay())
        return
    end

    -- Targeted routing: if the wallet included a targetKey hint, only respond
    -- if our key starts with that prefix. Stops all nodes replying to one broadcast.
    if type(pkt.targetKey) == "string" and #pkt.targetKey > 0 then
        if nodeKey:sub(1, #pkt.targetKey) ~= pkt.targetKey then
            return  -- packet is for a different node
        end
    end

    if cmd == "HEARTBEAT" then
        miner.heartbeat(from)
        -- heartbeat is high-frequency, only log occasionally to avoid spam

    elseif cmd == "BALANCE" then
        local bal = ledger.getBalance(from)
        print(string.format("[Net] BALANCE  %s... -> %d uAMI", who, bal))
        local resp = textutils.serialiseJSON({ ok=true, address=from, balance=bal })
        local enc  = xtea.encrypt(resp, nodeKey)
        router.transmit(replyChannel, MESH_CHANNEL, enc)

    elseif cmd == "TRANSFER" then
        -- Recipient can be a raw 64-hex address OR a player name via toName.
        local to     = pkt.to
        local amount = pkt.amount
        if not to and pkt.toName then
            to = ledger.lookupName(pkt.toName)
            if not to then
                local err = xtea.encrypt(textutils.serialiseJSON({ok=false, err="Player '" .. pkt.toName .. "' not found"}), nodeKey)
                router.transmit(replyChannel, MESH_CHANNEL, err)
                return
            end
        end
        if type(to) ~= "string" or #to ~= 128 then
            local err = xtea.encrypt(textutils.serialiseJSON({ok=false, err="Invalid recipient"}), nodeKey)
            router.transmit(replyChannel, MESH_CHANNEL, err)
            return
        end
        if type(amount) ~= "number" or amount <= 0 then
            local err = xtea.encrypt(textutils.serialiseJSON({ok=false, err="Invalid amount"}), nodeKey)
            router.transmit(replyChannel, MESH_CHANNEL, err)
            return
        end
        -- Floor to whole microcoins; prevents fractional balance accumulation
        -- that could cause floating-point ledger drift over many transactions.
        amount = math.floor(amount)
        if amount <= 0 then
            local err = xtea.encrypt(textutils.serialiseJSON({ok=false, err="Amount rounds to zero"}), nodeKey)
            router.transmit(replyChannel, MESH_CHANNEL, err)
            return
        end
        local success, errMsg = ledger.transfer(from, to, amount)
        if success then
            -- Transfer Toll: skim extra routing fee from sender to treasury.
            -- Comes from sender's balance AFTER the transfer (sender pays toll
            -- on top of the amount; recipient receives the full amount).
            -- If sender has no remaining balance, toll is silently skipped.
            -- floor applied; toll must be >= 1 to apply.
            local toll = upgrades.getTransferTollAmount()
            if toll > 0 then
                local upgSt = upgrades.getState()
                if type(upgSt.treasury) == "string" and #upgSt.treasury == 128 then
                    local drained, _ = ledger.drain(from, toll)
                    if drained > 0 then
                        ledger.credit(upgSt.treasury, drained)
                    end
                end
            end
            print(string.format("[Net] TRANSFER %s... -> %s... %d uAMI OK%s",
                who, to:sub(1,10), amount, toll > 0 and (" toll=" .. toll) or ""))
        else
            print(string.format("[Net] TRANSFER %s... FAILED: %s", who, errMsg or "?"))
        end
        local resp = xtea.encrypt(
            textutils.serialiseJSON({ ok=success, err=errMsg }),
            nodeKey
        )
        router.transmit(replyChannel, MESH_CHANNEL, resp)

    elseif cmd == "REGISTER" then
        local isNew = ledger.register(from)
        if type(pkt.name) == "string" and #pkt.name > 0 then
            ledger.registerName(pkt.name, from)
            print(string.format("[Net] REGISTER %s (%s...)", pkt.name, who))
        elseif isNew then
            print(string.format("[Net] REGISTER %s... (anonymous)", who))
        end
        local resp = xtea.encrypt(textutils.serialiseJSON({ok=true}), nodeKey)
        router.transmit(replyChannel, MESH_CHANNEL, resp)

    elseif cmd == "LOOKUP" then
        local name = pkt.name
        if type(name) ~= "string" or #name == 0 then
            local err = xtea.encrypt(textutils.serialiseJSON({ok=false, err="Missing name"}), nodeKey)
            router.transmit(replyChannel, MESH_CHANNEL, err)
            return
        end
        local addr = ledger.lookupName(name)
        local resp
        if addr then
            print(string.format("[Net] LOOKUP   '%s' -> %s...", name, addr:sub(1,10)))
            resp = textutils.serialiseJSON({ok=true, address=addr, name=name})
        else
            print(string.format("[Net] LOOKUP   '%s' -> not found", name))
            resp = textutils.serialiseJSON({ok=false, err="Player '" .. name .. "' not found"})
        end
        router.transmit(replyChannel, MESH_CHANNEL, xtea.encrypt(resp, nodeKey))

    elseif cmd == "GETKEY" then
        -- Password-based node key delivery.
        -- Reply is encrypted with keyFromPassword(password), NOT the node key,
        -- so the wallet can decrypt it before it has the node key.
        if type(setupPassword) ~= "string" or #setupPassword == 0 then
            local resp = xtea.encrypt(textutils.serialiseJSON({ok=false, err="Auto-fetch disabled on this node"}), keyFromPassword("disabled"))
            router.transmit(replyChannel, MESH_CHANNEL, resp)
            return
        end
        local provided = pkt.password
        if type(provided) ~= "string" or provided ~= setupPassword then
            -- Use a dummy key so the wallet gets a decrypt error (not a hang)
            local resp = xtea.encrypt(textutils.serialiseJSON({ok=false, err="Wrong password"}), keyFromPassword("wrong"))
            router.transmit(replyChannel, MESH_CHANNEL, resp)
            return
        end
        local pwdKey = keyFromPassword(setupPassword)
        local resp   = xtea.encrypt(textutils.serialiseJSON({ok=true, key=nodeKey}), pwdKey)
        router.transmit(replyChannel, MESH_CHANNEL, resp)
        print("[Net] Sent node key to " .. from:sub(1,12) .. "... (password auth)")

    elseif cmd == "VAULT_LOCK" then
        local amount   = pkt.amount
        local duration = pkt.duration
        if type(amount) ~= "number" or amount <= 0 then
            router.transmit(replyChannel, MESH_CHANNEL,
                xtea.encrypt(textutils.serialiseJSON({ok=false, err="Invalid amount"}), nodeKey))
            return
        end
        if type(duration) ~= "number" or duration <= 0 then
            router.transmit(replyChannel, MESH_CHANNEL,
                xtea.encrypt(textutils.serialiseJSON({ok=false, err="Invalid duration"}), nodeKey))
            return
        end
        -- Cap vault lock to 30 days max (2,592,000 s) to prevent accidental
        -- permanent self-lockout from wildly large duration values.
        local MAX_VAULT_DURATION = 2592000  -- 30 days in seconds
        if math.floor(duration) > MAX_VAULT_DURATION then
            router.transmit(replyChannel, MESH_CHANNEL,
                xtea.encrypt(textutils.serialiseJSON({
                    ok=false, err="Duration exceeds maximum (30 days / 2592000 s)"
                }), nodeKey))
            return
        end
        -- Floor amount to whole microcoins.
        local ok, result = ledger.vaultLock(from, math.floor(amount), math.floor(duration))
        if ok then
            print(string.format("[Net] VAULT_LOCK %s... %d uAMI for %ds -> %s...", who, amount, duration, result:sub(1,8)))
            router.transmit(replyChannel, MESH_CHANNEL,
                xtea.encrypt(textutils.serialiseJSON({ok=true, vault_id=result}), nodeKey))
        else
            print(string.format("[Net] VAULT_LOCK %s... FAILED: %s", who, result))
            router.transmit(replyChannel, MESH_CHANNEL,
                xtea.encrypt(textutils.serialiseJSON({ok=false, err=result}), nodeKey))
        end

    elseif cmd == "VAULT_UNLOCK" then
        local vaultId = pkt.vault_id
        if type(vaultId) ~= "string" then
            router.transmit(replyChannel, MESH_CHANNEL,
                xtea.encrypt(textutils.serialiseJSON({ok=false, err="Missing vault_id"}), nodeKey))
            return
        end
        local ok, result = ledger.vaultUnlock(from, vaultId)
        if ok then
            print(string.format("[Net] VAULT_UNLOCK %s... vault %s... -> %d uAMI", who, vaultId:sub(1,8), result))
            router.transmit(replyChannel, MESH_CHANNEL,
                xtea.encrypt(textutils.serialiseJSON({ok=true, amount=result}), nodeKey))
        else
            print(string.format("[Net] VAULT_UNLOCK %s... FAILED: %s", who, result))
            router.transmit(replyChannel, MESH_CHANNEL,
                xtea.encrypt(textutils.serialiseJSON({ok=false, err=result}), nodeKey))
        end

    elseif cmd == "VAULT_LIST" then
        local vaults = ledger.listVaults(from)
        print(string.format("[Net] VAULT_LIST  %s... -> %d vault(s)", who, #vaults))
        router.transmit(replyChannel, MESH_CHANNEL,
            xtea.encrypt(textutils.serialiseJSON({ok=true, vaults=vaults}), nodeKey))

    elseif cmd == "FINGERPRINT" then
        -- Wallet requests the node's current file fingerprint for tamper detection.
        local resp = textutils.serialiseJSON({
            ok          = true,
            fingerprint = nodeFingerprint,
            version     = NODE_VERSION,
        })
        router.transmit(replyChannel, MESH_CHANNEL, xtea.encrypt(resp, nodeKey))

    elseif cmd == "GOSSIP_DNS" then
        -- Wallet gossiping a name<->address mapping discovered elsewhere.
        -- Encrypted with wallet key + targeted routing = private to this node.
        -- Security: only accept gossip if the name is NOT already registered,
        -- or if the gossiped address matches the existing registration exactly.
        -- This prevents a malicious wallet from redirecting another player's
        -- registered name to an attacker-controlled address.
        local gname = pkt.name
        local gaddr = pkt.address
        if type(gname) == "string" and #gname > 0
        and type(gaddr) == "string" and #gaddr == 128 then
            local existing = ledger.lookupName(gname)
            if not existing or existing == gaddr then
                ledger.registerName(gname, gaddr)
            end
            -- Fire-and-forget; no reply needed.
        end

    elseif cmd == "STATS" then
        -- Returns network-wide stats: active wallets, total supply, current rate, tick count.
        local active = miner.getActive()
        local snap   = ledger.snapshot()
        local total  = 0
        for _, v in pairs(snap) do total = total + v end
        local payload = {
            ok             = true,
            active_wallets = #active,
            total_supply   = total,
            current_rate   = miner.getCurrentRate(),
            effective_rate = math.floor(miner.getCurrentRate() * upgrades.getMinerMultiplier()),
            total_ticks    = miner.getTotalTicks(),
            lag_factor     = miner.getLagFactor(),
            node_key_hint  = nodeKey:sub(1, 8),
            fingerprint    = nodeFingerprint,
            priority_ping     = upgrades.hasPriorityPing(),
            theme             = upgrades.getActiveTheme(),       -- crown overrides matrix_ui
            casino_rake_level = upgrades.getCasinoRakeLevel(),
            crown_level       = upgrades.getCrownLevel(),
            treasury_address  = (upgrades.getState() or {}).treasury,
        }
        router.transmit(replyChannel, MESH_CHANNEL,
            xtea.encrypt(textutils.serialiseJSON(payload), nodeKey))


    elseif cmd == "CONSOLIDATE_OUT" then
        -- Drain alice's balance from this node.  The wallet carries the returned
        -- receipt to the target node for CONSOLIDATE_IN.
        -- Security model: only alice (via her XTEA key) can trigger this on her
        -- own address; the receipt ties the drain to this specific node + nonce.
        local req_amount = pkt.amount
        local nonce      = pkt.nonce or 0
        if type(req_amount) ~= "number" or req_amount <= 0 then
            router.transmit(replyChannel, MESH_CHANNEL,
                xtea.encrypt(textutils.serialiseJSON({ok=false, err="Invalid amount"}), nodeKey))
            return
        end
        local drained, derr = ledger.drain(from, math.floor(req_amount))
        if drained <= 0 then
            print(string.format("[Net] CONSOLIDATE_OUT %s... FAILED: %s", who, derr or "no balance"))
            router.transmit(replyChannel, MESH_CHANNEL,
                xtea.encrypt(textutils.serialiseJSON({ok=false, err=derr or "No balance to drain"}), nodeKey))
            return
        end
        -- Receipt: fnv1a of (drained amount | nonce | first 8 chars of this node's key).
        -- Lets the target node log a human-readable audit trail.
        local receipt = fnv1a(tostring(drained) .. "|" .. tostring(nonce) .. "|" .. nodeKey:sub(1, 8))
        print(string.format("[Net] CONSOLIDATE_OUT %s... drained %d uAMI  receipt=%s",
            who, drained, receipt:sub(1, 8)))
        router.transmit(replyChannel, MESH_CHANNEL,
            xtea.encrypt(textutils.serialiseJSON({
                ok      = true,
                amount  = drained,
                receipt = receipt,
                nonce   = nonce,
            }), nodeKey))

    elseif cmd == "CONSOLIDATE_IN" then
        -- Credit alice on this (target) node after a verified CONSOLIDATE_OUT.
        -- Trust basis: alice's XTEA secretKey authenticated this packet, so only
        -- the legitimate wallet holder can credit their own address here.
        local amount  = pkt.amount
        local receipt = pkt.receipt   -- audit trail from the source node
        if type(amount) ~= "number" or amount <= 0 then
            router.transmit(replyChannel, MESH_CHANNEL,
                xtea.encrypt(textutils.serialiseJSON({ok=false, err="Invalid amount"}), nodeKey))
            return
        end
        -- Reject replayed receipts: a receipt may only be used ONCE per node.
        -- This prevents a wallet from replaying a single CONSOLIDATE_OUT receipt
        -- to illegitimately credit the same coins on multiple target nodes.
        if type(receipt) == "string" and isReceiptUsed(receipt) then
            print(string.format("[Net] CONSOLIDATE_IN %s... REJECTED: receipt %s already used",
                who, tostring(receipt):sub(1, 8)))
            router.transmit(replyChannel, MESH_CHANNEL,
                xtea.encrypt(textutils.serialiseJSON({ok=false, err="Receipt already redeemed on this node"}), nodeKey))
            return
        end
        local creditAmt = math.floor(amount)
        -- Fee Snatcher: skim a small routing fee into the node treasury
        local fee = upgrades.getFeeSnatchAmount()
        if fee > 0 and creditAmt > fee then
            local st = upgrades.getState()
            if type(st.treasury) == "string" and #st.treasury == 128 then
                ledger.credit(st.treasury, fee)
                creditAmt = creditAmt - fee
            end
        end
        ledger.credit(from, creditAmt)
        -- Mark receipt consumed so it cannot be replayed on this node again.
        if type(receipt) == "string" and #receipt > 0 then
            markReceiptUsed(receipt)
        end
        print(string.format("[Net] CONSOLIDATE_IN  %s... credited %d uAMI  receipt=%s",
            who, creditAmt, tostring(receipt):sub(1, 8)))
        router.transmit(replyChannel, MESH_CHANNEL,
            xtea.encrypt(textutils.serialiseJSON({ok=true, amount=creditAmt}), nodeKey))
    end
end

-- ── Self-update ─────────────────────────────────────────────────────────────
local REPO_BASE = "https://raw.githubusercontent.com/Teru-dot-png/amicoin-fullpower/refs/heads/main"
local UPDATE_FILES = {
    { src="/shared/xtea.lua",       dst="/shared/xtea.lua"   },
    { src="/node/startup.lua",      dst="/startup.lua"       },
    { src="/node/ledger.lua",       dst="/ledger.lua"        },
    { src="/node/miner_daemon.lua", dst="/miner_daemon.lua"  },
    { src="/node/xtea.lua",         dst="/xtea.lua"          },
    { src="/node/upgrades.lua",     dst="/upgrades.lua"      },
}

-- Compute a combined FNV-1a hash of all running node files.
-- Called once at boot; result is stored in the module-level nodeFingerprint.
local function computeNodeFingerprint()
    local checkFiles = {
        "/startup.lua", "/ledger.lua", "/miner_daemon.lua",
        "/xtea.lua",    "/shared/xtea.lua",
    }
    local parts = {}
    for _, fp in ipairs(checkFiles) do
        if fs.exists(fp) then
            local fh = fs.open(fp, "r")
            parts[#parts + 1] = fnv1a(fh.readAll())
            fh.close()
        else
            parts[#parts + 1] = "missing"
        end
    end
    return fnv1a(table.concat(parts, ":"))
end

-- note that selfUpdate might not always be pulling from the latest repo state,
-- if the update just happened to be triggered before the latest files were pushed to GitHub.
-- github needs a minute or two to reflect new commits in the raw URLs, and if the node reboots before
-- that happens it might pull the old files again and fail the update (since the old files are already there and won't be replaced).
local function selfUpdate()
    print("")
    print("[Update] Fetching latest files from GitHub...")
    local failed  = false
    local hashes  = {}
    for _, entry in ipairs(UPDATE_FILES) do
        io.write("[Update] " .. entry.dst .. " ... ")
        local ok, res = pcall(http.get, REPO_BASE .. entry.src)
        if ok and res then
            local content = res.readAll()
            res.close()
            if #content < 64 then
                print("REJECTED (too small - possible 404)")
                failed = true
            else
                local hash = fnv1a(content)
                hashes[#hashes + 1] = hash
                local dir = entry.dst:match("^(.*)/[^/]+$")
                if dir and dir ~= "" and not fs.exists(dir) then fs.makeDir(dir) end
                if fs.exists(entry.dst) then fs.delete(entry.dst) end
                local f = fs.open(entry.dst, "w")
                f.write(content)
                f.close()
                print("OK [" .. hash .. "]")
            end
        else
            print("FAILED")
            failed = true
        end
    end
    if failed then
        print("[Update] Some files failed. Will retry on next reboot.")
    else
        local fp = fnv1a(table.concat(hashes, ":"))
        print("[Update] Fingerprint: " .. fp)
        print("[Update] Complete! Rebooting in 3s...")
        os.sleep(3)
        os.reboot()
    end
end

-- ── Status display ───────────────────────────────────────────────────────────
local function statusLoop()
    while true do
        os.sleep(30)
        ledger.flush()  -- flush any cached ledger writes (Smart Cache safety net)
        local active = miner.getActive()
        local snap   = ledger.snapshot()
        local total  = 0
        for _, v in pairs(snap) do total = total + v end
        local lag = miner.getLagFactor()
        local lagStr = lag < 0.7 and string.format(" | LAG %.0f%%", lag * 100) or ""
        print(string.format("[Node] Active: %d | Supply: %d uAMI%s", #active, total, lagStr))
    end
end

-- ── Monitor display ──────────────────────────────────────────────────────────
-- Draws live stats on an attached monitor every 10 s.
-- If no monitor is connected the loop simply sleeps and checks again later.
local function monitorLoop(nodeKey)
    while true do
        -- Throttle monitor refresh when server is lagging to reduce tick pressure.
        local lag      = miner.getLagFactor()
        local sleepSec = (lag < 0.7) and 30 or 10

        local mon = peripheral.find("monitor")
        if mon then
            pcall(function()
                pcall(function() mon.setTextScale(0.5) end)
                local mw = mon.getSize()

                -- Matrix UI theme (Advanced Matrix UI upgrade)
                local theme = upgrades.getMatrixTheme()
                local THEME_COLORS = {
                    green_phosphor = {fg=colors.lime,       hdr=colors.green},
                    amber          = {fg=colors.orange,     hdr=colors.brown},
                    ice_blue       = {fg=colors.cyan,       hdr=colors.lightBlue},
                    deep_violet    = {fg=colors.purple,     hdr=colors.purple},
                    neon_pink      = {fg=colors.pink,       hdr=colors.pink},
                    solar_orange   = {fg=colors.orange,     hdr=colors.red},
                    arctic_white   = {fg=colors.white,      hdr=colors.lightGray},
                    spectrum       = {fg=colors.white,      hdr=colors.blue},
                    void_red       = {fg=colors.red,        hdr=colors.red},
                    genesis_gold   = {fg=colors.yellow,     hdr=colors.yellow},
                }
                local tc = (theme and THEME_COLORS[theme]) or {fg=colors.white, hdr=colors.red}

                mon.setBackgroundColor(colors.black)
                mon.clear()

                -- Header bar
                mon.setBackgroundColor(tc.hdr)
                mon.setTextColor(colors.white)
                mon.setCursorPos(1, 1)
                mon.clearLine()
                local title = " AmiCoin Node v" .. NODE_VERSION
                mon.setCursorPos(math.floor((mw - #title) / 2) + 1, 1)
                mon.write(title)
                mon.setBackgroundColor(colors.black)

                -- Divider
                mon.setTextColor(colors.gray)
                mon.setCursorPos(1, 2)
                mon.write(string.rep("-", mw))

                -- Stats
                local active = miner.getActive()
                local snap   = ledger.snapshot()
                local total  = 0
                for _, v in pairs(snap) do total = total + v end
                local ami = string.format("%.6f AMI", total / 1000000)

                mon.setCursorPos(1, 3)
                mon.setTextColor(tc.fg)
                mon.write("Key:    " .. nodeKey:sub(1, 16) .. "...")

                mon.setCursorPos(1, 4)
                mon.setTextColor(tc.fg)
                mon.write("Active: " .. #active .. " wallet(s)")

                mon.setCursorPos(1, 5)
                mon.setTextColor(tc.fg)
                mon.write("Supply: " .. total .. " uAMI")

                mon.setCursorPos(1, 6)
                mon.setTextColor(tc.fg)
                mon.write("      = " .. ami)

                mon.setCursorPos(1, 7)
                mon.setTextColor(tc.fg)
                mon.write("Chan:   " .. MESH_CHANNEL)

                -- Reward rate panel
                local baseRate = miner.getCurrentRate()
                local effRate  = math.floor(baseRate * upgrades.getMinerMultiplier())
                -- 3600s/hr ÷ 30s/tick = 120 ticks/hr
                local amiPerHr = effRate * 120 / 1000000

                mon.setCursorPos(1, 8)
                mon.setTextColor(colors.gray)
                mon.write(string.rep("-", mw))

                mon.setCursorPos(1, 9)
                mon.setTextColor(tc.fg)
                mon.write(string.format("Rate:   %d uAMI/tk", effRate))

                mon.setCursorPos(1, 10)
                mon.setTextColor(tc.fg)
                mon.write(string.format("      = %.4f AMI/hr", amiPerHr))

                -- Lag indicator
                mon.setCursorPos(1, 11)
                if lag < 0.7 then
                    mon.setTextColor(colors.red)
                    mon.write(string.format("LAG:    ~%.0f%% TPS", lag * 100))
                else
                    mon.setTextColor(colors.green)
                    mon.write("TPS:    OK")
                end

                -- Active upgrades panel (only shown if any upgrades are purchased)
                local upLines = upgrades.getActiveSummary()
                if #upLines > 0 then
                    local _, mh = mon.getSize()
                    mon.setCursorPos(1, 12)
                    mon.setTextColor(colors.gray)
                    mon.write(string.rep("-", mw))
                    mon.setCursorPos(1, 13)
                    mon.setTextColor(colors.yellow)
                    mon.write("Upgrades active:")
                    local ur = 14
                    for _, line in ipairs(upLines) do
                        if ur > mh then break end
                        mon.setCursorPos(1, ur)
                        mon.setTextColor(tc.fg)
                        mon.write(line:sub(1, mw))
                        ur = ur + 1
                    end
                end
            end)
        end
        os.sleep(sleepSec)
    end
end

-- ── Main ─────────────────────────────────────────────────────────────────────
local function main()
    term.clear()
    term.setCursorPos(1, 1)
    print("===========================================")
    print("  AmiCoin Node v" .. NODE_VERSION)
    print("  Proof-of-Uptime Consensus")
    print("===========================================")

    local nodeKey      = loadOrCreateNodeKey()
    local setupPassword = loadOrCreateSetupPassword()
    nodeFingerprint = computeNodeFingerprint()
    print("")
    print("[!] Node XTEA Key (share with wallets during setup):")
    print("    " .. nodeKey)
    print("[!] Fingerprint: " .. nodeFingerprint)
    if setupPassword and #setupPassword > 0 then
        print("[!] Setup password active - wallets can auto-fetch key.")
    end
    print("")

    local router = findRouter()
    if not router then
        error("No Ender Router peripheral found!  Attach one and reboot.", 0)
    end
    router.open(MESH_CHANNEL)
    print("[Net] Ender Router opened on channel " .. MESH_CHANNEL)
    router.open(SHOP_CHANNEL)
    print("[Net] Shop channel (" .. SHOP_CHANNEL .. ") opened for upgrade invoices.")

    -- Genesis Protocol: broadcast boot signature if upgrade is purchased
    local genSig = upgrades.getGenesisSignature()
    if genSig then
        router.transmit(MESH_CHANNEL, MESH_CHANNEL,
            textutils.serialiseJSON({type="GENESIS", msg=genSig}))
        print("[Genesis] Broadcast: " .. genSig)
    end

    -- Grandfathered upgrades: log retired upgrades the node still owns.
    local grandfathered = upgrades.getGrandfatheredSummary()
    if #grandfathered > 0 then
        print("[Upgrades] Grandfathered (retired from shop, effects still active): "
            .. table.concat(grandfathered, ", "))
    end

    -- Smart Cache Aggregator: configure ledger flush interval from upgrade level
    ledger.setFlushDelay(upgrades.getSmartCacheDelay())

    print("[Tip] Press U at any time to update from GitHub.")
    print("[Tip] Press P to open the Node Upgrade Shop.")
    do
        local ok, res = pcall(http.get,
            "https://raw.githubusercontent.com/Teru-dot-png/amicoin-fullpower/refs/heads/main/reward_rate.txt")
        if ok and res then
            local n = tonumber((res.readAll():gsub("%s","")))
            res.close()
            if n and n >= 1 and n <= 100000 then
                print(string.format("[Rate] Live reward rate: %d uAMI/tick (from GitHub)", n))
            else
                print("[Rate] Could not parse remote rate -- using compiled default")
            end
        else
            print("[Rate] GitHub unreachable -- using compiled default")
        end
    end
    local monAttached = peripheral.find("monitor") ~= nil
    print("[Mon] Monitor: " .. (monAttached and "found" or "not found"))

    -- Run all coroutines in parallel; all loop forever.
    parallel.waitForAll(
        function() miner.run() end,
        function() statusLoop() end,
        function()
            print("[Net] Listening for wallet packets...")
            while true do
                local event, side, senderChan, replyChan, rawMsg = os.pullEvent("modem_message")
                if rawMsg and type(rawMsg) == "string" then
                    local sep = rawMsg:find("|")
                    if sep then
                        local senderKey = rawMsg:sub(1, sep - 1)
                        local cipher    = rawMsg:sub(sep + 1)
                        if #senderKey == 32 then
                            handlePacket(nodeKey, setupPassword, router, senderKey, cipher, replyChan)
                        else
                            print("[Net] Ignored: bad wire format (key=" .. #senderKey .. " chars)")
                        end
                    else
                        print("[Net] Ignored: no | separator in message")
                    end
                end
            end
        end,
        function() monitorLoop(nodeKey) end,
        function()
            -- Peripheral watchdog: reboot if Ender Router disconnects.
            -- A missing peripheral makes any method call throw; pcall catches it.
            while true do
                os.sleep(30)
                local alive = pcall(function() return router.isOpen(MESH_CHANNEL) end)
                if not alive then
                    print("[Watchdog] Ender Router lost! Rebooting in 5s...")
                    os.sleep(5)
                    os.reboot()
                end
            end
        end,
        function()
            while true do
                local _, key = os.pullEvent("key")
                if key == keys.u then selfUpdate()
                elseif key == keys.p then upgrades.runUpgradeFlow(router) end
            end
        end
    )
end

main()
