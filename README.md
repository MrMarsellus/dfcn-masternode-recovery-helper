# DeFCoN Masternode Recovery Helper

Cautious recovery helper for DeFCoN masternodes with optional trusted addnode support.

## Features

- Three guided modes:
  - Recovery without trusted addnodes
  - Recovery with trusted addnodes
  - Restore normal mode for helper-managed addnode recovery
- Loads a trusted addnode list from a separate file when Recovery with trusted addnodes is used
- Randomized testing of trusted nodes and automatic filtering of good peers
- Careful daemon stop and restart handling with additional stop verification
- Optional temporary service disable or mask to prevent unwanted auto-restarts during recovery
- Optional peer and cache cleanup (`peers.dat`, `mncache.dat`, `llmq`, `blocks`, `chainstate`, `indexes`, `evodb`)
- Optional temporary trusted-peer mode by writing verified addnodes into `defcon.conf`
- Interactive monitoring menu to track sync progress before continuing recovery
- Guided controller wallet step for `protx update_service` after full sync
- Restore normal mode to remove helper-managed addnode settings and return to normal configuration
- Interactive safety check before restore normal mode (checks READY + full masternode sync)
- Clear prompts, status messages, and confirmation steps to avoid accidental changes

## Files

- `dfcn-mn-recovery.sh` – main recovery script
- `trusted_addnodes.txt` – trusted addnode list used only for **Recovery with trusted addnodes**

## Usage

### Quick one-liner (advanced users only)

If you understand the security implications of downloading and executing remote scripts, you can run the helper in one step:

```bash
cd /root && \
wget -O dfcn-mn-recovery.sh "https://raw.githubusercontent.com/MrMarsellus/dfcn-masternode-recovery-helper/main/dfcn-mn-recovery.sh" && \
wget -O trusted_addnodes.txt "https://raw.githubusercontent.com/MrMarsellus/dfcn-masternode-recovery-helper/main/trusted_addnodes.txt" && \
chmod +x /root/dfcn-mn-recovery.sh && \
/root/dfcn-mn-recovery.sh
```

> **Security notice:** Always review the script before running it on a production masternode.  
> You can open `dfcn-mn-recovery.sh` in an editor (for example `nano /root/dfcn-mn-recovery.sh`) and verify its contents before execution.

During startup, the script will:

- Show current defaults (user, data dir, binaries, service name, port)
- Validate that binaries and the main config file exist
- Ask you to choose a mode:
  - `1` = Recovery (without trusted addnodes)
  - `2` = Recovery with trusted addnodes
  - `3` = Restore normal mode

> **Note:** `trusted_addnodes.txt` is only required for **Mode 2**.

### Manual download and run (recommended)

```bash
cd /root && wget -O dfcn-mn-recovery.sh "https://raw.githubusercontent.com/MrMarsellus/dfcn-masternode-recovery-helper/main/dfcn-mn-recovery.sh" && wget -O trusted_addnodes.txt "https://raw.githubusercontent.com/MrMarsellus/dfcn-masternode-recovery-helper/main/trusted_addnodes.txt" && chmod +x /root/dfcn-mn-recovery.sh
```

```bash
/root/dfcn-mn-recovery.sh
```

### Optional: review the script before running it

```bash
nano /root/dfcn-mn-recovery.sh
```

```bash
/root/dfcn-mn-recovery.sh
```

## Recovery without trusted addnodes (Mode 1)

When you select **Recovery (without trusted addnodes)**, the script will:

1. Show the current local status and service state.
2. Create a backup of `defcon.conf`.
3. Carefully stop the daemon and service, including a verification step to confirm that the node is really stopped before destructive actions continue.
4. Optionally remove the lock file.
5. Optionally delete local blockchain, peer and cache data to force a clean resync.
6. Start the daemon again.
7. Open the interactive monitoring menu.

This mode does **not** load `trusted_addnodes.txt` and does **not** modify `addnode=` settings in `defcon.conf`.

## Recovery with trusted addnodes (Mode 2)

When you select **Recovery with trusted addnodes**, the script will:

1. Load and validate trusted addnodes from `trusted_addnodes.txt`.
2. Randomly select a subset of candidates and test connectivity and peer acceptance.
3. Show good and rejected addnodes.
4. Write the verified addnodes into `defcon.conf` in a helper-managed section (if you confirm).
5. Show the current local status and service state.
6. Create a backup of `defcon.conf`.
7. Carefully stop the daemon and service, including a verification step to confirm that the node is really stopped before destructive actions continue.
8. Optionally remove the lock file.
9. Optionally delete local blockchain, peer and cache data to force a clean resync.
10. Start the daemon again with the updated configuration.
11. Open the interactive monitoring menu.

This mode is intended for nodes that may benefit from a temporary curated peer set during recovery.

## Interactive monitoring menu

In the monitoring menu you can:

- `g` – get block height
- `s` – show raw `mnsync status`
- `p` – show summarized sync progress (block height, sync stage, flags)
- `l` – show the last 30 lines of `debug.log`
- `x` – confirm that sync is complete and continue with the next step

Before using `x`, the node should meet **all** of the following conditions:

- Local block height matches the reference block height (explorer / trusted reference)
- `Masternode sync stage` is `MASTERNODE_SYNC_FINISHED`
- `Blockchain synced` is `true`
- `Masternode synced` is `true`

Once you continue with `x`, the script will:

- Show a final local status snapshot
- Display a controller-wallet hint with the `protx update_service` command template

You must run the `protx update_service` command in your controller wallet and wait for the ProTx transaction to be confirmed before you expect the masternode to recover from a PoSe-banned state.

## Restore normal mode (Mode 3)

When you select **Restore normal mode**, the script will:

1. Run an interactive safety check (`check_ready_for_restore`):
   - Read `masternode status` and `mnsync status`
   - Show current `state`, `status`, sync stage and `IsSynced` flag
   - If the node is **READY**, has sync stage `MASTERNODE_SYNC_FINISHED` and `IsSynced` is `true`, it continues automatically
   - Otherwise, it warns and lets you choose:
     - `1` – check status again
     - `2` – continue with restore normal mode anyway (not recommended)
     - `3` – exit without making changes
2. Show the current local status and service state.
3. Create a backup of `defcon.conf`.
4. Stop the daemon cautiously and verify that it is really stopped.
5. Optionally remove the lock file.
6. Remove the helper-managed trusted addnode section from `defcon.conf`.
7. Start the daemon again with the normal configuration.
8. Show a final local status snapshot.

This mode is intended to revert changes made by **Recovery with trusted addnodes**.

## Service handling notes

During recovery or restore, the script may optionally:

- stop the systemd service before attempting daemon shutdown
- temporarily disable the service to prevent unwanted auto-restarts
- optionally mask the service as a stronger fallback if the daemon refuses to stay stopped

If the script changed the service state during the session, it will ask at the end whether it should restore the service state and start the service again.

## End-of-run note

At the end of a recovery run, the script will remind you:

> Once your masternode has been stable for several days, run this script again and select **"Restore normal mode"** if you previously used **"Recovery with trusted addnodes"** and want to revert from helper-managed recovery settings.

## Status

Work in progress.
