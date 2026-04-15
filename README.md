# DeFCoN Masternode Recovery Helper

Cautious recovery helper für DeFCoN-Masternodes mit optionalen trusted Addnodes und PoSe-basiertem temporären Ban-Feature.

## Features

- Drei geführte Modi:
  - Recovery ohne trusted addnodes
  - Recovery mit trusted addnodes
  - Restore normal mode (Addnode-Revert + optionale PoSe-Unbans)
- Trusted-Addnodes:
  - Laden aus `trusted_addnodes.txt`
  - Randomisierte Kandidatenauswahl und Connectivity-Checks
  - Schreiben geprüfter Addnodes in einen klar markierten Block in `defcon.conf`
- Recovery-Sicherheit:
  - Vorsichtiger Daemon-Stop (systemd + RPC + optional kill) mit Stop-Verifikation
  - Optionales Deaktivieren/Maskieren des Services gegen Auto-Restarts
  - Optionales Entfernen von Lockfile und Resync-Cleanup (`peers.dat`, `banlist.*`, `mncache.dat`, `llmq`, `blocks`, `chainstate`, `indexes`, `evodb`)
- PoSe-Integration:
  - Auswertung der deterministischen Masternodeliste via `protx list registered true` (inkl. PoSe-banned Nodes) 
  - Erkennung problematischer MNs:
    - PoSe-banned: `state.PoSeBanHeight > 0`
    - PoSe-score: `state.PoSePenalty > 0`
  - Ableitung der Service-IP aus `state.service` (IPv4) 
  - Optionale Erstellung einer temporären PoSe-basierten Banliste, die nach Cleanup und Neustart per `setban` angewendet wird 
  - Tracking-Datei `recovery_pose_bans.txt` mit Zuständen `prepared` und `applied` für sauberes Unban im Restore-Mode
- Monitoring & Steuerung:
  - Interaktives Monitoring-Menü (Blockhöhe, `mnsync status`, zusammengefasster Sync-Status, `debug.log`-Tail)
  - Controller-Wallet-Hinweis mit `protx update_service`-Template nach vollem Sync 
  - Interaktiver Safety-Check vor Restore (READY + vollständiger MN-Sync)

## Dateien

- `dfcn-mn-recovery.sh` – Hauptscript
- `trusted_addnodes.txt` – optionale trusted Addnode-Liste (nur für Mode 2)
- `recovery_pose_bans.txt` – optionale, vom Script verwaltete PoSe-Banliste (nur wenn PoSe-Feature genutzt wird)

## Installation & Start

**Empfohlen (manuell, prüfbar):**

```bash
cd /root
wget -O dfcn-mn-recovery.sh "https://raw.githubusercontent.com/MrMarsellus/dfcn-masternode-recovery-helper/main/dfcn-mn-recovery.sh"
wget -O trusted_addnodes.txt "https://raw.githubusercontent.com/MrMarsellus/dfcn-masternode-recovery-helper/main/trusted_addnodes.txt"
chmod +x /root/dfcn-mn-recovery.sh
```

Script prüfen (empfohlen):

```bash
nano /root/dfcn-mn-recovery.sh
```

Dann ausführen:

```bash
/root/dfcn-mn-recovery.sh
```

Beim Start zeigt das Script:

- aktuelle Defaults (User, Datadir, Binaries, Service, Port)
- Existenz der Binaries und der Config
- Modus-Auswahl:
  - `1` = Recovery ohne trusted addnodes
  - `2` = Recovery mit trusted addnodes
  - `3` = Restore normal mode

> **Hinweis:** `trusted_addnodes.txt` ist nur für Mode 2 erforderlich.

**Optionaler One-Liner (nur für erfahrene Nutzer, die den Code vorher geprüft haben):**

```bash
cd /root && \
wget -O dfcn-mn-recovery.sh "https://raw.githubusercontent.com/MrMarsellus/dfcn-masternode-recovery-helper/main/dfcn-mn-recovery.sh" && \
wget -O trusted_addnodes.txt "https://raw.githubusercontent.com/MrMarsellus/dfcn-masternode-recovery-helper/main/trusted_addnodes.txt" && \
chmod +x /root/dfcn-mn-recovery.sh && \
/root/dfcn-mn-recovery.sh
```

> **Security:** Lade das Script nur aus vertrauenswürdigen Quellen und lies es, bevor du es auf einem produktiven Masternode ausführst.

## Mode 1 – Recovery ohne trusted addnodes

Ablauf (vereinfacht):

1. Lokalen Status und Servicestatus anzeigen.
2. Backup von `defcon.conf` erstellen.
3. Daemon/Service vorsichtig stoppen und stoppen verifizieren.
4. Optional Lockfile entfernen.
5. Optional lokale Chain-/Peer-/Cache-Daten löschen (erzwungener Resync).
6. Daemon neu starten.
7. Optional: PoSe-Feature
   - Live-Auswertung `protx list registered true` und Anzeige problematischer MNs 
   - bei Bestätigung: Schreiben von `recovery_pose_bans.txt` (State `prepared`), Anwendung der Bans nach Neustart mit `setban` (State `applied`) 
8. Interaktives Monitoring-Menü bis vollständiger Sync.
9. Hinweis für `protx update_service` im Controller-Wallet. 

In diesem Modus werden keine `addnode=`-Einträge erstellt oder verändert.

## Mode 2 – Recovery mit trusted addnodes

Zusätzlich zu Mode 1:

1. Laden und Validieren von `trusted_addnodes.txt`.
2. Randomisierte Kandidatenauswahl, Port-Check und Peer-Check per `addnode ... onetry` + `getpeerinfo`. 
3. Anzeige guter vs. verworfener Addnodes.
4. Bei Bestätigung: Schreiben eines klar abgegrenzten Helper-Blocks mit geprüften Addnodes in `defcon.conf`.
5. Stop, Cleanup, Restart wie in Mode 1.
6. Optional: PoSe-Feature wie oben (Vorbereiten → Anwenden nach Restart).
7. Monitoring und Controller-Wallet-Schritt wie in Mode 1.

Dieser Modus ist für Nodes gedacht, die beim Wiederaufbau von einem kuratierten Peer-Set profitieren.

## Mode 3 – Restore normal mode

Ziel: Helper-Einstellungen zurückbauen, wenn der Node wieder stabil läuft.

1. Safety-Check:
   - `masternode status` + `mnsync status` lesen.
   - Automatisches Weiter, wenn:
     - `state = READY`
     - Stage `MASTERNODE_SYNC_FINISHED`
     - `IsSynced = true` 
   - Sonst Warnung + Auswahl:
     - nochmal prüfen
     - trotzdem fortfahren (nicht empfohlen)
     - abbrechen
2. Lokalen Status + Service anzeigen.
3. Backup von `defcon.conf`.
4. Vorsichtiger Stop + Stop-Verifikation.
5. Optional Lockfile entfernen.
6. PoSe-Unbans:
   - Falls `recovery_pose_bans.txt` existiert, werden nur diese IPs per `setban "<ip>" remove` zurückgenommen. 
   - Nicht (mehr) gebannte IPs werden nur informativ gemeldet.
   - Datei kann anschließend gelöscht oder behalten werden.
7. Entfernen des Helper-Addnode-Blocks aus `defcon.conf`.
8. Neustart, finaler Status und optionales Wiederherstellen des ursprünglichen Service-States.

## Monitoring-Menü (alle Modi)

Befehle:

- `g` – `getblockcount`
- `s` – `mnsync status`
- `p` – zusammengefasste Anzeige (Blockhöhe, Verificationprogress, Stage, Flags)
- `l` – letzte 30 Zeilen aus `debug.log`
- `x` – „Node ist fertig synchronisiert, weiter“

Vor `x` sollte gelten:

- Blockhöhe ≈ Referenz (Explorer/Referenznode)
- Stage `MASTERNODE_SYNC_FINISHED`
- `Blockchain synced` = `true`
- `Masternode synced` = `true` 

## Status

Work in progress – bitte nur bewusst und mit Backup auf produktiven Nodes einsetzen.
