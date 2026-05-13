# DeFCoN Masternode Recovery Helper

Cautious recovery helper for DeFCoN masternodes with optional trusted addnodes, a PoSe-based temporary ban feature, and automatic recovery modes.

## Features

- Five guided modes:
  - Recovery without trusted addnodes
  - Recovery with trusted addnodes
  - Automatic recovery (fully automated, with trusted addnodes)
  - Automatic recovery (fully automated, without trusted addnodes)
  - Restore normal mode (revert helper-managed addnodes + optional PoSe unbans)
- Trusted addnodes:
  - Loaded from `trusted_addnodes.txt`
  - Randomized candidate selection and connectivity checks
  - Addnode verification runs **after** resync cleanup on a clean chain to ensure reliable results
  - Writes verified addnodes into a clearly marked block in `defcon.conf`
- Early bootstrap support:
  - Optional temporary early bootstrap addnode list built from `trusted_addnodes.txt`
  - Used automatically as a fallback if normal peer discovery fails after restart, and cleaned up again in restore mode
- Recovery safety:
  - Cautious daemon stop (systemd + RPC + optional kill) with stop verification
  - Optional disable/mask of the service to prevent unwanted auto-restarts
  - Optional lockfile removal and resync cleanup (`peers.dat`, `banlist.*`, `mncache.dat`, `llmq`, `blocks`, `chainstate`, `indexes`, `evodb`)
- PoSe integration (recovery with addnodes, automatic recovery with addnodes, restore mode):
  - Evaluates the deterministic masternode list via `protx list registered true` (includes PoSe-banned nodes)
  - Detects problematic masternodes:
    - PoSe-banned: `state.PoSeBanHeight > 0`
    - PoSe-score: `state.PoSePenalty > 0`
  - Derives the service IP from `state.service` (IPv4)
  - Optional creation of a temporary PoSe-based banlist that is applied with `setban` after cleanup and restart
  - Tracking file `recovery_pose_bans.txt` with states `prepared` and `applied` for clean unban in restore mode
- Monitoring & control:
  - Interactive sync monitoring menu (block height, `mnsync status`, summarized sync state, `debug.log` tail)
  - Interactive ProTx readiness menu after full sync (blockchain info, sync state, connections, peers, chain tips, optional log views)
  - Controller-wallet hint with a `protx update_service` template after sync and readiness checks, optionally prefilled with data from the deterministic MN list
  - Interactive safety check before restore (READY + fully synced MN)

## Files

- `dfcn-mn-recovery.sh` – main script
- `trusted_addnodes.txt` – optional trusted addnode list (used in mode 2, mode 3 and as early bootstrap source in mode 4)
- `recovery_pose_bans.txt` – optional PoSe banlist managed by the script (only if PoSe feature is used)

## Installation & Start

**Recommended one-liner (only for experienced users who review the code first):**

```bash
cd /root && \
wget -O dfcn-mn-recovery.sh "https://raw.githubusercontent.com/MrMarsellus/dfcn-masternode-recovery-helper/main/dfcn-mn-recovery.sh" && \
wget -O trusted_addnodes.txt "https://raw.githubusercontent.com/MrMarsellus/dfcn-masternode-recovery-helper/main/trusted_addnodes.txt" && \
chmod +x /root/dfcn-mn-recovery.sh && \
/root/dfcn-mn-recovery.sh
```

**Security:** Only download the script from trusted sources and read it before running it on a production masternode.

**Optional (manual, reviewable):**

```bash
cd /root
wget -O dfcn-mn-recovery.sh "https://raw.githubusercontent.com/MrMarsellus/dfcn-masternode-recovery-helper/main/dfcn-mn-recovery.sh"
wget -O trusted_addnodes.txt "https://raw.githubusercontent.com/MrMarsellus/dfcn-masternode-recovery-helper/main/trusted_addnodes.txt"
chmod +x /root/dfcn-mn-recovery.sh
```

Review the script (recommended):

```bash
nano /root/dfcn-mn-recovery.sh
```

Then run:

```bash
/root/dfcn-mn-recovery.sh
```

On startup, the script will:

- Show current defaults (user, data dir, binaries, service name, port)
- Validate that binaries and the main config file exist
- Ask you to choose a mode:
  - `1` = Recovery without trusted addnodes
  - `2` = Recovery with trusted addnodes
  - `3` = Automatic recovery (fully automated, with trusted addnodes)
  - `4` = Automatic recovery (fully automated, without trusted addnodes)
  - `5` = Restore normal mode

**Note:** `trusted_addnodes.txt` is required for mode 2 and mode 3, and used as an optional early-bootstrap source in mode 4.

## Mode 1 – Recovery without trusted addnodes

Goal: cautious recovery without touching `addnode=` and without PoSe-based banlist preparation.

Simplified flow:

1. Show current local status and service state.
2. Create a backup of `defcon.conf`.
3. Carefully stop daemon/service and verify that it is really stopped.
4. Optionally remove the lockfile.
5. Optionally delete local chain/peer/cache data (forced resync).
6. Start the daemon again.
7. Open the interactive sync monitoring menu until full sync is reached.
8. Open the interactive ProTx readiness menu to re-check chain and peer quality before `protx update_service`.
9. Show a controller-wallet hint for `protx update_service`.

In this mode, no `addnode=` entries are created or modified and no PoSe-based temporary banlist is prepared.

## Mode 2 – Recovery with trusted addnodes

Goal: like mode 1, but with a curated trusted addnode list and optional PoSe-based banlist preparation.

This mode uses a **two-phase restart** to ensure that addnode candidates are verified against a node that is already on the correct chain — not against a potentially stuck or forked local node.

Detailed flow:

**Phase 1 – Pre-stop preparation (RPC available)**

1. Select trusted addnode source: prefilled `trusted_addnodes.txt` or manual entry via nano editor.
2. Enter the reference block height of the correct chain (from explorer or a trusted node).
3. Show current local status and service state.
4. Create a backup of `defcon.conf`.
5. Optional PoSe feature: evaluate live deterministic masternode state via `protx list registered true` and optionally prepare a temporary PoSe-based banlist.

**Phase 2 – Stop and resync cleanup**

6. Carefully stop daemon/service and verify that it is really stopped.
7. Optionally remove the lockfile and delete selected recovery targets (resync cleanup).

**Phase 3 – First restart and addnode verification**

8. Start the daemon on the clean, resyncing chain (without managed addnodes).
9. Wait for RPC to become available.
10. Select addnode check mode (soft or hard).
11. Random candidate selection, port checks and peer checks using `addnode ... onetry` + `getpeerinfo`.
12. Optional hard/soft mode for addnode checks (multiple rounds, minimum number of successful checks).
13. Show good vs. rejected addnodes.

**Phase 4 – Write config and final restart**

14. On confirmation: write a clearly separated helper block with verified addnodes into `defcon.conf`.
15. Stop the daemon again (config-reload stop, same reliability as the cautious stop).
16. Start the daemon with the verified addnode configuration active.

**Phase 5 – Post-restart**

17. If a PoSe banlist was prepared: apply temporary bans via `setban` after restart.
18. Open the interactive sync monitoring menu until full sync is reached.
19. Open the interactive ProTx readiness menu to re-check chain and peer quality before `protx update_service`.
20. Show the controller-wallet hint for `protx update_service`.

This mode is intended for nodes that benefit from a curated peer set during recovery, and especially for nodes that were stuck on a wrong fork where pre-stop addnode checks would produce unreliable results.

## Mode 3 – Automatic recovery (with trusted addnodes)

Goal: fully automated variant of mode 2 with minimal interaction.

Key differences to mode 2:

- Addnodes are always loaded automatically from `trusted_addnodes.txt` (no manual nano input).
- Addnode check mode is fixed to **hard** (multiple rounds, stricter filtering).
- PoSe-based banlist preparation is fully automatic (no confirmations).
- The entire stop, cleanup and restart sequence runs without `ask_yes_no` prompts.
- The only manual input is the reference block height of the correct chain.

Simplified flow:

1. Load and validate `trusted_addnodes.txt`, show selected addnodes.
2. Prompt for reference block height (manual input, same as in mode 2).
3. Collect PoSe-problem nodes and prepare a PoSe-based banlist automatically if any are found.
4. Build a temporary early-bootstrap list in non-interactive mode; abort back to the main menu if no acceptable nodes are found (to avoid starting with zero peers).
5. Stop daemon/service automatically and perform cleanup of all relevant chain/peer/cache data.
6. Start the daemon on a clean chain, wait for RPC, and apply the early-bootstrap fallback if normal peer discovery does not produce peers.
7. Start an automatic sync wait loop (every 60 seconds print height + sync state) until `IsSynced=true` and `AssetName=MASTERNODE_SYNC_FINISHED`.
8. Run addnode verification in hard mode; abort if no trusted nodes pass the checks.
9. Write the verified addnodes into the managed block in `defcon.conf` and perform a controlled config reload (stop + start) to activate them.
10. Apply the prepared PoSe-banlist (if present) after restart and show the current sync state once.
11. Hand over to the interactive ProTx readiness menu and then to the controller-wallet hint.

This mode is intended for operators who want a mostly hands-off recovery using trusted addnodes, with only the reference height and controller-wallet transaction performed manually.

## Mode 4 – Automatic recovery (without trusted addnodes)

Goal: automatic variant of mode 1 that performs a cautious resync without changing `addnode=` settings and without PoSe-based banlist preparation.

Key properties:

- Uses the same cautious stop / cleanup / restart logic as mode 1, but without interactive confirmations.
- Does **not** write any helper-managed `addnode=` block into `defcon.conf`.
- Does **not** prepare or apply any PoSe-based banlist.
- The only manual input is the reference block height of the correct chain.

Simplified flow:

1. Show current local status and service state.
2. Create a backup of `defcon.conf`.
3. Prompt for the reference block height (from explorer or a trusted node).
4. Stop daemon/service automatically:
   - Disable the systemd service temporarily to prevent auto-restart (if enabled).
   - Stop via `systemctl stop`, try `defcon-cli stop`, then `pkill` / `pkill -9` as fallback.
   - Verify that process, service and RPC are really stopped.
5. Remove the lockfile if present.
6. Perform automatic cleanup of local chain/peer/cache data:
   - `peers.dat`, `banlist.*`, `mncache.dat`, `netfulfilled.dat`
   - `llmq`, `evodb`, `blocks`, `chainstate`, `indexes`
7. Restart the daemon on a clean chain and restore the service state as needed.
8. Optional early-bootstrap support:
   - If `trusted_addnodes.txt` exists, build a temporary early-bootstrap list in non-interactive mode.
   - Apply it as a fallback if normal peer discovery does not yield peers after restart.
9. Start an automatic sync wait loop:
   - Every 60 seconds print block height and `mnsync` sync state.
   - Loop ends when `IsSynced = true` and `AssetName = MASTERNODE_SYNC_FINISHED`.
10. Record the time when full sync was first reached (for later readiness checks).
11. Hand over to the interactive ProTx readiness menu:
   - You can repeat readiness checks for a few minutes.
   - If the node was not PoSe-banned and you only needed a fresh sync, you can skip the `protx update_service` step with `x`.
12. Show the final local status snapshot and the controller-wallet hint for `protx update_service`.

This mode is intended for nodes that mainly need a fresh, clean sync on the correct chain, without touching their addnode configuration and without PoSe-based ban management.

## Mode 5 – Restore normal mode

Goal: revert helper changes once the node is stable again.

1. Safety check:
   - Read `masternode status` and `mnsync status`.
   - Automatically continue if:
     - `state = READY`
     - Sync stage `MASTERNODE_SYNC_FINISHED`
     - `IsSynced = true`
   - Otherwise warn and let you choose:
     - check status again
     - continue anyway (not recommended)
     - exit without changes
2. Show local status and service state.
3. Create a backup of `defcon.conf`.
4. Carefully stop daemon/service and verify the stop.
5. Optionally remove the lockfile.
6. PoSe unbans:
   - If `recovery_pose_bans.txt` exists, only those IPs are unbanned via `setban "<ip>" remove`.
   - IPs that are no longer banned are reported as info only.
   - The file can then be deleted or kept.
7. Remove the helper-managed addnode block from `defcon.conf`.
8. Restart, show final status and optionally restore the original service state.

## Sync monitoring menu (all recovery modes)

Commands:

- `g` – `getblockcount`
- `s` – `mnsync status`
- `p` – summarized view (block height, sync stage, sync flags)
- `l` – last 30 lines of `debug.log`
- `x` – "node is fully synchronized, continue to the next step"

Before using `x`, the node should meet all of the following conditions:

- Local block height ≈ reference (explorer / reference node)
- Sync stage `MASTERNODE_SYNC_FINISHED`
- `Blockchain synced` = `true`
- `Masternode synced` = `true`

The recommended way is to use `p` repeatedly and only continue with `x` once everything is fully synced and all flags are `true`.

## ProTx readiness menu (all recovery modes)

After the regular sync menu, the script can open an additional readiness menu before showing the `protx update_service` hint.

Purpose:

- Re-check whether the node is not only fully synced, but also in a stable enough state for `protx update_service`
- Allow repeated checks over a few minutes
- Still allow the operator to skip this step consciously

Typical checks include:

- `getblockchaininfo` (`blocks`, `headers`, `time` for best-block age)
- `mnsync status` (`IsBlockchainSynced`, `IsSynced`, `IsFailed`)
- `getnetworkinfo` (`connections`)
- `getpeerinfo` (peer count, max ping, peers above a configured ping threshold)
- `getchaintips` (for example `headers-only`, `valid-fork`, `valid-headers` chain tips)
- Best-block age vs. a configurable max tip age

Commands:

- `r` – run the readiness check
- `l` – last 30 lines of `debug.log`
- `j` – last 30 lines of `journalctl` for the service
- `n` – abort here and restart the recovery helper from the beginning
- `x` – skip the readiness step and continue

The readiness check itself is fast (only local RPC calls), but it is often useful to repeat it for a few minutes until the node looks stable enough.

## Controller wallet step

After the sync and readiness phases, the script prints a `protx update_service` command template for the controller wallet.

Where possible, the script tries to:

- Detect the local masternode service IP from `defcon.conf` and `masternode status`
- Find the matching deterministic MN entry via `protx list registered true`
- Prefill:
  - `PROTX_HASH` from `.proTxHash`
  - `IP:PORT` from `.state.service`
  - `BLS_SECRET_KEY` from `masternodeblsprivkey` in `defcon.conf`
  - `FEE_SOURCE_ADDRESS` with the current `state.payoutAddress` as a convenient default

You can replace the suggested fee source address with any funded address from the controller wallet before sending the transaction.

## Status

Work in progress – use carefully and always with backups on production nodes.
