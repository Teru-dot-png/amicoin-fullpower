# Wallet Migration Guide

This guide explains how to move your AmiCoin wallet to a new Ender Router Pad — for example, when you get a new Pad, lose your old one, or want to use the same wallet on multiple Pads simultaneously.

---

## Core Concept

Your wallet **is** your Secret Key. The Ender Router Pad itself is just a terminal. As long as you have your 32-character Secret Key, you can recover your full wallet — including your entire balance — on any Pad on the network.

Your balance lives on the **node's ledger**, not on your Pad. The Pad only holds the key.

---

## Step 1 — Export Your Key from the Old Pad

If your old Pad is still accessible:

1. Launch the Wallet App (it should start automatically on boot).
2. Log in if prompted.
3. On the Dashboard, press **`[E]`** — *Export / View Key*.
4. Your 32-character Secret Key will be displayed in two lines of 16 characters.
5. **Write it down by hand** or memorise it. Do not type it into chat or a public terminal.

If your old Pad is lost or destroyed but you have a written backup of the key, proceed directly to Step 2.

---

## Step 2 — Install the Wallet App on the New Pad

On the new Ender Router Pad, run the installer:

```
wget run https://raw.githubusercontent.com/Teru-dot-png/amicoin-fullpower/refs/heads/main/installpad.lua
```

The installer will print a per-file hash and a combined **install fingerprint** when it finishes. You can compare this fingerprint against the value published on the GitHub repository to confirm the files were not altered in transit. Reboot the Pad. The Wallet App launches automatically.

---

## Step 3 — Import Your Key

On the Welcome screen of the new Pad:

1. Press **`[2]`** — *Import existing key*.
2. Type in your 32-character Secret Key exactly as it appears (lowercase hex, no spaces).
3. Press Enter.

The app will derive your public address from the key and confirm the import.

---

## Step 4 — Configure Your Nodes

When prompted, add at least one **Node XTEA Key** (the 32-character key displayed on the node computer when it first booted). If you have lost the node key, reboot the node — it prints the stored key again on startup.

You can manage nodes at any time from the Dashboard by pressing **`[N]`**. Multiple nodes can be added; the wallet aggregates your balance across all of them and shows per-node latency on the Glass Cockpit.

---

## Step 5 — Verify Your Balance

On the Dashboard, press **`[R]`** to refresh. Your balance is fetched from all configured nodes and the total is displayed. Per-node balances appear in the node table below the total.

---

## What Transfers with the Key

| Data | Stored on node | Stored on Pad | Migrates with key? |
|------|---------------|---------------|--------------------|
| Coin balance | ✅ Yes | ❌ No | ✅ Automatically |
| Registered player name | ✅ Yes | ❌ No | ✅ Automatically |
| AmiVault locks | ✅ Yes | ❌ No | ✅ Automatically |
| Node list | ❌ No | ✅ Yes (`/wallet_data/nodes.json`) | ⚠️ Re-enter manually |
| Ami-DNS name cache | ❌ No | ✅ Yes (`/wallet_data/names_cache.json`) | ⚠️ Rebuilt automatically over time |
| Auto-login session | ❌ No | ✅ Yes (hardware-bound) | ❌ New session created on first login |

---

## Using the Same Key on Multiple Pads

Running the same Secret Key on more than one Pad is **supported** — all Pads share the same wallet address and balance. However:

- Each active Pad sends its own heartbeats, but the node de-duplicates by address — you earn uptime rewards once per address, not once per Pad.
- Sending a transfer from one Pad while another Pad is also online is safe; the ledger is authoritative on the node.
- Each Pad maintains its own node list and Ami-DNS cache independently.

---

## Frequently Asked Questions

**Q: I lost my Pad and never wrote down my key. Can I recover my wallet?**

No. The Secret Key is generated locally on the Pad and is never sent to the node. If the Pad is lost, destroyed, and you have no backup, the funds in that wallet are permanently inaccessible. This is why the app prominently displays the key immediately after creation and provides the Export menu.

**Q: Can I change my Secret Key?**

Not directly — the public address is derived from the key, so changing the key means changing your address. To effectively "rotate" your key, send all your funds from the old address to a freshly generated new address, then abandon the old key.

**Q: Is it safe to type my key into the Import screen?**

The key is entered through a password-masked input (`read("*")`), so it will not be visible on screen. Ensure no one is watching your physical screen when entering it.

**Q: My AmiVault locks did not show up after migrating. What do I do?**

AmiVault data is stored on the node's ledger and is tied to your address, not your Pad. Press **`[V]`** on the Dashboard and the vault screen will fetch them from the node automatically. If vaults are missing, confirm the node key is correct and press Refresh.

**Q: Do I need to re-register my player name after migrating?**

No. Your name is registered on the node's ledger against your address. As long as you import the same Secret Key (which derives the same address), your name is automatically associated on the node side. The new Pad will cache your name locally the first time it appears in a lookup or heartbeat response.
