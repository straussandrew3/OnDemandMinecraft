# Decommission Log

**Date:** 2026-07-04  
**Executor:** Claude Code (claude-sonnet-4-6) on Andrew's local machine

## Summary

All **EC2-based** Minecraft resources (the OnDemandMinecraft project)
terminated and world backup verified. The `minecraft.andrewbrett.xyz.`
Route 53 hosted zone deleted. However, a second **CDK/Fargate-based**
Minecraft infrastructure was discovered still live in the account — it
was not part of this project's scope but is responsible for the KMS and
EFS charges previously listed as "unrelated." See the CDK infrastructure
section below for full details and risk assessment before further action.

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

## Route 53 zone deletion (2026-07-04)

`minecraft.andrewbrett.xyz.` (zone `Z104067212IEK8RB32Q83`) deleted. The
A record pointing to `34.224.100.212` was removed first, then the zone.
This zone was originally created by `minecraft-domain-stack` (CDK), which
is now in an inconsistent state — see CDK infrastructure section below.

Going-forward Route 53 cost: **~$0.50/mo** (only `andrewbrett.xyz.` root
domain remains). Minecraft-related Route 53 spend: **$0**.

## Discovered: CDK/Fargate Minecraft infrastructure (not yet cleaned up)

During the final sweep, a second complete Minecraft server deployment was
found — built with AWS CDK and using ECS/Fargate instead of EC2. This is
separate from the OnDemandMinecraft project and was never part of this
decommission's original scope, but it is the source of the KMS and EFS
charges.

### What it is

An on-demand Fargate Minecraft server: when a player queries
`minecraft.andrewbrett.xyz` in DNS, a CloudWatch Logs subscription filter
triggers a Lambda that sets the ECS service's desired count to 1, starting
a Fargate task. The task mounts the EFS filesystem for persistent world
storage. When idle, the service scales back to 0 (currently 0/0 — nothing
running). The world data lives permanently in the EFS, not on an EC2 disk.

### CloudFormation stacks

| Stack | Status | Contains |
|---|---|---|
| `minecraft-server-stack` | CREATE_COMPLETE | ECS cluster, Fargate service/task, EFS filesystem, VPC+subnets, security groups, SNS topic, Lambda, IAM roles |
| `minecraft-domain-stack` | CREATE_COMPLETE (broken) | Route 53 hosted zone (now deleted), Lambda launcher, CloudWatch Logs group, SSM params |
| `StateMachineRole` | CREATE_COMPLETE | IAM role only |
| `LAMBDAROLE` | CREATE_COMPLETE | IAM role only |
| `CDKToolkit` | CREATE_COMPLETE | CDK bootstrap (S3 bucket) |

### Active billing from this infrastructure

| Resource | ID | Monthly cost |
|---|---|---|
| KMS customer key (`alias/mc`) | `8b461e69-7d43-439c-adfa-92dab68f4c10` | ~$1.00 |
| EFS filesystem | `fs-081089ad1ba0507bc` | ~$0.41 (~1.4 GB) |

ECS Fargate: **$0** — desired count is 0, no tasks running.

### Risk assessment (do not delete without reading this)

**EFS filesystem (`fs-081089ad1ba0507bc`)** — contains ~1.4 GB of Minecraft
world data at the `/minecraft` access point. This is almost certainly a
*different* world than the one backed up from the EC2 snapshots (the CDK
server was a separate, later deployment). **Must be backed up before
deletion.** Mount it on a temporary instance (same approach used for the EC2
volume) and SCP the contents before tearing down the stack.

**KMS key (`alias/mc`)** — used only to encrypt the EFS filesystem. Has no
grants, no other consumers. Safe to schedule for deletion *after* the EFS is
deleted (7-day minimum waiting period enforced by AWS; cancelable during that
window). It is irreversible once the waiting period completes, but since
EFS will be gone, there's nothing left for it to decrypt.

**`minecraft-domain-stack`** — the Route 53 hosted zone it created has
already been deleted manually. CloudFormation delete may error on that
resource but should proceed past it; worst case, the zone resource can be
skipped with a manual `--retain-resources` flag.

**`minecraft-server-stack`** — do not delete until EFS world data is backed
up. Once backed up, deleting the stack via CloudFormation will cleanly remove
ECS, EFS, VPC, security groups, and all associated IAM policies.

**`StateMachineRole` / `LAMBDAROLE` / `CDKToolkit`** — IAM roles and CDK
bootstrap only, no data. Safe to delete any time; no ongoing cost.

### Recommended next steps (not yet executed)

1. Back up EFS world data (mount on temp instance, SCP locally).
2. Delete `minecraft-domain-stack` (stack delete, may need `--retain-resources`
   for the already-deleted hosted zone).
3. Delete `minecraft-server-stack` (cleans up EFS, ECS, VPC, everything).
4. Schedule `alias/mc` KMS key for deletion (7-day window).
5. Delete `StateMachineRole`, `LAMBDAROLE`, `CDKToolkit` stacks.

## Final resource sweep (2026-07-04)

Checked: EC2 instances, Elastic IPs, EBS volumes, snapshots, load
balancers, RDS, S3, Route 53, NAT gateways, budgets.

**All EC2/snapshot/budget resources confirmed gone.** Remaining items:

| Resource | Detail | Monthly cost | Notes |
|---|---|---|---|
| Route 53 hosted zone | `andrewbrett.xyz.` | ~$0.50 | Root domain — likely intentional |
| S3 bucket | `cdk-hnb659fds-assets-996039603186-us-east-1` | ~$0 | CDK bootstrap bucket, negligible |
| KMS customer key | `alias/mc` | ~$1.00 | For CDK EFS encryption — see CDK section |
| EFS filesystem | `fs-081089ad1ba0507bc` | ~$0.41 | CDK world data — see CDK section |

`minecraft.andrewbrett.xyz.` Route 53 zone: **deleted** (see above).
KMS and EFS are Minecraft-related (CDK stack) — not safe to delete without
backing up the EFS world data first. See CDK infrastructure section above.

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
