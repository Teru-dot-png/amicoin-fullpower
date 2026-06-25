-- node/startup.lua
-- AmiCoin Node – entry point for the Advanced Computer + Ender Router anchor.
--
-- Responsibilities:
--   1. Discover and open the Ender Router peripheral.
--   2. Start the Proof-of-Uptime miner daemon in a parallel coroutine.
--   3. Listen for incoming XTEA-encrypted packets on the mesh channel.
--   4. Dispatch verified commands: HEARTBEAT, BALANCE, TRANSFER.
--   5. Display a live status dashboard with Opus UI framework (demon theme).
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

-- Core services
local xtea     = require("xtea")
local ledger   = require("ledger")
local miner    = require("miner_daemon")
local upgrades = require("upgrades")

-- Opus UI framework
local UI       = require('ami.lib.ui.ui')
local Theme    = require('ami.lib.ui.theme')
local Event    = require('ami.lib.ui.event')
local Util     = require('ami.lib.ui.util')
require('ami.lib.ui.widgets.fan')
require('ami.lib.ui.widgets.gauge')

-- Set demon theme
Theme.setTheme('demon')

-- ── Terminal output gate ─────────────────────────────────────────────────────
-- While the Opus dashboard owns the screen, stray print()/io.write() from the
-- background threads (miner ticks, net packets, watchdog) must NOT scroll the
-- terminal (that shoves the Opus canvas upward). Instead, when the dashboard is
-- active we ROUTE every print() into the on-screen "Node Log" panel via logSink.
-- During boot and the text sub-flows ([U]/[P]/[T]/[A]) print goes to the real
-- terminal as normal. Opus itself renders via device.blit, never print().
local uiActive = false
local uiModal  = false  -- an Opus SUB-page (e.g. upgrade shop) owns the screen
local logSink  = nil   -- set to nodeLog() once the dashboard exists
do
    local realPrint   = _G.print
    local realIoWrite = io.write
    _G.print = function(...)
        if uiModal then
            return            -- a modal Opus sub-page is up: swallow background prints
        elseif uiActive then
            if logSink then
                local parts = {}
                for i = 1, select('#', ...) do parts[i] = tostring((select(i, ...))) end
                logSink(table.concat(parts, ' '))
            end
        else
            return realPrint(...)
        end
    end
    io.write = function(...)
        if not uiActive and not uiModal then return realIoWrite(...) end
    end
end
local function setUIActive(on) uiActive = on end
local function setUIModal(on) uiModal = on end

-- ── Configuration ────────────────────────────────────────────────────────────
local MESH_CHANNEL    = 1337          -- Ender Router channel all nodes share
local SHOP_CHANNEL    = 1338          -- Plaintext invoice / PAYMENT_ACK channel
local NODE_VERSION    = "7.4"
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
-- Node service files pulled by the in-node [U] self-update. The COMPLETE Opus UI
-- tree (ami/lib/ui/**) is appended at update time from the committed manifest, so
-- pressing [U] now updates the whole UI - not just these service files.
local UPDATE_FILES = {
    { src="/shared/xtea.lua",        dst="/shared/xtea.lua"   },
    { src="/node/startup.lua",       dst="/startup.lua"       },
    { src="/node/node_ui.lua",       dst="/node_ui.lua"       },
    { src="/node/upgrade_ui.lua",    dst="/upgrade_ui.lua"    },
    { src="/node/amidecode_ui.lua",  dst="/amidecode_ui.lua"  },
    { src="/node/monitor_ui.lua",    dst="/monitor_ui.lua"    },
    { src="/node/ledger.lua",        dst="/ledger.lua"        },
    { src="/node/miner_daemon.lua",  dst="/miner_daemon.lua"  },
    { src="/node/xtea.lua",          dst="/xtea.lua"          },
    { src="/node/upgrades.lua",      dst="/upgrades.lua"      },
}

-- Append the full ami/lib/ui tree from the committed manifest to a file list.
-- Returns count, or nil + error. Shared by the [U] self-update below.
local function appendUiManifest(files)
    local cb  = (os.epoch and os.epoch("utc")) or os.time()
    local ok, res = pcall(http.get, REPO_BASE .. "/ami/lib/ui/manifest.txt?" .. cb)
    if not ok or not res then return nil, "could not fetch ui manifest" end
    local body = res.readAll(); res.close()
    local n = 0
    for line in (body .. "\n"):gmatch("(.-)\n") do
        line = line:gsub("%s+", "")
        if #line > 0 and line:sub(1, 1) ~= "#" then
            files[#files + 1] = { src = line, dst = line }
            n = n + 1
        end
    end
    return n
end

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

    -- Build the full file set: node services + the entire ami/lib/ui tree.
    local files = {}
    for _, e in ipairs(UPDATE_FILES) do files[#files + 1] = e end
    local uiN, uiErr = appendUiManifest(files)
    if uiN then
        print("[Update] UI manifest: " .. uiN .. " files")
    else
        print("[Update] WARNING: " .. tostring(uiErr) .. " - updating services only")
    end

    for _, entry in ipairs(files) do
        io.write("[Update] " .. entry.dst .. " ... ")
        local cb = (os.epoch and os.epoch("utc")) or os.time()
        local ok, res = pcall(http.get, REPO_BASE .. entry.src .. "?" .. cb)
        if ok and res then
            local content = res.readAll()
            res.close()
            if #content < 16 then
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

-- ── Opus UI Dashboard ───────────────────────────────────────────────────────
local dashboardPage = nil  -- Will be created in main()
local nodeUI = nil         -- Main UI page

-- Live "Node Log" shown in the dashboard's right panel. Every print() made while
-- the dashboard is active is routed here (see logSink). Raw messages are kept and
-- WORD-WRAPPED to the panel width on each update, then the last LOG_LINES wrapped
-- lines are shown (newest at the bottom) - so long lines wrap instead of truncate.
local LOG_LINES   = 14
local LOG_WIDTH   = 22          -- inner width of the log panel (cols 2..23)
local LOG_RAW_MAX = 80          -- raw messages retained before wrapping
local logRaw      = {}
local function nodeLog(line)
    logRaw[#logRaw + 1] = tostring(line)
    while #logRaw > LOG_RAW_MAX do table.remove(logRaw, 1) end
    if dashboardPage and uiActive and dashboardPage.logPanel then
        -- Wrap every retained message, flatten, then show the last LOG_LINES.
        local wrapped = {}
        for _, msg in ipairs(logRaw) do
            for _, wl in ipairs(Util.wordWrap(msg, LOG_WIDTH)) do
                wrapped[#wrapped + 1] = wl
            end
        end
        local startIdx = math.max(1, #wrapped - LOG_LINES + 1)
        for i = 1, LOG_LINES do
            local w = dashboardPage.logPanel['logLine' .. i]
            if w then w.value = wrapped[startIdx + i - 1] or '' end
        end
        dashboardPage.logPanel:draw()
        dashboardPage.logPanel:sync()
    end
end
logSink = nodeLog   -- the print() gate now feeds the on-screen log

local function updateDashboard()
    if not dashboardPage then return end
    if not uiActive then return end  -- a sub-flow owns the terminal; don't overdraw

    -- Query current state
    local active = miner.getActive()
    local snap   = ledger.snapshot()
    local total  = 0
    for _, v in pairs(snap) do total = total + v end
    local baseRate = miner.getCurrentRate()
    local effRate  = math.floor(baseRate * upgrades.getMinerMultiplier())
    local amiPerHr = effRate * 120 / 1000000  -- 120 ticks/hr
    
    -- Update stats
    dashboardPage.infoPanel.activeWalletsValue.value = tostring(#active)
    dashboardPage.infoPanel.supplyValue.value = string.format("%.6f AMI", total / 1000000)
    dashboardPage.infoPanel.supplyuAMI.value = string.format("(%d uAMI)", total)
    
    -- Mining rate gauge
    local maxRate = 200  -- Max theoretical rate with all upgrades
    dashboardPage.infoPanel.miningRateGauge.value = math.min(effRate, maxRate)
    dashboardPage.infoPanel.miningRateText.value = string.format("%d uAMI/tk", effRate)
    dashboardPage.infoPanel.ratePerHour.value = string.format("%.4f AMI/hr", amiPerHr)
    
    -- Thermal display
    local netTemp = upgrades.computeNetTemp(true)
    local _, shutoff, _ = upgrades.computeThermalFactor()
    local tempColor = colors.lime
    local tempLabel = "OK"
    
    if shutoff then
        tempColor = colors.red
        tempLabel = "THROTTLED"
    elseif netTemp >= 200 then
        tempColor = colors.orange
        tempLabel = "HOT"
    elseif netTemp >= 100 then
        tempColor = colors.yellow
        tempLabel = "WARM"
    end
    
    -- Compact thermal + cooling status line in the log panel.
    local coolingLevel = upgrades.getAirCoolerLevel()
    local coolStr = coolingLevel > 0 and (" | Cool Lv" .. coolingLevel) or ""
    dashboardPage.logPanel.tempValue.value = string.format("%dC %s%s", netTemp, tempLabel, coolStr)
    dashboardPage.logPanel.tempValue.textColor = tempColor

    -- Lag indicator
    local lag = miner.getLagFactor()
    if lag < 0.7 then
        dashboardPage.infoPanel.lagValue.value = string.format("~%.0f%% (lagging)", lag * 100)
        dashboardPage.infoPanel.lagValue.textColor = colors.red
    else
        dashboardPage.infoPanel.lagValue.value = "OK"
        dashboardPage.infoPanel.lagValue.textColor = colors.lime
    end
    
    -- Update upgrades list.
    -- getActiveSummary() returns lines like "OvrclkMiner  Lv5" (name padded to
    -- 12 chars, then the level/status), NOT "Name (LvN)". Split on the first run
    -- of whitespace: first token = name, remainder = level/status.
    local upgradeData = {}
    local upLines = upgrades.getActiveSummary()
    for _, line in ipairs(upLines) do
        local name, level = line:match("^(%S+)%s+(.+)$")
        if name and level then
            table.insert(upgradeData, {
                name  = name,
                level = (level:gsub("%s+$", "")),
            })
        elseif line:match("%S") then
            table.insert(upgradeData, { name = (line:gsub("%s+$", "")), level = "" })
        end
    end
    dashboardPage.upgradesPanel.upgradesList:setValues(upgradeData)
    
    dashboardPage:draw()
    dashboardPage:sync()
end

-- Lightweight ~1Hz updater for just the mint-countdown bar (the full
-- updateDashboard only runs every 30s, too slow for a 1-second countdown).
local function updateMintBar()
    if not dashboardPage then return end
    if not uiActive then return end
    local progress, remaining = miner.getMintProgress()
    local ip = dashboardPage.infoPanel
    ip.mintBar.value      = math.floor(progress * 100 + 0.5)
    ip.mintCountdown.value = string.format("%ds", math.ceil(remaining))
    ip:draw()
    ip:sync()
end

-- ── Opus Upgrade Shop ([P]) ──────────────────────────────────────────────────
-- A full Opus page (scrolling grid + details + Buy/Back buttons + name field),
-- driven by the node's existing UI:pullEvents loop. The page emits 'shop_buy' /
-- 'shop_close' os events; this blocking flow reacts to them. The actual purchase
-- reuses the existing term-based confirm/payment flow (upgrades.purchaseByIndex).
local function runUpgradeShop(router)
    -- First-run treasury wizard is still a brief term step.
    if upgrades.needsTreasurySetup() then
        setUIActive(false); setUIModal(false)
        term.clear(); term.setCursorPos(1, 1)
        if not upgrades.setupTreasuryFlow() then
            return  -- operator cancelled setup
        end
    end

    local UpgradeUI = require("upgrade_ui")
    local shopPage  = UpgradeUI.createPage(NODE_VERSION)
    UpgradeUI.setCatalog(shopPage, upgrades.getCatalog())

    -- The Opus shop owns the screen: modal so background prints are swallowed
    -- (no scroll, no dashboard overdraw). The main UI:pullEvents loop drives it.
    setUIActive(false)
    setUIModal(true)
    UI:setPage(shopPage)
    shopPage.buyerEntry:focus()

    while true do
        local ev = os.pullEvent()
        if ev == "shop_close" then
            break
        elseif ev == "shop_buy" then
            local idx  = UpgradeUI.selectedIndex(shopPage)
            local name = shopPage.buyerEntry.value
            local addr, clean = upgrades.resolveBuyer(name)
            if not idx then
                shopPage.hint:setStatus("Select an upgrade first")
                shopPage.hint:draw(); shopPage.hint:sync()
            elseif not addr then
                shopPage.hint:setStatus("Enter a valid Ami-DNS name")
                shopPage.hint:draw(); shopPage.hint:sync()
            else
                -- Hand off to the existing term-based purchase/payment flow.
                setUIModal(false)
                term.clear(); term.setCursorPos(1, 1)
                upgrades.purchaseByIndex(router, idx, addr, clean)
                -- Back to the Opus shop with refreshed levels/costs.
                UpgradeUI.setCatalog(shopPage, upgrades.getCatalog())
                setUIModal(true)
                UI:setPage(shopPage)
            end
        end
    end

    -- Leave the shop: hand the screen back to the dashboard.
    setUIModal(false)
    setUIActive(true)
    UI:setPage(dashboardPage)
    updateDashboard()
end

-- ── Status display ───────────────────────────────────────────────────────────
local function statusLoop(textModeOnly, nodeKeyHint)
    while true do
        os.sleep(30)
        ledger.flush()  -- flush any cached ledger writes (Smart Cache safety net)
        
        local active = miner.getActive()
        local snap   = ledger.snapshot()
        local total  = 0
        for _, v in pairs(snap) do total = total + v end
        local lag = miner.getLagFactor()
        
        if textModeOnly then
            -- TEXT MODE: full-screen status update every 30 seconds
            term.clear()
            term.setCursorPos(1, 1)
            print("===========================================")
            print("  AmiCoin Node v" .. NODE_VERSION)
            print("===========================================")
            print("")
            print("Key:    " .. nodeKeyHint:sub(1, 16) .. "...")
            print("Supply: " .. string.format("%.6f AMI", total / 1000000))
            print("        " .. total .. " uAMI")
            print("")
            local rate = math.floor(miner.getCurrentRate() * upgrades.getMinerMultiplier())
            print("Rate:   " .. rate .. " uAMI/tick")
            print("        " .. string.format("%.4f AMI/hr", rate * 120 / 1000000))
            print("")
            print("Active: " .. #active .. " wallet(s)")
            print("")
            if lag < 0.7 then
                print("LAG:    ~" .. string.format("%.0f", lag * 100) .. "% (server lagging)")
            else
                print("TPS:    OK")
            end
            print("")
            print("[U] Update  [P] Upgrade Shop  [A] Admin")
        else
            -- UI MODE: update dashboard and print to log
            updateDashboard()
            local lagStr = lag < 0.7 and string.format(" | LAG %.0f%%", lag * 100) or ""
            print(string.format("[Node] Active: %d | Supply: %d uAMI%s", #active, total, lagStr))
        end
    end
end

-- ── Monitor display ──────────────────────────────────────────────────────────
-- Draws live stats on an attached monitor PLUS the big pre-rendered cooling fan.
-- The (expensive) full stats redraw is throttled; the fan animates a few fps.
-- If no monitor is connected the loop simply sleeps and checks again later.
local function monitorLoop(nodeKey)
    local MonitorUI = nil
    pcall(function() MonitorUI = require('monitor_ui') end)
    local fanIdx    = 1
    local lastStats = -1e9

    while true do
        local lag = miner.getLagFactor()
        local mon = peripheral.find("monitor")
        if mon then
            pcall(function()
                pcall(function() mon.setTextScale(0.5) end)
                local mw, mh = mon.getSize()

                -- Throttle the full stats redraw; the fan animates much faster.
                local statsInterval = (lag < 0.7) and 5 or 15
                local doStats = (os.clock() - lastStats) >= statsInterval

                if doStats then
                    lastStats = os.clock()

                    if MonitorUI then
                        local active   = miner.getActive()
                        local snap     = ledger.snapshot()
                        local total    = 0
                        for _, v in pairs(snap) do total = total + v end
                        local baseRate = miner.getCurrentRate()
                        local effRate  = math.floor(baseRate * upgrades.getMinerMultiplier())
                        local netTemp  = upgrades.computeNetTemp(true)
                        local _, shutoff = upgrades.computeThermalFactor()
                        local coolLv   = upgrades.getAirCoolerLevel()
                                       + upgrades.getLiquidCoolingLevel()
                        local mintProg, mintRem = miner.getMintProgress()

                        -- Parse upgrade summary into {name, level} pairs
                        local upgradeData = {}
                        for _, line in ipairs(upgrades.getActiveSummary()) do
                            local n, l = line:match("^(%S+)%s+(.+)$")
                            if n and l then
                                upgradeData[#upgradeData+1] = {
                                    name  = n,
                                    level = l:gsub("%s+$", ""),
                                }
                            elseif line:match("%S") then
                                upgradeData[#upgradeData+1] = {
                                    name  = line:gsub("%s+$", ""),
                                    level = '',
                                }
                            end
                        end

                        -- Leave room for the fan animation column when it fits
                        local fcW = (MonitorUI and MonitorUI.FAN_COLS > 0
                                     and mw >= 26 + MonitorUI.FAN_COLS)
                                    and MonitorUI.FAN_COLS or 0
                        local statsW = fcW > 0 and (mw - fcW - 1) or mw

                        mon.setBackgroundColor(colors.black)
                        mon.clear()

                        MonitorUI.drawStats(mon, statsW, {
                            version         = NODE_VERSION,
                            theme           = upgrades.getActiveTheme(),
                            nodeKey         = nodeKey,
                            fingerprint     = nodeFingerprint,
                            channel         = MESH_CHANNEL,
                            activeWallets   = #active,
                            totalSupply     = total,
                            effRate         = effRate,
                            lagFactor       = lag,
                            netTemp         = netTemp,
                            thermalShutoff  = shutoff,
                            coolingLevel    = coolLv,
                            mintProgress    = mintProg or 0,
                            mintRemaining   = mintRem  or 30,
                            upgrades        = upgradeData,
                            crownLevel      = upgrades.getCrownLevel(),
                            casinoRakeLevel = upgrades.getCasinoRakeLevel(),
                            priorityPing    = upgrades.hasPriorityPing(),
                            totalTicks      = miner.getTotalTicks(),
                        })
                    end
                end

                -- ── Cooling fan (animated, delegated to MonitorUI) ─────────────
                if MonitorUI then
                    local airLv  = upgrades.getAirCoolerLevel()
                    local liqLv  = upgrades.getLiquidCoolingLevel()
                    local netTemp  = upgrades.computeNetTemp(false)
                    local _, shutoff = upgrades.computeThermalFactor()
                    fanIdx = MonitorUI.drawFan(mon, mw, mh, {
                        coolingLevel   = airLv + liqLv,
                        netTemp        = netTemp,
                        thermalShutoff = shutoff,
                        theme          = upgrades.getActiveTheme(),
                    }, fanIdx)
                end
            end)
        end
        -- Fan playback speed scales with COOLING LEVEL: more cooling power = a
        -- faster spin. No cooler => idle (slow poll). Each level shaves the frame
        -- interval; clamped so it never thrashes the monitor. Backs off on lag.
        local coolLv = upgrades.getAirCoolerLevel() + upgrades.getLiquidCoolingLevel()
        local fanSleep
        if coolLv <= 0 then
            fanSleep = 0.5
        else
            fanSleep = math.max(0.04, 0.13 - coolLv * 0.018)
        end
        os.sleep((lag < 0.7) and fanSleep or 1.0)
    end
end

-- ── Admin recovery menu ([A] key) ───────────────────────────────────────────
-- Provides operator tools for wallet recovery: balance inquiry, force-credit,
-- force-transfer, re-register, and ledger flush.  All actions are logged.
-- Password-protected using the same setup password file.
local ADMIN_LOG = "/data/admin.log"
local function adminLog(msg)
    if not fs.exists("/data") then fs.makeDir("/data") end
    local f = fs.open(ADMIN_LOG, "a")
    f.write("[" .. tostring(os.epoch("utc")) .. "] " .. msg .. "\n")
    f.close()
end

local function adminResolve(input)
    -- Accepts a 128-hex address directly OR an Ami-DNS name.
    -- Returns address (string) or nil, errMsg (string).
    local trimmed = input:gsub("^%s*(.-)%s*$", "%1")
    if #trimmed == 128 and trimmed:match("^%x+$") then
        return trimmed, nil
    elseif #trimmed > 0 then
        local addr = ledger.lookupName(trimmed)
        if addr then return addr, nil end
        return nil, "Name '" .. trimmed .. "' not found in registry."
    end
    return nil, "Empty input."
end

local function adminRead(prompt)
    term.setTextColor(colors.white)
    io.write(prompt)
    return (read() or ""):gsub("^%s*(.-)%s*$", "%1")
end

local function adminMenu(setupPassword)
    -- Password gate: require the setup password if one is set.
    if type(setupPassword) == "string" and #setupPassword > 0 then
        term.setTextColor(colors.yellow)
        print("\n[Admin] Enter setup password to continue:")
        io.write("  > ")
        local pw = read("*")
        if pw ~= setupPassword then
            term.setTextColor(colors.red)
            print("[Admin] Wrong password.")
            term.setTextColor(colors.white)
            os.sleep(1)
            return
        end
    end

    while true do
        term.setBackgroundColor(colors.black)
        term.setTextColor(colors.yellow)
        term.clear(); term.setCursorPos(1,1)
        print("===========================================")
        print("  AmiCoin Node -- Admin Recovery Menu")
        print("===========================================")
        term.setTextColor(colors.white)
        print("  [1] Balance inquiry     (name or address)")
        print("  [2] Force transfer      (address -> address)")
        print("  [3] Re-register wallet  (create zero-balance entry)")
        print("  [4] Flush ledger        (force write cached ledger)")
        print("  [5] List all balances   (snapshot dump)")
        print("  [B] Exit admin menu")
        term.setTextColor(colors.gray)
        print("")
        io.write("  Choice > ")
        local choice = (read() or ""):gsub("%s","")

        if choice == "b" or choice == "B" then
            break

        elseif choice == "1" then
            -- Balance inquiry
            local inp = adminRead("  Name or address > ")
            local addr, err = adminResolve(inp)
            if not addr then
                term.setTextColor(colors.red); print("  " .. err)
            else
                local bal = ledger.getBalance(addr)
                local name = ledger.getNameByAddress(addr) or "(unregistered)"
                term.setTextColor(colors.lime)
                print(string.format("  Name:    %s", name))
                print(string.format("  Address: %s...", addr:sub(1,24)))
                print(string.format("  Balance: %d uAMI  (%.6f AMI)", bal, bal/1e6))
                adminLog(string.format("INQUIRY addr=%s name=%s bal=%d", addr:sub(1,16), name, bal))
            end
            term.setTextColor(colors.gray); print("  [Enter] continue"); read()

        elseif choice == "2" then
            -- Force transfer (no signature required — operator action)
            local fromInp = adminRead("  FROM name/address > ")
            local from, e1 = adminResolve(fromInp)
            if not from then
                term.setTextColor(colors.red); print("  " .. e1); os.sleep(1)
            else
                local toInp = adminRead("  TO name/address   > ")
                local to, e2 = adminResolve(toInp)
                if not to then
                    term.setTextColor(colors.red); print("  " .. e2); os.sleep(1)
                else
                    local amtStr = adminRead("  Amount (AMI, M=all) > ")
                    local uami
                    if amtStr:lower() == "m" then
                        uami = ledger.getBalance(from)
                    else
                        local n = tonumber(amtStr)
                        uami = n and math.floor(n * 1e6) or 0
                    end
                    if uami <= 0 then
                        term.setTextColor(colors.red); print("  Zero or invalid amount."); os.sleep(1)
                    else
                        local ok, errMsg = ledger.transfer(from, to, uami)
                        if ok then
                            term.setTextColor(colors.lime)
                            print(string.format("  Transferred %d uAMI OK.", uami))
                            adminLog(string.format("FORCE_XFER from=%s to=%s amount=%d", from:sub(1,16), to:sub(1,16), uami))
                        else
                            term.setTextColor(colors.red)
                            print("  Failed: " .. (errMsg or "?"))
                        end
                        term.setTextColor(colors.gray); print("  [Enter] continue"); read()
                    end
                end
            end

        elseif choice == "3" then
            -- Re-register (creates zero-balance entry if missing)
            local inp = adminRead("  Address (128 hex) > ")
            local addr, err = adminResolve(inp)
            if not addr then
                term.setTextColor(colors.red); print("  " .. err); os.sleep(1)
            else
                local isNew = ledger.register(addr)
                term.setTextColor(isNew and colors.lime or colors.yellow)
                print(isNew and "  Registered new entry." or "  Already exists (no change).")
                adminLog(string.format("REREGISTER addr=%s new=%s", addr:sub(1,16), tostring(isNew)))
                term.setTextColor(colors.gray); print("  [Enter] continue"); read()
            end

        elseif choice == "4" then
            -- Flush ledger cache to disk immediately
            ledger.flush()
            term.setTextColor(colors.lime); print("  Ledger flushed to disk.")
            adminLog("LEDGER_FLUSH operator=admin")
            os.sleep(0.8)

        elseif choice == "5" then
            -- Snapshot dump: list all addresses with non-zero balance
            local snap = ledger.snapshot()
            local entries = {}
            for addr, bal in pairs(snap) do
                if bal > 0 then entries[#entries+1] = {addr=addr, bal=bal} end
            end
            table.sort(entries, function(a,b) return a.bal > b.bal end)
            term.setTextColor(colors.white)
            print(string.format("  %d entries with balance:", #entries))
            for i, e in ipairs(entries) do
                local name = ledger.getNameByAddress(e.addr) or ""
                local nameStr = #name > 0 and (" (" .. name .. ")") or ""
                term.setTextColor(colors.lightGray)
                print(string.format("  %s...%s  %d uAMI",
                    e.addr:sub(1,12), nameStr, e.bal))
                if i >= 20 then
                    term.setTextColor(colors.gray)
                    print(string.format("  ... %d more (truncated)", #entries - 20))
                    break
                end
            end
            term.setTextColor(colors.gray); print("  [Enter] continue"); read()
        end
    end

    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
    term.clear(); term.setCursorPos(1,1)
    print("[Admin] Returned to node shell.")
    print("[Tip] Press U to update  |  P for Upgrade Shop  |  A for Admin")
end

-- ── Main ─────────────────────────────────────────────────────────────────────
local function main()
    -- Boot message (briefly shown before UI takes over)
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

    -- Live reward rate (informational print only)
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
            print("[Rate] Could not reach GitHub -- using compiled default")
        end
    end

    -- ── Opus UI bootstrap ────────────────────────────────────────────────────
    -- Strategic fix (studied from upstream kepler155c/opus):
    --   * disableEffects() makes Device:sync() skip runTransitions(), whose
    --     `while true ... os.sleep(0)` loop is what hung forever ("zombie UI").
    --   * setPage()/pullEvents() are the real Opus API; no hand-rolled init.
    print("[Tip] Initializing Opus UI dashboard...")
    print("[Tip] Press U to update  |  P for Upgrade Shop  |  T for AMIdecode  |  A for Admin")
    local nodeUI = require("node_ui")
    UI:disableEffects()
    dashboardPage = nodeUI.createDashboard(nodeKey, NODE_VERSION)
    UI:setPage(dashboardPage)
    -- Dashboard now owns the screen: silence background print()/io.write() so
    -- they stop scrolling the Opus canvas. (updateDashboard requires uiActive.)
    setUIActive(true)
    updateDashboard()

    parallel.waitForAll(
        -- Proof-of-Uptime miner
        function()
            miner.run()
        end,
        -- Live stats refresh (drives updateDashboard every 30s)
        function()
            statusLoop(false, nodeKey)
        end,
        -- Mint countdown bar (~1Hz; just the infoPanel, cheap)
        function()
            while true do
                os.sleep(1)
                updateMintBar()
            end
        end,
        -- Opus UI event loop (mouse clicks, hovers, redraws)
        function()
            UI:pullEvents()
        end,
        -- Encrypted mesh packet handler
        function()
            while true do
                local _, _, _, replyChan, rawMsg = os.pullEvent("modem_message")
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
                    end
                end
            end
        end,
        -- External monitor mirror
        function()
            monitorLoop(nodeKey)
        end,
        -- Ender Router watchdog
        function()
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
        -- Footer actions (U/P/T/A keys AND footer-button clicks). Footer buttons
        -- queue an 'ami_action' event (see node_ui), so mouse and keyboard share
        -- ONE dispatch path here. Sub-flows take over the terminal, then return to
        -- the dashboard via setPage(); setUIActive toggles text vs UI output.
        function()
            local function runAction(action)
                if action == 'p' then
                    -- The Opus upgrade shop manages its own screen state and
                    -- returns to the dashboard itself.
                    runUpgradeShop(router)
                    return
                end
                setUIActive(false)
                term.clear(); term.setCursorPos(1, 1)
                if action == 'u' then
                    selfUpdate()                 -- reboots on success
                elseif action == 't' then
                    upgrades.runAmdMinigame()
                elseif action == 'a' then
                    adminMenu(setupPassword)
                end
                UI:setPage(dashboardPage)
                setUIActive(true)
                updateDashboard()
            end
            while true do
                local ev, a = os.pullEvent()
                if ev == 'key' then
                    if     a == keys.u then runAction('u')
                    elseif a == keys.p then runAction('p')
                    elseif a == keys.t then runAction('t')
                    elseif a == keys.a then runAction('a')
                    end
                elseif ev == 'ami_action' then
                    runAction(a)
                end
            end
        end
    )
end

main()
