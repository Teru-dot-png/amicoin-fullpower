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
8. [AmiCasino](#amicasino)
9. [Reward Schedule](#reward-schedule)
10. [File Structure](#file-structure)
11. [Further Reading](#further-reading)

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

Upgrades use per-upgrade cost curves. Earners use a flat curve; cosmetics use a cheaper flat curve.

| Upgrade group | Cost per level | Max total |
|---|---|---|
| Overclocked Miner, Mint Surge | Exponential 1 → 100 AMI | 100 AMI each |
| Fee & Vault Yield, Transfer Toll | Flat 0.2 AMI/level | 2 AMI |
| Wallet Bonus | Flat 0.1 AMI/level | 1 AMI |
| Matrix UI, Genesis Protocol (cosmetic) | Flat 0.05 AMI/level | 0.5 AMI |

### Available Upgrades

| ID | Name | Cost/level | Max Level | Effect | Type |
|----|------|-----------|-----------|--------|------|
| `miner_boost` | Overclocked Miner | 1→100 AMI | 10 | +20% mining payout multiplier per level (1.0× → 3.0×) | Inflationary |
| `mint_surge` | Mint Surge | 1→100 AMI | 10 | Fires a bonus 2× reward tick on a cooldown: Lv1 = every 80 min → Lv10 = every 8 min | Inflationary |
| `fee_snatcher` | Fee & Vault Yield | 0.2 AMI | 10 | 100 µAMI/level per CONSOLIDATE_IN + 5 µAMI/tick per active vault per level | Redistributive |
| `transfer_toll` | Transfer Toll | 0.2 AMI | 10 | 50 µAMI per level skimmed from every TRANSFER routed through this node (from sender) | Redistributive |
| `wallet_bonus` | Wallet Bonus | 0.1 AMI | 10 | +1 µAMI/tick per active wallet per level credited to treasury | Small inflationary |
| `matrix_ui` | Advanced Matrix UI | 0.05 AMI | 10 | Unlocks premium monitor colour themes per level | Cosmetic |
| `genesis` | Genesis Protocol | 0.05 AMI | 10 | Broadcasts a prestige signature across the mesh at every boot | Cosmetic |

#### Retired upgrades (grandfathered)
The following upgrades are no longer sold but **remain active** on nodes that already own them. Their effects are preserved across reboots and self-updates. They do not appear in the shop menu.

| ID | Effect preserved |
|----|----------------|
| `priority_ping` | Advertises `priority_ping=true` in STATS |
| `smart_cache` | Batches ledger disk writes (+3 s flush/level) |
| `collision_fix` | Reduces error-path backoff (−0.05 s/level) |
| `dns_longevity` | Multiplies local DNS record TTL by level |
| `hb_extender` | Extends active-wallet TTL (+9 s/level, 90 s base) |

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

## AmiCasino

AmiCasino is a standalone gamble station that runs on any CC:Tweaked computer with an Ender Router or modem. Players bet AmiCoin on 9 different games. Winnings are credited and losses are collected through the same INVOICE / PAYMENT_ACK flow used by AmiStore — no special trust required on the node side.

### Install

```
wget run https://raw.githubusercontent.com/Teru-dot-png/amicoin-fullpower/refs/heads/main/installcasino.lua
```

Choose **[I] Install** on first setup. After installation, run `shell.run("/ami/casino/startup")` (or reboot if `/startup.lua` was written by the installer).

### First-Time Setup

1. Press **`[A]`** from the lobby to open the Admin panel.
2. Add at least one AmiCoin node (name + 32-char XTEA key).
3. Fund the **casino wallet** with enough AMI to cover potential payouts — the casino address is printed at startup. Transfer AMI to it from any wallet.
4. Press **`[P]`** to start playing.

### Playing

From the lobby press **`[P]`**. You are asked:

```
Who's Playing?
  Enter your Ami-DNS name:
  > Steve
```

The casino looks up your name on the configured nodes. Once found, the **game menu** opens across two pages:

| Page | # | Game | House Edge |
|------|---|------|------------|
| 1 | 1 | **Mines** | ~2% |
| 1 | 2 | **Crash** | ~4% |
| 1 | 3 | **Slots** | ~5% |
| 1 | 4 | **Blackjack** | ~3% |
| 1 | 5 | **Roulette** | ~2.7% |
| 2 | 1 | **Higher / Lower** | ~4% |
| 2 | 2 | **Pachinko** | ~4.7% |
| 2 | 3 | **Craps** | ~1.4% |
| 2 | 4 | **Coin Flip** | 4% |

Navigate pages with **`[N]`** / **`[P]`**. Select a game with **`[1–5]`**. Press **`[B]`** to return to the lobby.

### Game Summaries

- **Mines** — 5×5 grid with hidden mines. Reveal safe tiles to grow a multiplier, cash out any time with `[C]`. Hit a mine and lose the bet. More mines = higher potential reward.
- **Crash** — A multiplier rises from 1.0× until it randomly crashes. Press `[C]` to cash out before it does. The longer you wait, the bigger the reward — but it can crash at any moment.
- **Slots** — 3 weighted reels. Three 7s = 10× your bet. Any matching pair on the left two reels returns 0.5×.
- **Blackjack** — Standard rules. Dealer stands on soft 17. Natural blackjack pays 3:2. Hit `[H]`, stand `[S]`.
- **Roulette** — European single-zero. Bet on a number (35:1), red/black, odd/even, or high/low (1:1).
- **Higher / Lower** — Guess whether the next of 5 cards is higher or lower. Correct streak builds a multiplier up to 3.2×. Equal card = free round.
- **Pachinko** — Animated 7-row peg board. The ball bounces left or right at each row. Outer buckets pay 12×; centre buckets pay 0.2×.
- **Craps** — Pass-line craps. 7 or 11 on the come-out wins; 2, 3, or 12 loses; any other number sets the point. Roll the point before a 7 to win.
- **Coin Flip** — Pick heads or tails. Win pays 1.92× (net +0.92× your bet).

### Money Flow

**Win:**  Casino TRANSFER to player address (coins move from casino wallet)
**Loss:** Session balance decreases in memory; no per-game on-chain movement
**Cashout:** Single TRANSFER at session end. If casino is short, pays what it has and records the remainder owed in the session file.

> **Important:** The casino wallet must hold enough AMI to cover payouts. If it runs dry, winning players will not receive funds. Top it up periodically via any AmiCoin wallet.

### Lobby Keys

| Key | Action |
|-----|--------|
| `P` | Play (enter Ami-DNS name → game menu) |
| `A` | Admin (add/remove nodes) |
| `U` | Self-update from GitHub |
| `Q` | Quit |

Rewards are issued in *microcoins* (µAMI). **1 AMI = 1,000,000 µAMI.**

> **Live rate:** The base reward rate is controlled by [`reward_rate.txt`](../reward_rate.txt) in this repository.
> Nodes fetch this file at startup and every ~10 minutes. If unreachable, the last known value is kept.
> The rate is **never saved to disk** on the node — edit the file in the repo to change it for all nodes globally.

| Period | Base Rate | Notes |
|--------|-----------|-------|
| Ticks 0 – 525,599 | *live rate* µAMI / tick / wallet | ~182 real days at 30s/tick |
| Ticks 525,600 – 1,051,199 | *live rate* ÷ 2 | First halving |
| Ticks 1,051,200 – 1,576,799 | *live rate* ÷ 4 | Second halving |
| … | Halves each period | Floor: 1 µAMI |

- A wallet is **active** if it has sent any packet to the node within the last 90 seconds (extendable to 180 s with the Heartbeat Extender upgrade).
- Each reward cycle is **30 seconds** (120 ticks/hr). All active wallets receive the current effective rate simultaneously.
- The `HALVING_TICKS` constant is 525,600 ticks = 525,600 × 30s ≈ **182 real days** per halving period.
- The **effective rate** paid per wallet per tick is `floor(base_rate × miner_multiplier)` where `miner_multiplier = 1.0 + 0.2 × miner_boost_level`.
- `totalTicks` is persisted to `/data/miner_state.json` and survives reboots, so the halving schedule is never reset.

---

## File Structure

```
amicoin/
├── shared/
│   └── xtea.lua              XTEA cipher library (node, wallet, shop, and casino)
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
├── ami/casino/
│   ├── startup.lua           AmiCasino entry point; lobby, login, admin, money flow
│   ├── games.lua             All 9 games (Mines, Crash, Slots, Blackjack, Roulette,
│   │                         Higher/Lower, Pachinko, Craps, Coin Flip)
│   └── ui.lua                Shared terminal drawing helpers, bet prompt, animations
├── docs/
│   ├── README.md             This file
│   ├── SHOP.md               AmiStore Merchant Manual
│   ├── SECURITY.md           XTEA, source verification, and key safety guidelines
│   └── MIGRATION.md          How to move your wallet to a new Pad
├── installnode.lua           One-command node installer (includes upgrades.lua)
├── installpad.lua            One-command wallet installer
├── installshop.lua           One-command AmiStore installer
└── installcasino.lua         One-command AmiCasino installer
```

---

## Further Reading

- [SHOP.md](SHOP.md) — AmiStore Merchant Manual: hardware layout, listing format, receipts, admin gate.
- [SECURITY.md](SECURITY.md) — XTEA encryption, source verification, and keeping your Secret Key safe.
- [MIGRATION.md](MIGRATION.md) — Moving your wallet to a new Ender Router Pad.
