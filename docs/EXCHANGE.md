# The Great Ami Exchange

A CC:Tweaked computer that swaps FTB quest coins (the `/coins` command from
Magic Coins) for AmiCoin and back, at a fixed rate: **1 coin = 400 uAMI** in
both directions.

It is a trimmed copy of AmiStore (`ami/shop`): same wallet key, mesh, node
manager and invoice code. The listings, ME bridge, vending tray and printer are
gone; a command block does the coin side.

## Build

| Side | Block | Notes |
|---|---|---|
| BACK | Modem / Ender Router | any side is found; BACK matches AmiStore |
| TOP | Advanced Monitor | optional status board |
| any | Command block | runs `/coins` |

Server requirements:

- `command_block_enabled = true` under `[peripheral]` in
  `computercraft-server.toml` (it is off by default).
- `enable-command-block=true` in `server.properties`.

A Command Computer also works and needs no command block, but only operators
can open its terminal, so it is no use as a public counter.

## Protect the build first

With that CC:Tweaked option on, **any computer touching a command block can run
any server command**. Before opening the exchange:

- Claim/protect the area so players can only right-click the computer. They
  must not be able to break it, or place their own computer or disk drive next
  to the command block.
- Leave autostart on. The program disables Ctrl+T, turns off disk startup,
  writes `/startup.lua` and reboots itself if it crashes, so a player never
  reaches a shell.

## Install and open

```
wget run https://raw.githubusercontent.com/Teru-dot-png/amicoin-fullpower/refs/heads/main/installexchange.lua
```

1. Choose `[I]` Install, then reboot.
2. Set the admin password when asked.
3. On the main screen press `` ` `` (backtick) and enter the password.
4. `[N]` Node manager: add your node.
5. `[T]` Safety test (see below). Trading stays closed until it passes.
6. Send AMI to the exchange (its name is registered in Ami-DNS) so it can pay
   for coins players sell. Coins players buy add to that reserve.

## How a trade works

**Buy coins (AMI to coins).** The player types their Minecraft name and an
amount. The exchange sends a normal invoice to the wallet registered under that
name; the player accepts it with `[Y]`. Once the payment shows on the ledger the
command block runs `coins add <name> <amount>`. If that command fails, the AMI
is sent back.

**Sell coins (coins to AMI).** The player types their name and an amount, checks
the wallet address shown, and confirms. One command both checks that the player
is standing at the exchange alone and removes the coins; then the AMI is sent.
If the payout fails, the coins are given back.

## Why the safety test exists

The computer cannot read a coin balance, and a command block only reports
whether a command ran without an error. `/coins remove` does **not** error when
a player has too few coins: it prints "insufficient funds", changes nothing and
still counts as a success. Trusting that would let anyone sell coins they do
not have.

So every `/coins` command is run through `execute store result score`, which
records how many players the command actually changed (1 or 0) in a scoreboard
objective called `amiex`, and the exchange checks that score.

The test adds and removes one coin on the admin's account, then tries to remove
one more coin than the admin holds. It passes only if the first two are seen as
changes and the last one is seen as no change. Enter your exact balance from
`/coins get`; a number that is too low makes the last step fail. Re-run the
test after updating the modpack.

## Other safeguards

- Only a valid Minecraft name (letters, digits, `_`, up to 16) and a whole
  number ever reach a command, so nothing typed at the terminal can inject one.
- Ami-DNS names are not proof of identity: any wallet can register any name,
  and a later registration replaces an earlier one. So coins are only taken
  from a player who is within range of the command block with nobody else in
  range, and the payout address is shown to check against the `Addr:` in the
  wallet's title bar.
- A payment acknowledgement is only a hint. Coins are released when the
  exchange's balance on the node has actually gone up by the invoice total.

## Settings

Rate, max trade and distance are in the admin panel. The command templates are
in `/ami/exchange/config.json` (`cmd_add`, `cmd_remove`; `%s` is the player
name, `%d` the amount). Every trade and every failure is written to
`/ami/exchange/exchange.log` (`[L]` in the admin panel); lines marked `OWED` or
`DISPUTE` need an admin to settle by hand.

## Test

```
lua5.4 tools/cc_harness/test_exchange.lua
```
