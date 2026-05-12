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

The plaintext key prefix is intentional: it tells the node *which* key to attempt decryption with, without exposing the key's sensitive material (since an attacker cannot reverse the encryption from the key alone without the ciphertext — and cannot forge ciphertext without knowing the key).

### What XTEA Protects Against

| Threat | Protected? | Notes |
|--------|-----------|-------|
| Passive eavesdropping on the mesh | ✅ Yes | Encrypted payloads reveal nothing without the key |
| Replay attacks | ⚠️ Partial | Nonce fields in BALANCE/TRANSFER packets help; the node does not yet maintain a nonce log |
| Forged transactions | ✅ Yes | Only the key-holder can produce valid ciphertext for their address |
| Node key compromise | ⚠️ Partial | An attacker with the node key can read replies but cannot forge wallet transactions |

---

## The Secret Key

Your **Secret Key** is a 128-bit (32 hexadecimal character) random value generated on first wallet creation.

### Why It Matters

- It is the **sole master credential** for your wallet.
- It is used to encrypt every packet your Pad sends.
- Your **public address** is deterministically derived from it.
- Anyone who obtains your Secret Key can impersonate you on the network, send your funds, and earn your uptime rewards.

### Rules for the Secret Key

1. **Never share it.** Not with friends, not in screenshots, not in chat.
2. **Write it down on paper.** Store the paper somewhere physically secure.
3. **Do not store it in plain text files you share** (e.g., do not paste it into a pastebin, Discord message, or screenshot).
4. **Your Pad stores the key in `/wallet_data/secret.key`** — do not give other players access to your Pad's filesystem.

### What the Node Knows

The node **never** stores or logs Secret Keys. It only stores:
- Public wallet addresses (64-character hex strings).
- Coin balances associated with those addresses.

The node's own XTEA key (used to encrypt replies) is stored in `/data/node_key.txt` on the node computer. This key is less sensitive — it only protects reply confidentiality — but you should still avoid broadcasting it unnecessarily.

---

## Recommended Practices

- **Chunk-load your node** to ensure continuous uptime and consistent reward delivery.
- **Keep your Pad in your inventory** and out of public display cases.
- **Back up your Secret Key** using the `[E] Export / View Key` option on the wallet dashboard before you lose or reset the Pad.
- **Rotate the node key** periodically by deleting `/data/node_key.txt` on the node and rebooting; re-enter the new key on all Pads.
