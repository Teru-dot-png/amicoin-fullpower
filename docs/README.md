# AmiCoin

**A standalone, cross-dimensional cryptocurrency for Minecraft built on CC:Tweaked.**

AmiCoin runs on a *Proof-of-Uptime* consensus: nodes earn coins simply by staying online and keeping the network healthy. No mining puzzles, no energy races — just reliable uptime.

---

## Table of Contents

1. [How It Works](#how-it-works)
2. [Hardware Requirements](#hardware-requirements)
3. [Quick-Start Guide](#quick-start-guide)
4. [Reward Schedule](#reward-schedule)
5. [File Structure](#file-structure)
6. [Further Reading](#further-reading)

---

## How It Works

```
┌──────────────────────────────────────────────────┐
│              AmiCoin Mesh Network                │
│                                                  │
│  ┌─────────────────┐      XTEA-encrypted          │
│  │  Advanced       │◄────────────────────────────►│
│  │  Computer       │      Ender Router mesh        │
│  │  (Node/Anchor)  │                              │
│  └─────────────────┘      ┌──────────────────┐   │
│         │                 │  Ender Router Pad │   │
│  Manages ledger,          │  (Wallet App)     │   │
│  mints rewards            └──────────────────┘   │
└──────────────────────────────────────────────────┘
```

1. **Node (Anchor)** — An Advanced Computer running `startup.lua` with an Ender Router attached. It holds the public ledger (`/data/ledger.json`), tracks which wallets are active on the mesh, and mints coins every 60 seconds.

2. **Wallet (Pad)** — An Ender Router Pad running `main.lua`. It holds *only* the user's Secret Key locally. It sends signed, encrypted heartbeats to keep the node counting its uptime.

3. **XTEA Encryption** — Every packet on the mesh is encrypted with the wallet's 128-bit Secret Key, providing confidentiality in transit. The node never stores private keys.

---

## Hardware Requirements

| Component | CC:Tweaked Device | Purpose |
|-----------|------------------|---------|
| The Anchor | Advanced Computer | 24/7 uptime host; manages the public ledger and validates encrypted packets |
| The Mesh Link | Ender Router | Peripheral attached to the Anchor; handles cross-dimensional XTEA-encrypted data on channel 1337 |
| The Mobile Terminal | Ender Router Pad | Handheld device running the Wallet App; stores the Secret Key locally |

> **Tip:** The Anchor should be placed in a chunk-loaded area (e.g., spawn chunks, or using a Chunk Loader) to ensure continuous uptime.

---

## Quick-Start Guide

### Step 1 — Deploy the Node

On the Advanced Computer (with Ender Router attached):

```
wget run https://raw.githubusercontent.com/Teru-dot-png/amicoin-fullpower/refs/heads/main/installnode.lua
```

Type `YES` when prompted, then reboot. The node will print its **XTEA Node Key** — write this down.

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

## Reward Schedule

Rewards are issued in *microcoins* (µAMI). **1 AMI = 1,000,000 µAMI.**

| Period | Base Rate | Notes |
|--------|-----------|-------|
| Ticks 0 – 525,599 | 10 µAMI / min / wallet | ~1 in-game year |
| Ticks 525,600 – 1,051,199 | 5 µAMI / min / wallet | First halving |
| Ticks 1,051,200 – 1,576,799 | 2 µAMI / min / wallet | Second halving |
| … | Halves each period | Minimum 1 µAMI |

A wallet is considered **active** if it has sent any packet to the node within the last 90 seconds.

---

## File Structure

```
amicoin/
├── shared/
│   └── xtea.lua            XTEA cipher library (used by both node and wallet)
├── node/
│   ├── startup.lua         Node entry point; opens Ender Router, dispatches commands
│   ├── ledger.lua          On-disk wallet address → balance database
│   ├── miner_daemon.lua    Proof-of-Uptime reward engine
│   └── xtea.lua            Thin re-export of shared/xtea.lua
├── wallet/
│   ├── main.lua            GUI: Login, Dashboard, Send, Export Key
│   ├── secret_manager.lua  Key generation, import, and address derivation
│   ├── session.lua         Device-encrypted persistent session (auto-login)
│   └── comms.lua           XTEA packet signing and Ender Router I/O
├── docs/
│   ├── README.md           This file
│   ├── SECURITY.md         XTEA explanation and key safety guidelines
│   └── MIGRATION.md        How to move your wallet to a new Pad
├── installnode.lua         One-command node installer
└── installpad.lua          One-command wallet installer
```

---

## Further Reading

- [SECURITY.md](SECURITY.md) — Understanding XTEA and keeping your Secret Key safe.
- [MIGRATION.md](MIGRATION.md) — Moving your wallet to a new Ender Router Pad.
