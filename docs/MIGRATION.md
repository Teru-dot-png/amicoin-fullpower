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

Reboot the Pad. The Wallet App will launch automatically.

---

## Step 3 — Import Your Key

On the Welcome screen of the new Pad:

1. Press **`[2]`** — *Import existing key*.
2. Type in your 32-character Secret Key exactly as it appears (lowercase hex, no spaces).
3. Press Enter.

The app will derive your public address from the key and confirm the import.

---

## Step 4 — Enter the Node Key

When prompted, enter the 32-character **Node XTEA Key** (displayed on the node computer when it first booted). This is required so the Pad can decrypt replies from the node.

If you have lost the node key, reboot the node — it will print the stored key again on startup.

---

## Step 5 — Verify Your Balance

On the Dashboard, press **`[R]`** to refresh your balance. Your full coin balance will be restored from the node's ledger.

---

## Using the Same Key on Multiple Pads

Running the same Secret Key on more than one Pad is **supported** — all Pads will share the same wallet address and balance. However:

- Each active Pad sends its own heartbeats, but the node de-duplicates by address — you earn uptime rewards once per address, not once per Pad.
- Sending a transfer from one Pad while another Pad is also online is safe; the ledger is authoritative on the node.

---

## Frequently Asked Questions

**Q: I lost my Pad and never wrote down my key. Can I recover my wallet?**

No. The Secret Key is generated locally on the Pad and is never sent to the node. If the Pad is lost, destroyed, and you have no backup, the funds in that wallet are permanently inaccessible. This is why the app prominently displays the key immediately after creation and provides the Export menu.

**Q: Can I change my Secret Key?**

Not directly — the public address is derived from the key, so changing the key means changing your address. To effectively "rotate" your key, send all your funds from the old address to a freshly generated new address, then abandon the old key.

**Q: Is it safe to type my key into the Import screen?**

The key is entered through a password-masked input (`read("*")`), so it will not be visible on screen. Ensure no one is watching your physical screen when entering it.
