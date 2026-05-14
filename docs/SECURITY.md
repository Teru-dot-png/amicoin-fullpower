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

The plaintext key prefix tells the node which key to attempt decryption with, without exposing sensitive material — an attacker cannot reverse the encryption from the key prefix alone without also producing valid ciphertext, which requires knowing the full key.

### Targeted Routing

Every packet includes a `targetKey` hint containing the first 8 characters of the intended node's key. Nodes drop packets whose key does not start with that prefix. This prevents nodes from attempting to decrypt packets meant for other nodes on the same mesh.

### What XTEA Protects Against

| Threat | Protected? | Notes |
|--------|-----------|-------|
| Passive eavesdropping on the mesh | ✅ Yes | Encrypted payloads reveal nothing without the key |
| Replay attacks | ⚠️ Partial | Nonce fields in BALANCE/TRANSFER packets help; the node does not maintain a full nonce log |
| Forged transactions | ✅ Yes | Only the key-holder can produce valid ciphertext for their address |
| Node key compromise | ⚠️ Partial | An attacker with the node key can read replies but cannot forge wallet transactions |
| Packet routing misdirection | ✅ Yes | `targetKey` hint + node-side prefix check prevents cross-node confusion |

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
- Your **public address** is deterministically derived from it (64-byte SHA-512-style derivation → 128 hex chars).
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

The node's own XTEA key (used to encrypt replies) is stored in `/data/node_key.txt`. This key is less sensitive — it only protects reply confidentiality — but you should still avoid broadcasting it unnecessarily. You can rotate it by deleting the file and rebooting; all Pads will need their node key updated via the Node Manager.

---

## Session Security

The auto-login session token is stored in `/wallet_data/session.dat`. It is encrypted using a key derived from the computer's hardware ID (`os.getComputerID()`), so the token is non-transferable between devices. Even if another player copies the file, they cannot use it on a different Pad. The session does not contain your Secret Key — it contains only the data needed to restore the dashboard state.

Press **`[L]`** (Logout) to invalidate and delete the session token at any time.

---

## AmiVault Security

AmiVault locks are enforced server-side on the node. The node uses `os.epoch("utc")` for unlock time comparisons. Because CC:Tweaked computers derive time from the server clock, a player cannot bypass a vault lock by manipulating their local clock — the check happens on the node, not the Pad.

Locked funds cannot be transferred, even if the wallet address is known, because the node rejects any TRANSFER that would reduce the balance below the sum of all active vault locks for that address.

---

## Recommended Practices

- **Chunk-load your node** to ensure continuous uptime and consistent reward delivery.
- **Keep your Pad in your inventory** and out of public display cases.
- **Back up your Secret Key** using **`[E] Export / View Key`** on the dashboard before you lose or reset the Pad.
- **Verify install fingerprints** after every fresh install or self-update.
- **Rotate the node key** periodically by deleting `/data/node_key.txt` on the node and rebooting; update all Pads via **`[N]` → edit node** with the new key.
