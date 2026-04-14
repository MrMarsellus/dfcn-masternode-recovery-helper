# DeFCoN Masternode Recovery Helper

Cautious recovery helper for DeFCoN masternodes with trusted addnode support.

## Features

- Loads a trusted addnode list from a separate file
- Randomized testing of trusted nodes and automatic filtering of good peers
- Careful daemon stop and restart handling (RPC stop → systemd → optional kill)
- Optional peer and cache cleanup (peers.dat, mncache, llmq, blocks, chainstate, indexes, evodb)
- Temporary trusted-peer mode by writing verified addnodes into `defcon.conf`
- Interactive monitoring menu to track sync progress before continuing recovery
- Guided controller wallet step for `protx update_service` after full sync
- Restore mode to remove recovery helper settings and return to normal configuration
- Interactive safety check before restore mode (checks READY + full masternode sync)
- Clear prompts, status messages, and confirmation steps to avoid accidental changes

## Files

- `dfcn-mn-recovery.sh` – main recovery script
- `trusted_addnodes.txt` – trusted addnode list

## Usage

### Manual download and run (recommended)

```bash
cd /root
wget -O dfcn-mn-recovery.sh "https://raw.githubusercontent.com/MrMarsellus/dfcn-masternode-recovery-helper/main/dfcn-mn-recovery.sh"
wget -O trusted_addnodes.txt "https://raw.githubusercontent.com/MrMarsellus/dfcn-masternode-recovery-helper/main/trusted_addnodes.txt"
chmod +x /root/dfcn-mn-recovery.sh
```

# Optional: review the script before running it
```bash
nano /root/dfcn-mn-recovery.sh
/root/dfcn-mn-recovery.sh
```

During startup, the script will:

- Show current defaults (user, data dir, binaries, service name, port)
- Validate that binaries and required files exist
- Ask you to choose a mode:
  - `1` = Recovery mode
  - `2` = Restore normal mode

### Quick one‑liner (advanced users only)

If you understand the security implications of downloading and executing remote scripts, you can run the helper in one step:

```bash
cd /root && \
wget -O dfcn-mn-recovery.sh "https://raw.githubusercontent.com/MrMarsellus/dfcn-masternode-recovery-helper/main/dfcn-mn-recovery.sh" && \
wget -O trusted_addnodes.txt "https://raw.githubusercontent.com/MrMarsellus/dfcn-masternode-recovery-helper/main/trusted_addnodes.txt" && \
chmod +x /root/dfcn-mn-recovery.sh && \
/root/dfcn-mn-recovery.sh
```

> **Security notice:** Always review the script before running it on a production masternode.  
> You can open `dfcn-mn-recovery.sh` in an editor (for example `nano dfcn-mn-recovery.sh`) and verify its contents before execution.

## Recovery mode overview (Mode 1)

When you select **Recovery mode**, the script will:

1. Load and validate trusted addnodes from `trusted_addnodes.txt`.
2. Randomly select a subset of candidates and test connectivity and peer acceptance.
3. Show good and rejected addnodes and write the verified ones into `defcon.conf` in a managed section (if you confirm).
4. Carefully stop the daemon and service, optionally removing the lock file.
5. Optionally delete local blockchain, peer and cache data to force a clean resync.
6. Start the daemon again with the updated configuration.
7. Open the interactive monitoring menu.

### Interactive monitoring menu

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
- Display a controller‑wallet hint with the `protx update_service` command template

You must run the `protx update_service` command in your controller wallet and wait for the ProTx transaction to be confirmed before you expect the masternode to recover from a PoSe‑banned state.

## Restore mode overview (Mode 2)

When you select **Restore normal mode**, the script will:

1. Run an interactive safety check (`check_ready_for_restore`):
   - Read `masternode status` and `mnsync status`
   - Show current `state`, `status`, sync stage and `IsSynced` flag
   - If the node is **READY**, has sync stage `MASTERNODE_SYNC_FINISHED` and `IsSynced` is `true`, it continues automatically
   - Otherwise, it warns and lets you choose:
     - `1` – check status again
     - `2` – continue with restore mode anyway (not recommended)
     - `3` – exit without making changes
2. Show the current local status and service state.
3. Stop the daemon cautiously and optionally remove the lock file.
4. Remove the managed trusted‑addnode section from `defcon.conf`.
5. Start the daemon again with the normal configuration.
6. Show a final local status snapshot.

At the end of a **recovery** run, the script will also remind you:

> Once your masternode has been stable for several days, run this script again and select **"Restore normal mode"** to revert from recovery settings.

## Status

Work in progress.
