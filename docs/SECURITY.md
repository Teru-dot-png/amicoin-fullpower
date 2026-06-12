# Security Model

## XTEA Encryption

AmiCoin uses the **XTEA (eXtended Tiny Encryption Algorithm)** cipher to protect all packets sent across the Ender Router mesh.

### What Is XTEA?

XTEA is a 64-bit block cipher that operates on a 128-bit key with 32 Feistel-style rounds. It was designed as a lightweight, easy-to-implement alternative to Blowfish — making it an ideal fit for the constrained Lua environment of CC:Tweaked, where code size and execution speed matter.

```
Block size : 64 bits (two 32-bit halves)
Key size   : 128 bits (four 32-bit words)
Rounds     : 32
Delta      : 0x9E3779B9 (derived from the golden ratio)
```

Each AmiCoin packet is serialised as JSON, XTEA-encrypted with the sender's 128-bit Secret Key, then hex-encoded before transmission. The wire format is:

```
<senderKeyHex (32 chars)>|<ciphertextHex>
```

> **Important:** The full 32-character Secret Key is transmitted in plaintext as the prefix of every packet. This is by architectural design — the node must know which key to use for decryption. It means that **any observer on the Ender Router mesh can read all packet contents and impersonate any wallet whose traffic they have seen.** AmiCoin's encryption provides privacy against passive third-party eavesdroppers on *other* channels, but not against an active attacker monitoring channel 1337. In the friendly Minecraft server context this is an accepted trade-off. Do not rely on XTEA for strong identity guarantees.

### Targeted Routing

Every packet includes a `targetKey` hint containing the first 8 characters of the intended node's key. Nodes drop packets whose key does not start with that prefix. This prevents nodes from attempting to decrypt packets meant for other nodes on the same mesh.

### What XTEA Protects Against

| Threat | Protected? | Notes |
|--------|-----------|-------|
| Passive eavesdropping on the mesh | ⚠️ Partial | Full secret key travels in plaintext wire prefix; determined attacker on ch 1337 can read all traffic |
| Replay attacks | ⚠️ Partial | Nonce fields in BALANCE/TRANSFER packets help; the node does not maintain a full nonce log |
| Forged transactions by third parties | ✅ Yes | Requires the sender's key, which they must capture from live traffic |
| Node key compromise | ⚠️ Partial | An attacker with the node key can read replies but cannot forge wallet transactions |
| Packet routing misdirection | ✅ Yes | `targetKey` hint + node-side prefix check prevents cross-node confusion |

---

## Node Upgrade State Encryption

The node's upgrade state (`/data/upgrades.json`) is **XTEA-encrypted at rest** using the node's own hardware key (`/data/node_key.txt`).

### Why This Matters

Without encryption, a node operator with filesystem access could manually edit `upgrades.json` to set upgrade levels beyond the legal maximum of 10, granting themselves unlimited mining multipliers, fee rates, or heartbeat windows. Encrypting the file with the node key makes such edits produce garbage that the node rejects on load.

### How It Works

- On every save, `upgrades.lua` serialises the upgrade state to JSON and encrypts it with the node's XTEA key before writing to disk.
- On every load, the file is first decrypted; if decryption fails, it falls back to treating the file as unencrypted plaintext JSON (migration path for nodes upgrading from older software). After a successful boot with the old file it is automatically re-saved in encrypted form.
- Levels are additionally **clamped** to `[0, 10]` on every read, so even a corrupt or tampered file cannot grant out-of-range values.

### Key Durability

The encryption key (`/data/node_key.txt`) is generated once on first boot by `startup.lua` and lives in `/data/`, which is explicitly preserved across `[U]` self-updates and `[F]` Force Update installs. It is only removed by a **Clean Install** (`[I]`), which also wipes all ledger data — in that case `upgrades.json` is wiped too, so there is nothing to decrypt. The upgrade state therefore survives restarts and code updates without any manual intervention.

---

## Source Verification

### The Problem

When you run an installer or self-update via `http.get`, the downloaded Lua code executes directly on your computer. A compromised CDN, DNS spoofing attack, or repository tampering could substitute malicious code in place of a legitimate file.

### FNV-1a Hash Check

Both installers (`installnode.lua`, `installpad.lua`) and both self-update functions compute an **FNV-1a 32-bit hash** of every downloaded file immediately after the HTTP response is received and before writing it to disk.

```
FNV-1a 32-bit:
  offset basis : 2166136261
  prime        : 16777619
  operation    : hash = (hash XOR byte) * prime   (mod 2^32)
```

Two checks are applied to each file:

1. **Minimum-size guard** — Any response shorter than 64 bytes is rejected as a likely HTTP 404 error page saved as content. The file is not written.
2. **Hash display** — The 8-character hex hash of each file is printed inline, e.g. `startup.lua OK [a3f9b2c1]`.

After all files are downloaded, a **combined fingerprint** is computed by hashing the concatenation of all per-file hashes (joined by `:`). This single value is printed as the **install fingerprint**.

### Verifying the Fingerprint

Compare the printed fingerprint against the value published on the GitHub repository page for the current release:

```
github.com/Teru-dot-png/amicoin-fullpower
```

If the values match, all downloaded files are byte-for-byte identical to the published source. If they differ, do not reboot — delete the installed files and investigate before running the node or wallet.

### Limitations

FNV-1a is a non-cryptographic hash. It provides strong accidental-corruption detection and makes opportunistic tampering detectable, but a determined attacker who knows the expected hash values could craft a colliding payload. For the threat model of a Minecraft mod environment this is an adequate safeguard. Users who require cryptographic integrity should verify the SHA-256 of the installer scripts out-of-band before running them.

---

## The Secret Key

Your **Secret Key** is a 128-bit (32 hexadecimal character) random value generated on first wallet creation.

### Why It Matters

- It is the **sole master credential** for your wallet.
- It is used to encrypt every packet your Pad sends.
- Your **public address** is deterministically derived from it (128-bit key expanded to 64 bytes via two-pass XOR/multiply mixing → 128 hex chars).
- Anyone who obtains your Secret Key can impersonate you on the network, send your funds, and earn your uptime rewards.

### Rules for the Secret Key

1. **Never share it.** Not with friends, not in screenshots, not in chat.
2. **Write it down on paper.** Store the paper somewhere physically secure.
3. **Do not store it in plain text files you share** (e.g., do not paste it into a pastebin, Discord message, or screenshot).
4. **Your Pad stores the key in `/wallet_data/secret.key`** — do not give other players access to your Pad's filesystem.

### What the Node Knows

The node **never** stores or logs Secret Keys. It only stores:
- Public wallet addresses (128-character hex strings).
- Coin balances associated with those addresses.
- Registered player names mapped to addresses.
- AmiVault lock records (address, amount, expiry timestamp).

The node's own XTEA key (used to encrypt replies and protect upgrade state) is stored in `/data/node_key.txt`. This key is more sensitive than in older versions — it now also encrypts the upgrade state. You should avoid broadcasting it unnecessarily. You can rotate it by deleting the file and rebooting; all Pads will need their node key updated via the Node Manager, and the upgrade file will be re-encrypted with the new key on next boot.

---

## Name Registry Protections

### GOSSIP_DNS Hijack Prevention

The Ami-DNS system lets wallets gossip known name↔address mappings to other nodes. This is intentionally limited: a wallet can only gossip a name if that name is **not already registered** on the target node, or if the gossiped address **exactly matches** the existing registration.

This means a malicious wallet cannot send `GOSSIP_DNS {name="alice", address=attacker}` to redirect Alice's registered name to their own address. Once a name is registered (either by `REGISTER` or by a prior gossip), it is locked to that address and can only be updated by the legitimate owner sending a new `REGISTER` packet signed with their own key.

---

## Consolidation Security

### CONSOLIDATE_IN Receipt Tracking

When a wallet consolidates funds from one node to another (CONSOLIDATE_OUT → CONSOLIDATE_IN), the source node issues a **receipt token** (an FNV-1a hash of the drained amount, nonce, and source node key prefix). The target node now **records every receipt it has processed** in `/data/consolidate_receipts.json`.

If the same receipt arrives a second time — whether from a replay attack or from the wallet mistakenly re-submitting — the node rejects it with `"Receipt already redeemed on this node"` and does not credit any funds.

> **Residual risk:** The receipt does not cryptographically commit to a specific amount on the target node. The first use of a receipt is trusted to carry the correct amount (as reported by the source node in the CONSOLIDATE_OUT response). A wallet that fabricated an inflated amount in its CONSOLIDATE_IN packet on first use would be cheating, but this would require the wallet to have been modified to lie about the drained amount. Receipt replay (sending the same receipt to multiple nodes) is fully prevented.

---

## Session Security

The auto-login session token is stored in `/wallet_data/session.enc`. It is encrypted using a key derived from the computer's hardware ID (`os.getComputerID()`), so the token is non-transferable between devices. Even if another player copies the file, they cannot use it on a different Pad. The session does not contain your Secret Key — it contains only the data needed to restore the dashboard state.

Press **`[L]`** (Logout) to invalidate and delete the session token at any time.

---

## AmiVault Security

AmiVault locks are enforced server-side on the node. The node uses `os.epoch("utc")` for unlock time comparisons. Because CC:Tweaked computers derive time from the server clock, a player cannot bypass a vault lock by manipulating their local clock — the check happens on the node, not the Pad.

Locked funds cannot be transferred, even if the wallet address is known, because the node rejects any TRANSFER that would reduce the balance below zero.

> **Note (known limitation):** The TRANSFER handler does not currently check active vault locks. A wallet that has exactly `X` µAMI locked in a vault could still transfer that `X` away via TRANSFER, leaving the vault unable to return funds on unlock. This is a known bug tracked separately. Vault funds are safest when the wallet maintains headroom above the locked amount.

**Maximum vault duration** is capped at **30 days (2,592,000 seconds)**. This prevents accidental permanent self-lockout from an unreasonably large duration value submitted by a buggy client.

---

## Remote Rate Fetch

The miner daemon fetches the live base reward rate from a remote URL at startup and every 10 ticks. The fetched value is validated to be a number in `[1, 100000]` before use and is **never saved to disk** — only held in memory for the current run. If the fetch fails the node retains the last known value.

> **Note:** If the remote host serving `reward_rate.txt` were compromised, an attacker could push a high rate (up to 100,000 µAMI/tick), significantly inflating rewards until the node operator notices. This is an accepted operational risk for the current deployment model. Node operators who want full control can set `RATE_URL = nil` in `miner_daemon.lua` and manage the rate locally via the `reward_rate.txt` file instead.

---

## Recommended Practices

- **Chunk-load your node** to ensure continuous uptime and consistent reward delivery.
- **Keep your Pad in your inventory** and out of public display cases.
- **Back up your Secret Key** using **`[E] Export / View Key`** on the dashboard before you lose or reset the Pad.
- **Verify install fingerprints** after every fresh install or self-update.
- **Rotate the node key** periodically by deleting `/data/node_key.txt` on the node and rebooting; update all Pads via **`[N]` → edit node** with the new key. After rotation `upgrades.json` is automatically re-encrypted with the new key on the first boot.
- **Never run Clean Install** unless you intend to wipe all ledger data and upgrade state — it permanently destroys `/data/`.

