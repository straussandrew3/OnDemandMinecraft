# Decommission Log

**Date:** 2026-07-04  
**Executor:** Claude Code (claude-sonnet-4-6) on Andrew's local machine

## Summary

All Minecraft-related AWS resources terminated. World backup verified
locally before any destructive action. The account still has residual
charges (~$2.72/mo) from KMS, EFS, and Route 53 that are **not related
to this project** — noted in the final sweep section below.

## What was non-standard

`decommission.sh` was not used because the EC2 root volume had already
been detached and the instance had no storage attached. Instead, each
step was executed manually via `aws` CLI. The volume was recovered from
the `mc1` snapshot, temporarily re-attached to the instance to confirm
SSH was not possible (original `.pem` key did not match `authorized_keys`
in the snapshot), then re-attached to a fresh rescue instance to extract
the world.

## Steps executed

### 1 — World backup

- Restored `snap-02843dd620b4d5c02` (mc1, 30 GB) to a new EBS volume
  (`vol-0a75a2bbee7aa2ce6`) in `us-east-1f`.
- Attached the volume to original instance `i-0538826f40837f061` as root
  and started it — SSH failed (key mismatch; neither `minecraft.pem` nor
  `minecraft_config.pem` from the data-transfer folder matched
  `authorized_keys` baked into the snapshot).
- Launched fresh rescue instance `i-0d2f195806f93224b` (t3.nano,
  Ubuntu 22.04) in `us-east-1f` with a generated `mc-rescue-temp` key pair.
- Re-attached `vol-0a75a2bbee7aa2ce6` as `/dev/sdf` to the rescue instance.
- Mounted at `/mnt/mc`; world found at `/mnt/mc/home/minecraft/world`.
- SCP'd the following to `~/Documents/minecraft-world-backup/` on local machine:
  - `world/` (14 MB)
  - `server.properties`, `ops.json`, `whitelist.json`,
    `banned-players.json`, `banned-ips.json`, `usercache.json`, `eula.txt`
  - `server.jar` (44 MB, original server binary — used for verify step)

### 2 — World backup verification

Ran `verify_world_backup.sh` with the original `server.jar` and
OpenJDK 21 (Homebrew `openjdk@21`).

**Result: `LOADED`** — world started cleanly, safe to proceed.

### 3 — Resource termination / deletion

| Resource | ID | Action | Result |
|---|---|---|---|
| Restored volume | `vol-0a75a2bbee7aa2ce6` | Deleted | ✅ |
| Rescue instance | `i-0d2f195806f93224b` | Terminated | ✅ |
| Minecraft instance (tagged) | `i-0538826f40837f061` | Terminated | ✅ |
| Minecraft instance (secondary) | `i-06108c86b0163eb23` | Terminated | ✅ |
| Snapshot mc1 (30 GB) | `snap-02843dd620b4d5c02` | Deleted | ✅ |
| Snapshot mc2 (8 GB) | `snap-08ce6141b48058037` | Deleted | ✅ |
| Snapshot mc3 (8 GB) | `snap-0a246376530d90a86` | Deleted | ✅ |
| Snapshot mc4 (8 GB) | `snap-056fed8efee4a842c` | Deleted | ✅ |
| AWS budget alert | `AWS budget` ($10/mo) | Deleted | ✅ |
| Temp key pair | `mc-rescue-temp` | Deleted | ✅ |

Elastic IPs: none present.

## World backup location

`~/Documents/minecraft-world-backup/` on Andrew's local machine.

Contains the full world folder plus all server config files and the
original `server.jar`. Keep this somewhere with redundancy (Time Machine,
iCloud, Google Drive, etc.) if you want a long-term copy.

## Final resource sweep (2026-07-04)

Checked: EC2 instances, Elastic IPs, EBS volumes, snapshots, load
balancers, RDS, S3, Route 53, NAT gateways, budgets.

**All Minecraft-related resources confirmed gone.** Remaining items:

| Resource | Detail | Monthly cost | Notes |
|---|---|---|---|
| Route 53 hosted zone | `minecraft.andrewbrett.xyz.` | ~$0.50 | DNS for this server — can delete |
| Route 53 hosted zone | `andrewbrett.xyz.` | ~$0.50 | Root domain — likely intentional |
| S3 bucket | `cdk-hnb659fds-assets-996039603186-us-east-1` | ~$0 | CDK bootstrap bucket, negligible |
| KMS | 1 customer-managed key | ~$1.00 | Not Minecraft — from another project |
| EFS | Elastic File System | ~$0.41 | Not Minecraft — from another project |

The `minecraft.andrewbrett.xyz.` hosted zone is the one item directly
tied to this project. Deleting it saves ~$0.50/mo. The others are
unrelated to this project and should be managed separately.

## Cost history (Jul 2025 – Jun 2026, by service)

All amounts in USD (unblended). $0.00 entries omitted. "EC2 - Other"
covers EBS volume/snapshot storage and data transfer; it was high while
instances were actively running and dropped after the volumes were
snapshotted and deleted in Nov 2025.

| Month | KMS | EC2-Other | EFS | Route 53 | Registrar | S3 | Tax | **Total** |
|---|---|---|---|---|---|---|---|---|
| Jul 2025 | 0.99 | 5.08 | 0.41 | 1.00 | — | <0.01 | 0.78 | **8.26** |
| Aug 2025 | 0.98 | 5.08 | 0.41 | 1.00 | — | <0.01 | 0.78 | **8.25** |
| Sep 2025 | 1.00 | 5.08 | 0.41 | 1.00 | — | <0.01 | 0.78 | **8.27** |
| Oct 2025 | 0.99 | 5.08 | 0.41 | 1.00 | 18.00 | <0.01 | 0.78 | **26.26** |
| Nov 2025 | 0.99 | 0.45 | 0.41 | 1.00 | — | <0.01 | 0.23 | **3.08** |
| Dec 2025 | 0.99 | 0.32 | 0.41 | 1.00 | — | <0.01 | 0.22 | **2.94** |
| Jan 2026 | 0.99 | 0.32 | 0.41 | 1.00 | — | <0.01 | 0.22 | **2.94** |
| Feb 2026 | 0.99 | 0.32 | 0.41 | 1.00 | — | <0.01 | 0.22 | **2.94** |
| Mar 2026 | 0.99 | 0.32 | 0.41 | 1.00 | — | <0.01 | 0.30 | **3.02** |
| Apr 2026 | 0.98 | 0.32 | 0.41 | 1.00 | — | <0.01 | 0.30 | **3.01** |
| May 2026 | 0.99 | 0.32 | 0.41 | 1.00 | — | <0.01 | 0.30 | **3.02** |
| Jun 2026 | 0.99 | 0.32 | 0.41 | 1.00 | — | <0.01 | 0.30 | **3.02** |

**Notes on the data:**
- Oct 2025 spike: $18 Amazon Registrar charge = annual domain renewal for `andrewbrett.xyz`.
- EC2-Other dropped from ~$5.08 to ~$0.45 in Nov 2025 when the instances were stopped and
  volumes were snapshotted; dropped again to ~$0.32 in Dec 2025 once snapshot storage
  stabilized. Now $0 following today's cleanup.
- KMS (~$1/mo) and EFS (~$0.41/mo) have been consistent throughout and do not correspond
  to any Minecraft resource — they originate from a separate project in this account.
- Route 53 (~$1/mo) covers two hosted zones. `minecraft.andrewbrett.xyz.` is the
  Minecraft-specific one; `andrewbrett.xyz.` is the root domain.
- Post-decommission going-forward cost: ~$2.22/mo (KMS + EFS + Route 53 root zone),
  assuming `minecraft.andrewbrett.xyz.` is also deleted. All from non-Minecraft resources.

## Follow-up (30 days)

Check AWS Cost Explorer around **2026-08-04** to confirm EC2 and snapshot
charges are fully gone from the bill (there may be a small trailing charge
for partial-month usage before termination). The budget alert has been
deleted, so this must be done manually.
