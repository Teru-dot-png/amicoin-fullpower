# AmiCoin

**A standalone, cross-dimensional cryptocurrency for Minecraft built on CC:Tweaked.**

AmiCoin runs on a *Proof-of-Uptime* consensus: nodes earn coins simply by staying online and keeping the network healthy. No mining puzzles, no energy races — just reliable uptime.

---

## Table of Contents

1. [How It Works](#how-it-works)
2. [Hardware Requirements](#hardware-requirements)
3. [Quick-Start Guide](#quick-start-guide)
4. [Wallet Features](#wallet-features)
5. [Node Features](#node-features)
6. [Node Upgrades](#node-upgrades)
7. [AmiStore Marketplace](#amistore-marketplace)
8. [Reward Schedule](#reward-schedule)
9. [File Structure](#file-structure)
10. [Further Reading](#further-reading)

---

## How It Works

```
┌────────────────────────────────────────────────────┐
│               AmiCoin Mesh Network                 │
│                                                    │
│  ┌──────────────────┐      XTEA-encrypted          │
│  │  Advanced        │◄────────────────────────────►│
│  │  Computer        │      Ender Router mesh       │
│  │  (Node / Anchor) │      channel 1337            │
│  └──────────────────┘                              │
│         │                  ┌──────────────────┐    │
│  Manages ledger,           │  Ender Router Pad│    │
│  mints rewards,            │  (Wallet App)    │    │
│  optional Monitor display  └──────────────────┘    │
└────────────────────────────────────────────────────┘
```

1. **Node (Anchor)** — An Advanced Computer running `startup.lua` with an Ender Router attached. It holds the public ledger (`/data/ledger.json`), tracks which wallets are active on the mesh, mints coins every 30 seconds, and optionally drives a connected Advanced Monitor.

2. **Wallet (Pad)** — An Ender Router Pad running `startup.lua`. It holds *only* the user's Secret Key locally. It sends signed, encrypted heartbeats to keep the node counting its uptime. It supports multiple nodes simultaneously.

3. **XTEA Encryption** — Every packet on the mesh is encrypted with the wallet's 128-bit Secret Key, providing confidentiality in transit. The node never stores private keys.

---

## Hardware Requirements

| Component | CC:Tweaked Device | Purpose |
|-----------|------------------|---------|
| The Anchor | Advanced Computer | 24/7 uptime host; manages the public ledger and validates encrypted packets |
| The Mesh Link | Ender Router | Peripheral attached to the Anchor; handles cross-dimensional data on channels 1337 (mesh) and 1338 (shop/invoices) |
| The Mobile Terminal | Ender Router Pad | Handheld device running the Wallet App; stores the Secret Key locally |
| Status Display *(optional)* | Advanced Monitor | Live network stats board; the node auto-detects and drives it if present |

> **Tip:** The Anchor should be placed in a chunk-loaded area (e.g., spawn chunks, or using a Chunk Loader) to ensure continuous uptime.

---

## Quick-Start Guide

### Step 1 — Deploy the Node

On the Advanced Computer (with Ender Router attached):

```
wget run https://raw.githubusercontent.com/Teru-dot-png/amicoin-fullpower/refs/heads/main/installnode.lua
```

Type `YES` when prompted, then reboot. The node prints its **XTEA Node Key** on first boot — write this down. The installer also prints an **install fingerprint** you can compare against the published checksum on GitHub to verify the files were not tampered with.

### Step 2 — Deploy the Wallet

On each Ender Router Pad:

```
wget run https://raw.githubusercontent.com/Teru-dot-png/amicoin-fullpower/refs/heads/main/installpad.lua
```

Press Enter, then reboot. The Wallet App launches automatically.

### Step 3 — Configure the Wallet

1. On first boot, choose **[1] Create a new wallet** or **[2] Import existing key**.
2. Write down your **Secret Key** — it is displayed immediately after creation.
3. When prompted, enter the **Node XTEA Key** from Step 1.
4. Your wallet is now live on the mesh and earning rewards.

---

## Wallet Features

### Glass Cockpit Dashboard

The main screen is a high-density live view:

```
══════════════ AmiCoin ═════════════════
────────────────────────────────────────
Steve | 38de02..3e9f
1.2345 AMI
                           1234567 uAMI
────────────────────────────────────────
Node           Balance   Ping   St
HomeNode      1.2345    42ms   [OK]
FarmNode         ---      ---   [!]
────────────────────────────────────────
Net 7  50 uAMI/tk (2 nodes)  +6000/hr
────────────────────────────────────────
[S]end [R]efresh [E]xport [N] CmdCtr(2)
[V]ault  [U]pdate  [L]ogout
```

- **Per-node health table** — balance, round-trip latency, and status badge (`[OK]` / `[FP]` / `[??]`) for every configured node.
- **Network stats row** — sums the `effective_rate` (base rate × Overclocked Miner multiplier) across every responding node. If you run 5 nodes each giving 10 uAMI/tick the row shows **50 uAMI/tick** and the correct hourly total. The `/hr` figure uses the actual 30-second tick interval (120 ticks/hr).

### Multi-Node Support

The wallet connects to any number of nodes simultaneously. Balances are aggregated across all reachable nodes. Use the **Command Center** (`[N]`) to add, remove, or manage nodes.

### Unit Selection When Sending

When pressing **`[S]`** to send, you are prompted to choose the unit:

```
Unit? [A]MI or [U]uAMI:
> a
Amount (AMI):
> 1.5
```

Type `a` + Enter for AMI (human-friendly, decimal) or `u` + Enter for µAMI (integer, exact).

### Ami-DNS Name Cache

Player names are cached locally in `/wallet_data/names_cache.json`. Addresses appear as `"Steve"` wherever known instead of raw 128-character hex strings. The cache is populated automatically on register and on successful lookups during a Send operation, and is gossiped to all nodes automatically.

> **Note:** If a node has the **Privacy Shield** upgrade active, LOOKUP for that node operator's address returns `PRIVATE` to all wallets except their own.

### Command Center (Node Manager)

Press **`[N]`** to open the Command Center. Available actions:

| Key | Action |
|-----|--------|
| `[A]` | Add a node (manual key entry or auto-fetch via setup password) |
| `[D]` | Remove a node |
| `[I]` | **Integrity Handshake** — fetch & compare each node's file fingerprint. Shows `OK` / `TOFC` / `MISMATCH` (tamper alert) |
| `[G]` | **Gossip DNS** — push your entire local name cache to all nodes |
| `[C]` | **Consolidate** — sweep balances from all nodes into a single target node |
| `[B]` | Back to Dashboard |

### AmiVault

Press **`[V]`** from the Dashboard. Lock a chosen amount of AMI for a chosen duration. Locked funds cannot be spent until the timer expires. An **Auto-Sweep** mode can automatically lock earnings above a configured threshold.

### Auto-Login Session

After first login the wallet saves an encrypted session token (bound to the computer's hardware ID). On subsequent reboots the Dashboard opens immediately. Press **`[L]`** to log out and clear the session.

### Self-Update

Press **`[U]`** from the Dashboard to pull the latest wallet files from GitHub. Each file is FNV-1a hash-verified before writing.

---

## Node Features

### Commands Handled

| Command | Description |
|---------|-------------|
| `HEARTBEAT` | Records wallet as active; keeps uptime counter running |
| `BALANCE` | Returns the wallet's current µAMI balance |
| `TRANSFER` | Moves µAMI from one address to another (by address or Ami-DNS name) |
| `REGISTER` | Registers a new wallet address and optional player name |
| `LOOKUP` | Resolves a player name to a wallet address (returns `PRIVATE` if Privacy Shield is active for that address) |
| `GETKEY` | Returns the node's XTEA key after password authentication |
| `VAULT_LOCK` | Locks an amount of µAMI into a time-locked vault |
| `VAULT_UNLOCK` | Releases a vault whose timer has expired |
| `VAULT_LIST` | Returns all vault entries for an address |
| `STATS` | Returns active-wallet count, total supply, base and effective mint rates, tick count, TPS lag factor, node fingerprint, and whether Priority Ping is active |
| `FINGERPRINT` | Returns the node's current FNV-1a file fingerprint for tamper detection |
| `GOSSIP_DNS` | Accepts a name↔address mapping and persists it to the node's name registry |
| `CONSOLIDATE_OUT` | Drains a wallet's balance from this node and returns a signed receipt |
| `CONSOLIDATE_IN` | Credits a wallet on this node from a receipt (Fee Snatcher upgrade skims a routing fee) |

### Monitor Display

If an Advanced Monitor is attached, the node renders a live status board every 10–30 seconds:

```
────────── AmiCoin Node v1.0.0 ──────────
------------------------------------------
Key:    a3f1b2c4d5e6f7a8...
Active: 3 wallet(s)
Supply: 12345678 uAMI
      = 12.345678 AMI
Chan:   1337
------------------------------------------
Rate:   10 uAMI/tk
      = 1.2000 AMI/hr
TPS:    OK
------------------------------------------
Upgrades active:
OvrclkMiner  Lv2
HBExtender   Lv1
```

- Rate rows show the **effective rate** (base × Overclocked Miner multiplier).
- The upgrades panel only appears when at least one upgrade has been purchased.
- The colour theme changes when the **Advanced Matrix UI** upgrade is active.

### Keyboard Shortcuts

| Key | Action |
|-----|--------|
| `U` | Self-update from GitHub; reboots on success |
| `P` | Open the **Node Upgrade Shop** |

### Watchdog

A background coroutine checks the Ender Router every 30 seconds. If the router stops responding the node reboots automatically.

### Self-Update

Press **`U`** on the node's keyboard. Each downloaded file is size-checked and FNV-1a hashed before writing. The update also fetches `upgrades.lua` so upgrade logic stays in sync with the rest of the node software.

---

## Node Upgrades

Node operators can purchase permanent performance upgrades for their node directly from the node's keyboard. Press **`[P]`** to open the upgrade shop.

### How It Works

1. The first time you open the shop you are prompted to enter your Ami-DNS name. This becomes the **treasury address** — the wallet that receives upgrade revenue from third-party buyers. When the node operator buys their own upgrades the cost is **burned** (sent to an unspendable address) so coins are removed from circulation.
2. Enter the buyer's Ami-DNS name. The node broadcasts a standard AmiCoin **INVOICE** on channel 1338, identical to AmiStore. Accept it on the Wallet Pad with **`[Y]`**.
3. On a confirmed PAYMENT_ACK the upgrade level is incremented immediately and saved to `/data/upgrades.json`.

### Upgrade Pricing

Upgrades use an exponential curve: Level 1 costs **1 AMI** (1,000,000 µAMI), Level 10 costs **100 AMI**.

`cost(level) = floor(1,000,000 × 100 ^ ((level − 1) / 9))`

| Level | Cost (AMI) |
|-------|-----------|
| 1 | 1.0000 |
| 2 | 1.6681 |
| 3 | 2.7826 |
| 5 | 7.7426 |
| 8 | 35.9381 |
| 10 | 100.0000 |

### Available Upgrades

| ID | Name | Max Level | Effect |
|----|------|-----------|--------|
| `miner_boost` | Overclocked Miner | 10 | +20% mining payout multiplier per level (1.0× → 3.0×) |
| `priority_ping` | Priority Ping Response | 10 | Removes error-path reply delay; advertises `priority_ping=true` in STATS |
| `privacy_shield` | Ledger Privacy Shield | 10 | LOOKUP returns `PRIVATE` for the node operator's address |
| `smart_cache` | Smart Cache Aggregator | 10 | Batches ledger disk writes; +3 s flush interval per level (0 → 30 s) |
| `collision_fix` | Collision Handler | 10 | Reduces error-path backoff by 0.05 s per level (0.5 s → 0.0 s) |
| `fee_snatcher` | Routing Fee Snatcher | 10 | Skims 100 µAMI per level from every CONSOLIDATE_IN operation |
| `hb_extender` | Heartbeat Extender | 10 | Extends active-wallet TTL +9 s per level (90 s base → 180 s max) |
| `dns_longevity` | DNS Cache Longevity | 10 | Multiplies local DNS record TTL by level |
| `matrix_ui` | Advanced Matrix UI | 10 | Unlocks premium monitor colour themes per level |
| `genesis` | Genesis Protocol | 10 | Broadcasts a prestige signature across the mesh at every boot |

### Upgrade State

Upgrade levels are persisted to `/data/upgrades.json`. This file is **XTEA-encrypted at rest** using the node's own hardware key (`/data/node_key.txt`) — manually editing it produces unreadable ciphertext that the node rejects. Levels are also clamped to `[0, 10]` on every read regardless. The file is preserved across `[U]` self-updates and is wiped only on a **Clean Install** (which also wipes `/data/`).

---

## AmiStore Marketplace

AmiStore is a decentralised, AE2-integrated shopfront that runs as a peer node on the AmiCoin mesh. Buyers and sellers communicate over the mesh on channel 1338, with balance witnessing handled by whichever AmiCoin nodes the merchant has configured. See **[SHOP.md](SHOP.md)** for the full Merchant Manual.

### How it fits into the network

```
Player Wallet (Pad)              AmiStore (Merchant Node)
     │                                     │
     │── touch listing on monitor ────────►│  Invoice broadcast on ch 1338
     │◄── INVOICE popup on wallet ─────────│
     │── Send payment (wallet → shop) ────►│  Witnessed by mesh node
     │── PAYMENT_ACK ─────────────────────►│  Item exported AE2 → tray
```

### Key features

- **WTS listings** — shop sells items from AE2 digital storage; live stock checked every 30 s.
- **WTB listings** — shop buys items from players using its own µAMI balance.
- **Touch-to-buy invoice flow** — tapping a listing card on the monitor triggers a wallet pop-up; no manual key entry required.
- **Admin panel** — password-gated dashboard; access is strictly local.
- **Vault sweep** — configurable percentage of every transaction swept to an AmiVault address.

### Install AmiStore

```
wget run https://raw.githubusercontent.com/Teru-dot-png/amicoin-fullpower/refs/heads/main/installshop.lua
```

---

## Reward Schedule

Rewards are issued in *microcoins* (µAMI). **1 AMI = 1,000,000 µAMI.**

> **Live rate:** The base reward rate is controlled by [`reward_rate.txt`](../reward_rate.txt) in this repository.
> Nodes fetch this file at startup and every ~10 minutes. If unreachable, the last known value is kept.
> The rate is **never saved to disk** on the node — edit the file in the repo to change it for all nodes globally.

| Period | Base Rate | Notes |
|--------|-----------|-------|
| Ticks 0 – 525,599 | *live rate* µAMI / tick / wallet | ~1 in-game year |
| Ticks 525,600 – 1,051,199 | *live rate* ÷ 2 | First halving |
| Ticks 1,051,200 – 1,576,799 | *live rate* ÷ 4 | Second halving |
| … | Halves each period | Floor: 1 µAMI |

- A wallet is **active** if it has sent any packet to the node within the last 90 seconds (extendable to 180 s with the Heartbeat Extender upgrade).
- Each reward cycle is **30 seconds** (120 ticks/hr). All active wallets receive the current effective rate simultaneously.
- The **effective rate** paid per wallet per tick is `floor(base_rate × miner_multiplier)` where `miner_multiplier = 1.0 + 0.2 × miner_boost_level`.
- `totalTicks` is persisted to `/data/miner_state.json` and survives reboots, so the halving schedule is never reset.

---

## File Structure

```
amicoin/
├── shared/
│   └── xtea.lua              XTEA cipher library (node, wallet, and shop)
├── node/
│   ├── startup.lua           Node entry point; packet dispatcher, monitor, watchdog, key input
│   ├── ledger.lua            Ledger, name registry, AmiVault, in-memory write cache
│   ├── miner_daemon.lua      Proof-of-Uptime reward engine (TPS-aware, halving, upgrade-aware)
│   ├── upgrades.lua          Node Upgrade Engine; 10 upgrades, invoice flow, effect API
│   └── xtea.lua              Thin re-export of shared/xtea.lua
├── wallet/
│   ├── main.lua              Glass Cockpit dashboard, all wallet screens, Ami-DNS cache
│   ├── secret_manager.lua    Key generation, import, and 128-char address derivation
│   ├── session.lua           Hardware-bound encrypted auto-login session
│   └── comms.lua             Encrypted packet I/O, latency measurement, all node commands
├── ami/shop/
│   ├── startup.lua           AmiStore entry point; parallel network/sync/input loops
│   ├── shop_api.lua          AE2, listings, pipeline, structured logging
│   └── shop_ui.lua           Glass Cockpit monitor UI
├── docs/
│   ├── README.md             This file
│   ├── SHOP.md               AmiStore Merchant Manual
│   ├── SECURITY.md           XTEA, source verification, and key safety guidelines
│   └── MIGRATION.md          How to move your wallet to a new Pad
├── installnode.lua           One-command node installer (includes upgrades.lua)
├── installpad.lua            One-command wallet installer
└── installshop.lua           One-command AmiStore installer
```

---

## Further Reading

- [SHOP.md](SHOP.md) — AmiStore Merchant Manual: hardware layout, listing format, receipts, admin gate.
- [SECURITY.md](SECURITY.md) — XTEA encryption, source verification, and keeping your Secret Key safe.
- [MIGRATION.md](MIGRATION.md) — Moving your wallet to a new Ender Router Pad.


---
