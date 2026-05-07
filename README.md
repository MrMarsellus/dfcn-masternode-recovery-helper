# DeFCoN Masternode Recovery Helper

Cautious recovery helper for DeFCoN masternodes with optional trusted addnodes and a PoSe-based temporary ban feature.

## Features

- Three guided modes:
  - Recovery without trusted addnodes
  - Recovery with trusted addnodes
  - Restore normal mode (revert helper-managed addnodes + optional PoSe unbans)
- Trusted addnodes:
  - Loaded from `trusted_addnodes.txt`
  - Randomized candidate selection and connectivity checks
  - Addnode verification runs **after** resync cleanup on a clean chain to ensure reliable results
  - Writes verified addnodes into a clearly marked block in `defcon.conf`
- Recovery safety:
  - Cautious daemon stop (systemd + RPC + optional kill) with stop verification
  - Optional disable/mask of the service to prevent unwanted auto-restarts
  - Optional lockfile removal and resync cleanup (`peers.dat`, `banlist.*`, `mncache.dat`, `llmq`, `blocks`, `chainstate`, `indexes`, `evodb`)
- PoSe integration (recovery with addnodes + restore mode):
  - Evaluates the deterministic masternode list via `protx list registered true` (includes PoSe-banned nodes)
  - Detects problematic masternodes:
    - PoSe-banned: `state.PoSeBanHeight > 0`
    - PoSe-score: `state.PoSePenalty > 0`
  - Derives the service IP from `state.service` (IPv4)
  - Optional creation of a temporary PoSe-based banlist that is applied with `setban` after cleanup and restart
  - Tracking file `recovery_pose_bans.txt` with states `prepared` and `applied` for clean unban in restore mode
- Monitoring & control:
  - Interactive sync monitoring menu (block height, `mnsync status`, summarized sync state, `debug.log` tail)
  - Interactive ProTx readiness menu after full sync (`getblockchaininfo`, `mnsync status`, connections, peers, `getchaintips`, optional log views)
  - Controller-wallet hint with `protx update_service` template after sync and readiness checks
  - Interactive safety check before restore (READY + fully synced MN)

## Files

- `dfcn-mn-recovery.sh` – main script
- `trusted_addnodes.txt` – optional trusted addnode list (used only in mode 2)
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
wget -O trusted_addnodes.txt "https://raw.githubusercontent.com/MrMarsellus/dfcn-mn-recovery-helper/main/trusted_addnodes.txt"
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
  - `3` = Restore normal mode

**Note:** `trusted_addnodes.txt` is only required for mode 2.

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
15. Stop the daemon again (silent config-reload stop, same reliability as the cautious stop).
16. Start the daemon with the verified addnode configuration active.

**Phase 5 – Post-restart**

17. If a PoSe banlist was prepared: apply temporary bans via `setban` after restart.
18. Open the interactive sync monitoring menu until full sync is reached.
19. Open the interactive ProTx readiness menu to re-check chain and peer quality before `protx update_service`.
20. Show the controller-wallet hint for `protx update_service`.

This mode is intended for nodes that benefit from a curated peer set during recovery, and especially for nodes that were stuck on a wrong fork where pre-stop addnode checks would produce unreliable results.

## Mode 3 – Restore normal mode

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

- `getblockchaininfo` (`blocks`, `headers`, `initialblockdownload`)
- `mnsync status` (`IsBlockchainSynced`, `IsSynced`, `IsFailed`)
- `getnetworkinfo` (`connections`)
- `getpeerinfo` (peer count / simple ping summary)
- `getchaintips` (for example `headers-only` chain tips)

Commands:

- `r` – run the readiness check
- `l` – last 30 lines of `debug.log`
- `j` – last 30 lines of `journalctl` for the service
- `x` – skip the readiness step and continue

The readiness check itself is fast (only local RPC calls), but it is often useful to repeat it for a few minutes until the node looks stable enough.

## Status

Work in progress – use carefully and always with backups on production nodes.
