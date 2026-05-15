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
6. [AmiStore Marketplace](#amistore-marketplace)
7. [Reward Schedule](#reward-schedule)
8. [File Structure](#file-structure)
9. [Further Reading](#further-reading)

---

## How It Works

```
┌────────────────────────────────────────────────────┐
│               AmiCoin Mesh Network                 │
│                                                    │
│  ┌──────────────────┐      XTEA-encrypted           │
│  │  Advanced        │◄────────────────────────────►│
│  │  Computer        │      Ender Router mesh         │
│  │  (Node / Anchor) │      channel 1337             │
│  └──────────────────┘                              │
│         │                  ┌──────────────────┐    │
│  Manages ledger,           │  Ender Router Pad │    │
│  mints rewards,            │  (Wallet App)     │    │
│  optional Monitor display  └──────────────────┘    │
└────────────────────────────────────────────────────┘
```

1. **Node (Anchor)** — An Advanced Computer running `startup.lua` with an Ender Router attached. It holds the public ledger (`/data/ledger.json`), tracks which wallets are active on the mesh, mints coins every 60 seconds, and optionally drives a connected Advanced Monitor.

2. **Wallet (Pad)** — An Ender Router Pad running `main.lua`. It holds *only* the user's Secret Key locally. It sends signed, encrypted heartbeats to keep the node counting its uptime. It supports multiple nodes simultaneously.

3. **XTEA Encryption** — Every packet on the mesh is encrypted with the wallet's 128-bit Secret Key, providing confidentiality in transit. The node never stores private keys.

---

## Hardware Requirements

| Component | CC:Tweaked Device | Purpose |
|-----------|------------------|---------|
| The Anchor | Advanced Computer | 24/7 uptime host; manages the public ledger and validates encrypted packets |
| The Mesh Link | Ender Router | Peripheral attached to the Anchor; handles cross-dimensional XTEA-encrypted data on channel 1337 |
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

Press Enter, then reboot. The Wallet App launches automatically. The installer prints its own fingerprint for the same tamper-verification purpose.

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
═══════════════ AmiCoin ════════════════
─────────────────────────────────────
Steve | 38de02..3e9f
1.2345 AMI
                          1234567 uAMI
─────────────────────────────────────
Node           Balance   Ping  St
HomeNode      1.2345    42ms  [OK]
FarmNode         ---      ---  [!]
─────────────────────────────────────
Net 7 active  25 uAMI/tick  +1500/hr
─────────────────────────────────────
[S]end [R]efresh [E]xport [N]odes(2)
[V]ault  [U]pdate  [L]ogout
```

- **Per-node health table** — balance, round-trip latency, and status for every configured node.
- **Network stats** — live active-wallet count, current mint rate, and estimated hourly earnings pulled from the STATS command.

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

Type `a` + Enter for AMI (human-friendly, decimal) or `u` + Enter for µAMI (integer, exact). Both resolve to the same on-chain amount — µAMI is the raw wire format.

### Ami-DNS Name Cache

Player names are cached locally in `/wallet_data/names_cache.json`. Addresses appear as `"Steve"` wherever known instead of raw 128-character hex strings. The cache is populated automatically when you register your own name and whenever a name lookup succeeds during a Send operation. Cached names are gossiped to all nodes automatically so the entire mesh shares the same directory.

### Command Center (Node Manager)

Press **`[N]`** to open the Command Center. Available actions:

| Key | Action |
|-----|--------|
| `[A]` | Add a node (manual key entry or auto-fetch via setup password) |
| `[D]` | Remove a node |
| `[I]` | **Integrity Handshake** — fetch & compare each node's file fingerprint against the trusted on-file hash. Shows `OK` / `TOFC` (trust on first contact) / `MISMATCH` (tamper alert) |
| `[G]` | **Gossip DNS** — push your entire local name cache to all nodes |
| `[C]` | **Consolidate** — sweep balances from all nodes into a single target node |
| `[B]` | Back to Dashboard |

Press **`[V]`** from the Dashboard to open AmiVault. You can lock a chosen amount of AMI for a chosen duration (in seconds). Locked funds cannot be spent until the timer expires — useful for commitment savings or gift locks.

### Auto-Login Session

After your first successful login the wallet saves an encrypted session token (bound to the computer's hardware ID). On subsequent reboots the Dashboard opens immediately without requiring your password again. Press **`[L]`** to log out and clear the session.

### Self-Update

Press **`[U]`** from the Dashboard to pull the latest wallet files from GitHub. Each file is hash-verified before writing; a combined fingerprint is shown after the update completes.

---

## Node Features

### Commands Handled

| Command | Description |
|---------|-------------|
| `HEARTBEAT` | Records wallet as active; keeps uptime counter running |
| `BALANCE` | Returns the wallet's current µAMI balance |
| `TRANSFER` | Moves µAMI from one address to another |
| `REGISTER` | Registers a new wallet address with a player name |
| `LOOKUP` | Resolves a player name to a wallet address |
| `GETKEY` | Returns the node's XTEA key after password authentication |
| `VAULT_LOCK` | Locks an amount of µAMI into a time-locked vault |
| `VAULT_UNLOCK` | Releases a vault whose timer has expired |
| `VAULT_LIST` | Returns all vault entries for an address |
| `STATS` | Returns active-wallet count, total supply, mint rate, tick count, TPS lag factor, and node file fingerprint |
| `FINGERPRINT` | Returns the node's current FNV-1a file fingerprint for tamper detection |
| `GOSSIP_DNS` | Accepts a name↔address mapping from a wallet and persists it to the node's name registry |

### Monitor Display

If an Advanced Monitor is connected, the node automatically renders a live status board every 10 seconds showing the node key hint, active wallet count, total supply, current mint rate, and mesh channel. No configuration needed — the node silently skips this step if no monitor is present.

### Watchdog

A background coroutine checks the Ender Router every 30 seconds. If the router stops responding (e.g., the peripheral is removed), the node reboots automatically to restore the connection.

### Self-Update

Press **`U`** on the node's keyboard to pull the latest node files from GitHub. Each downloaded file is size-checked and FNV-1a hashed before being written to disk. A combined fingerprint is printed on completion.

---

## AmiStore Marketplace

AmiStore is a decentralised, AE2-integrated shopfront that runs as a peer node on the AmiCoin mesh. It operates entirely without a central server: buyers and sellers communicate with the shop computer directly over XTEA-encrypted modem packets on channel 1338, with balance witnessing handled by whichever AmiCoin nodes the merchant has configured. See **[SHOP.md](SHOP.md)** for the full Merchant Manual.

### How it fits into the network

```
Player Wallet (Pad)              AmiStore (Merchant Node)
     │                                     │
     │── touch listing on monitor ────────►│  Invoice broadcast on ch 1338
     │◄── INVOICE popup on wallet ─────────│
     │── Send payment (wallet → shop) ────►│  Witnessed by mesh node
     │── PAYMENT_ACK ────────────────────►│  Item exported AE2 → tray
     │                                     │  Receipt printed (optional)
```

### Key features

- **WTS listings** — shop sells items from AE2 digital storage; live stock checked every 30 s via `me_bridge`.
- **WTB listings** — shop buys items from players using its own µAMI balance; sellers place items in the BOTTOM chest.
- **Touch-to-buy invoice flow** — tapping a listing card on the monitor triggers a wallet pop-up on the buyer's Pad; no manual key entry required.
- **Admin panel** — password-gated dashboard for editing listings, prices, and vault sweep settings; access is strictly local (hardware-bound password hash, never transmitted).
- **Vault sweep** — a configurable percentage of every transaction is swept automatically to a designated AmiVault address.
- **Smart self-update** — delta-checked GitHub pull with FNV-1a verification and automatic `.bak` rollback on failure.

### Install AmiStore

```
wget run https://raw.githubusercontent.com/Teru-dot-png/amicoin-fullpower/refs/heads/main/installshop.lua
```

---

## Reward Schedule

Rewards are issued in *microcoins* (µAMI). **1 AMI = 1,000,000 µAMI.**

> **Live rate:** The base reward rate is controlled by [`reward_rate.txt`](../reward_rate.txt) in this repository.
> Nodes fetch this file at startup and every 10 ticks (~10 minutes). If unreachable, they keep the last known value.
> The rate is **never saved to disk** on the node — edit the file in the repo to change it for all nodes globally.

| Period | Base Rate | Notes |
|--------|-----------|-------|
| Ticks 0 – 525,599 | *live rate* µAMI / min / wallet | ~1 in-game year |
| Ticks 525,600 – 1,051,199 | *live rate* ÷ 2 | First halving |
| Ticks 1,051,200 – 1,576,799 | *live rate* ÷ 4 | Second halving |
| … | Halves each period | Floor: 1 µAMI |

- A wallet is **active** if it has sent any packet to the node within the last 90 seconds.
- `totalTicks` is persisted to `/data/miner_state.json` and survives reboots, so the halving schedule is never reset.
- Each reward cycle is 60 seconds. All active wallets receive the current rate simultaneously.

---

## File Structure

```
amicoin/
├── shared/
│   └── xtea.lua            XTEA cipher library (used by node, wallet, and shop)
├── node/
│   ├── startup.lua         Node entry point; Ender Router listener, monitor, watchdog
│   ├── ledger.lua          Ledger, name registry, and AmiVault storage
│   ├── miner_daemon.lua    Proof-of-Uptime reward engine (TPS-aware, halving, ticks)
│   └── xtea.lua            Thin re-export of shared/xtea.lua
├── wallet/
│   ├── main.lua            Glass Cockpit dashboard, all wallet screens, Ami-DNS cache
│   ├── secret_manager.lua  Key generation, import, and 128-char address derivation
│   ├── session.lua         Hardware-bound encrypted auto-login session
│   └── comms.lua           Encrypted packet I/O, latency measurement, all node commands
├── ami/shop/
│   ├── startup.lua         AmiStore entry point; parallel network/sync/input loops
│   ├── shop_api.lua        Intelligence layer: AE2, listings, pipeline, structured logging
│   └── shop_ui.lua         Glass Cockpit monitor UI (orange/red/gray theme)
├── docs/
│   ├── README.md           This file
│   ├── SHOP.md             AmiStore Merchant Manual
│   ├── SECURITY.md         XTEA, source verification, and key safety guidelines
│   └── MIGRATION.md        How to move your wallet to a new Pad
├── installnode.lua         One-command node installer with FNV-1a tamper detection
├── installpad.lua          One-command wallet installer with FNV-1a tamper detection
└── installshop.lua         One-command AmiStore installer with hardware checklist
```

---

## Further Reading

- [SHOP.md](SHOP.md) — AmiStore Merchant Manual: hardware layout, listing format, receipts, admin gate.
- [SECURITY.md](SECURITY.md) — XTEA encryption, source verification, and keeping your Secret Key safe.
- [MIGRATION.md](MIGRATION.md) — Moving your wallet to a new Ender Router Pad.
