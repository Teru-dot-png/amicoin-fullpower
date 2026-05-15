# AmiStore Merchant Manual

**AmiStore v1.1** — A secure, AE2-integrated marketplace for the AmiCoin mesh network.

AmiStore turns an Advanced Computer into a fully automated shopfront. It reads your AE2 digital storage, lists items for sale (WTS) or purchase (WTB), verifies buyers via XTEA-encrypted handshake, commits transactions atomically to the AmiCoin ledger, and optionally prints physical receipts.

---

## Table of Contents

1. [Hardware Layout](#hardware-layout)
2. [Installation](#installation)
3. [First Boot](#first-boot)
4. [Listings Format](#listings-format)
5. [Config Format](#config-format)
6. [Transaction Pipelines](#transaction-pipelines)
7. [Admin Dashboard](#admin-dashboard)
8. [Receipts & Physical Audit Trail](#receipts--physical-audit-trail)
9. [Structured Logging](#structured-logging)
10. [Merchant Node Identity](#merchant-node-identity)
11. [Vault Sweep](#vault-sweep)
12. [Buyer / Seller Protocol](#buyer--seller-protocol)
13. [Troubleshooting](#troubleshooting)

---

## Hardware Layout

AmiStore uses **hardcoded sides**. Place peripherals exactly as shown:

| Side | Peripheral | Role |
|------|-----------|------|
| **TOP** | 3×3 Advanced Monitor | Glass Cockpit display — storefront & admin UI |
| **LEFT** | Printer | Physical receipt output (optional but recommended) |
| **RIGHT** | ME Bridge (AE2CC) | Digital inventory link — reads stock, exports/imports items |
| **BOTTOM** | Chest or Barrel | Physical vending tray — items land here on sale, sellers place items here to sell |
| **BACK** | Wired or Wireless Modem | XTEA-encrypted mesh comms for AmiCoin transactions |
| **FRONT** | *(nothing)* | Player interaction zone |

> **All six sides are detected at boot.** Missing peripherals degrade gracefully — the shop continues operating with reduced functionality. The log reports which peripherals are offline.

### Without AE2

If no ME Bridge is on the RIGHT side, stock is always reported as `0` for WTS listings and imports are skipped for WTB listings. You can still run WTB-only shops (player deposits items into the BOTTOM chest manually) or configure WTS listings and restock the tray manually.

---

## Installation

Run the installer on the Merchant Node computer:

```
wget run https://raw.githubusercontent.com/Teru-dot-png/amicoin-fullpower/refs/heads/main/InstallShop.lua
```

The installer will:

1. **Check all six peripheral sides** and report what is present vs. missing.
2. Download `shared/xtea.lua`, `shop_api.lua`, `shop_ui.lua`, and `startup.lua` from GitHub.
3. Verify each file with an FNV-1a fingerprint. A combined install fingerprint is printed at the end — compare it against the checksum published on GitHub.
4. Write **template** `listings.json` and `config.json` if they do not already exist.
5. Optionally write `/startup.lua` to auto-start AmiStore on reboot (backs up any existing startup).

---

## First Boot

```
/ami/shop/startup
```

On first boot the terminal displays:

```
============================================
  AmiStore v1.1  —  Merchant Node Boot
============================================
Initialising peripherals...
  Shop address : 3f8a1b2c...
  Monitor      : TOP [OK]
  meBridge     : RIGHT [OK]
  Printer      : LEFT [OK]
  Inventory    : BOTTOM [OK]
  Modem        : BACK [OK]

Admin session token (keep private):
  a3f91c2d

Loaded 4 listing(s).
Starting in 3 seconds...
```

**Write down the admin session token.** It is hardware-bound (derived from the computer ID and a persistent UUID) and is required to enter the Admin Dashboard. It never changes unless you delete `/ami/shop/data/session_uuid.txt`.

---

## Listings Format

Listings live in `/ami/shop/listings.json`. Edit this file to configure what the shop sells and buys.

```json
{
  "listings": [
    { "type": "WTS", "item": "minecraft:diamond",    "price": 50000 },
    { "type": "WTS", "item": "minecraft:emerald",    "price": 25000 },
    { "type": "WTB", "item": "minecraft:iron_ingot", "price": 500   },
    { "type": "WTB", "item": "minecraft:gold_ingot", "price": 2000  }
  ]
}
```

### WTS — Want To Sell

The shop sells this item **from AE2 storage** to buyers.

| Field | Type | Description |
|-------|------|-------------|
| `type` | string | `"WTS"` |
| `item` | string | Full item ID, e.g. `"minecraft:diamond"` |
| `price` | integer | Price **per item** in µAMI (1 AMI = 1,000,000 µAMI) |

**Stock** is checked live from `meBridge.getItem()` every 30 seconds. If AE2 reports zero stock, the listing shows `OUT` in orange and quotes are rejected. Items are exported to the BOTTOM chest/barrel on successful purchase.

### WTB — Want To Buy

The shop buys this item **from sellers** using its own AMI balance.

| Field | Type | Description |
|-------|------|-------------|
| `type` | string | `"WTB"` |
| `item` | string | Full item ID, e.g. `"minecraft:iron_ingot"` |
| `price` | integer | Price **per item** in µAMI the shop pays |

**Liquidity** is checked live from the shop's witnessed balance. If the shop cannot afford the full order, the listing shows `LOW` in red and the trade is rejected. Sellers place items in the BOTTOM inventory before sending `SHOP_SELL`; the shop verifies item presence before transferring AMI.

---

## Config Format

`/ami/shop/config.json` controls witness nodes and vault sweep settings.

```json
{
  "nodes": [
    { "name": "MainNode", "key": "abcdef0123456789abcdef0123456789" }
  ],
  "sweep_pct": 5,
  "vault_addr": "3f8a1b2c...(128 hex chars)...",
  "vault_node_key": "abcdef0123456789abcdef0123456789"
}
```

| Field | Description |
|-------|-------------|
| `nodes` | Array of AmiCoin witness nodes. The shop queries these for balance/transfer. At least one is required for live transactions. |
| `sweep_pct` | Integer 1–50. Percentage of each sale/purchase swept to the AmiVault. Default: `5`. |
| `vault_addr` | 128-hex AmiVault owner address. Leave blank to disable sweeping. |
| `vault_node_key` | 32-hex XTEA key of the node hosting the vault. Leave blank to disable sweeping. |

> **Adding a node:** Use the wallet's Command Center (`[N]`) to register the shop's address (`/ami/shop/data/shop_addr.txt`) as a known wallet, then add the same node's key here.

---

## Transaction Pipelines

### WTS Pipeline (Buyer purchases from shop)

```
Buyer                          AmiStore
  │                                │
  │── SHOP_QUOTE (item, qty) ─────►│  1. Checks _stock ≥ qty
  │                                │     Creates pending order (60 s TTL)
  │◄─ {tx_id, price, shop_addr} ───│
  │                                │
  │── [pays via wallet Send] ──────►Mesh: wallet→shopAddr via node
  │                                │
  │── SHOP_CONFIRM (tx_id) ───────►│  2. Witnesses new balance (+price)
  │                                │  3. Shows receipt preview (3 s)
  │                                │  4. me.exportItem → BOTTOM
  │                                │  5. Sweeps vault_pct to AmiVault
  │                                │  6. Prints receipt (if printer present)
  │◄─ {ok=true, tx_id} ───────────│
```

### WTB Pipeline (Seller sells to shop)

```
Seller                         AmiStore
  │                                │
  │── [places item in BOTTOM] ─────►Physical tray
  │                                │
  │── SHOP_SELL (item, qty) ──────►│  1. tray.list() to verify item present
  │                                │  2. Checks _liquid ≥ totalPrice
  │                                │  3. TRANSFER shopAddr→sellerAddr via mesh
  │                                │  4. me.importItem from BOTTOM
  │                                │  5. Sweeps vault_pct to AmiVault
  │                                │  6. Prints receipt (if printer present)
  │◄─ {ok=true, tx_id} ───────────│
```

---

## Admin Dashboard

Press **`[A]`** on the terminal and enter the session token when prompted.

```
AMISTORE  ADMIN  DASHBOARD
Session : ACTIVE (hardware-bound)
Addr    : 3f8a1b2c4d5e6f7a8b9c0d...
Sweep   : 5%  |  Nodes: 1
----------- Listings -----------
[ 1] WTS   diamond                  50000 uAMI
[ 2] WTS   emerald                  25000 uAMI
[ 3] WTB   iron_ingot                 500 uAMI
[ 4] WTB   gold_ingot               2000 uAMI

[B]ack  [P]rice  [+]Add  [-]Remove  [S]weep%
```

| Key | Action |
|-----|--------|
| `[P]` | Edit the price of an existing listing (by index) |
| `[+]` | Add a new listing (prompts for type, item ID, price) |
| `[-]` | Remove a listing by index |
| `[S]` | Change the vault sweep percentage (1–50%) |
| `[B]` | Return to the storefront |

All changes are saved to `listings.json` / `config.json` immediately. The monitor updates on next redraw.

**The Admin Dashboard is strictly gated by the hardware-bound session token.** The token is never transmitted over the network and cannot be guessed without physical access to the computer. Entering the wrong token denies access silently.

---

## Receipts & Physical Audit Trail

When a Printer is attached to the LEFT side, AmiStore automatically prints a slip after each completed transaction.

### Sample Receipt

```
--- AMICOIN OFFICIAL RECEIPT ---
TX:   a3f91c2d
Type: WTS
Item: minecraft:diamond  x5
Amt:  250000 uAMI  (0.2500 AMI)
Party:3f8a1b2c4d5e6f7a8b9c0d1e2f...
--------------------------------
   .---.
  (  o  )
   `---'
```

The three-line ASCII Ami-Head at the bottom is the watermark confirming the receipt is genuine.

### Graceful Degradation

If the printer is:
- **Missing** — logged as `[WARN] [printer] Printer offline` and skipped.
- **Out of paper or ink** — `newPage()` returns false; logged as `[ERROR] [printer] Receipt failed` and skipped.
- **Any other error** — caught by `pcall`, logged, and skipped.

**In all cases the sale completes and the buyer receives their items.** Receipts are supplemental and never block the money flow.

---

## Structured Logging

All events are written to `/ami/shop/errors.log` in a structured format:

```
[1747305600000] [pipeline] [INFO] WTS ok: 5 x minecraft:diamond for 250000 uAMI [a3f91c2d]
[1747305601234] [ae2]      [WARN] WTB AE2 import failed [b4e72d1f]: peripheral error
[1747305999999] [printer]  [ERROR] Receipt failed for tx c5f83e2g: out of paper
```

| Field | Description |
|-------|-------------|
| `[timestamp]` | `os.epoch("utc")` in milliseconds |
| `[module]` | `pipeline`, `ae2`, `printer`, `mesh`, etc. |
| `[severity]` | `DEBUG`, `INFO`, `WARN`, or `ERROR` |
| `message` | Human-readable detail |

`WARN` and `ERROR` entries are also printed to the terminal in yellow and red respectively so the operator sees critical issues immediately.

---

## Merchant Node Identity

The shop generates a persistent identity on first run:

- **Shop key** — a random 32-hex XTEA key stored in `/ami/shop/data/shop_key.txt`. This is the shop's cryptographic identity and is **never transmitted**.
- **Shop address** — 128-hex public address derived from the shop key, stored in `/ami/shop/data/shop_addr.txt`.

### Why the Merchant Key must be registered

AmiCoin nodes only track balances for **registered addresses**. If the shop address is not registered on a witness node, `BALANCE` queries return `0` and `TRANSFER` payments to the shop will fail silently.

**Registration happens automatically at boot** — `api.registerShop()` sends a `REGISTER` packet to every configured witness node with the shop address and the name `"AmiStore"`. This is idempotent; running it multiple times is harmless.

To manually register (e.g. before first boot):
1. Find the shop address in `/ami/shop/data/shop_addr.txt`.
2. Open your wallet → `[S]end` → use the address as the recipient to trigger registration, **or**
3. Add the shop address to a node via the node's own ledger tool.

> The shop address also appears in the boot log and in the Admin Dashboard. Copy it and register it through your AmiCoin wallet's Command Center if automatic registration does not succeed.

---

## Vault Sweep

After every completed sale or purchase, AmiStore automatically transfers a percentage of the transaction value to a designated AmiVault:

```
sweep_amount = floor(totalPrice × sweep_pct / 100)
```

The sweep is a standard mesh `TRANSFER` from `shopAddress` → `vault_addr` and is committed atomically on the same witness node. If the sweep fails (e.g., node unreachable), it is silently skipped — it does not roll back the sale.

Configure via the Admin Dashboard (`[S]` key) or directly in `config.json`.

---

## Buyer / Seller Protocol

Third-party clients (other pads, turtles) communicate with AmiStore on **channel 1338** using XTEA-encrypted JSON packets. Wire format is identical to the AmiCoin mesh: `senderKeyHex|cipherHex`.

### Commands

| Command | Sender | Payload | Response |
|---------|--------|---------|----------|
| `SHOP_PING` | Anyone | `{cmd, from}` | `{ok, name, addr, version}` |
| `SHOP_QUOTE` | Buyer | `{cmd, from, item, qty, nonce}` | `{ok, tx_id, price, shop_addr}` or `{ok=false, err}` |
| `SHOP_CONFIRM` | Buyer | `{cmd, from, tx_id}` | `{ok, tx_id}` or `{ok=false, err}` |
| `SHOP_SELL` | Seller | `{cmd, from, item, qty, nonce}` | `{ok, tx_id}` or `{ok=false, err}` |

All replies are encrypted with the **shop's XTEA key** (`shopKey`). Buyers must know the shop's key to decrypt replies — this is analogous to how wallet comms works with node keys.

---

## Troubleshooting

| Symptom | Likely Cause | Fix |
|---------|-------------|-----|
| All listings show `OUT` | No meBridge on RIGHT | Attach ME Bridge to RIGHT side |
| `Payment unconfirmed` error | Buyer paid but balance not witnessed yet | Increase `MESH_TIMEOUT` or check witness node is reachable |
| `No witness node configured` | `config.json` `nodes` array is empty | Add at least one AmiCoin node to `config.json` |
| Printer never prints | Printer on wrong side | Attach Printer to LEFT side specifically |
| Admin login always fails | Wrong token | Check the token printed at boot; delete `session_uuid.txt` to reset |
| `AE2 import failed` log | Item not exported from AE2 yet or wrong side | Verify meBridge is on RIGHT and AE2 system has power |
| Shop address balance always 0 | Address not registered on witness nodes | Reboot (auto-registers) or manually send to the shop address once |
