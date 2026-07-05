# Decommission Log

**Date:** 2026-07-04  
**Executor:** Claude Code (claude-sonnet-4-6) on Andrew's local machine

## Summary

**Decommission complete.** Both Minecraft server deployments (EC2-based
OnDemandMinecraft and CDK/Fargate-based) are fully torn down. All world
data backed up and verified locally before any destructive action.

**Irreducible floor going forward: ~$0.50/mo** — the `andrewbrett.xyz.`
root domain Route 53 hosted zone (unrelated to Minecraft, presumably
intentional). The KMS key (`alias/mc`) is in PendingDeletion and stops
billing on **2026-07-11**. After that date, Minecraft-related AWS spend
is permanently $0.

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

### CDK teardown executed (2026-07-04)

**Step 1 — EFS world backup**

Launched a rescue instance (`i-0a58035edf552eed6`, t3.nano) in a public
subnet of the CDK VPC with a fresh key pair (`efs-rescue-temp`). Added an
NFS ingress rule to the EFS security group, mounted the filesystem at
`/mnt/efs`, and copied the `/minecraft` directory.

- World size: **793 MB** (significantly larger than the EC2 world; this
  is the more recent/active world)
- Multiple server jars on the EFS: 1.19.2, 1.19.3, 1.19.4, 1.20, 1.20.1,
  1.20.2, 1.20.4, 1.21.1
- Backed up to `~/Documents/efs-world-backup/` (world + config files +
  `minecraft_server.1.21.1.jar` for verification; libraries/versions cache
  omitted as re-downloadable)
- Verified with `verify_world_backup.sh` using 1.21.1 jar: **LOADED**

**Step 2 — Stack deletions**

| Stack | Outcome |
|---|---|
| `minecraft-domain-stack` | Deleted cleanly (hosted zone already gone — no error) |
| `minecraft-server-stack` | Deleted cleanly (ECS, EFS, VPC, subnets, SGs, Lambda, IAM) |
| `StateMachineRole` | Deleted |
| `LAMBDAROLE` | Deleted |
| `CDKToolkit` | Deleted; S3 bootstrap bucket manually emptied and deleted first |

Two leftover security groups (`instance-sg-1`, `efs-sg-1`) and the VPC
had a cross-referencing NFS rule that blocked deletion. Revoked both rules
manually, then deleted the SGs and the VPC.

**Step 3 — KMS key**

`alias/mc` (`8b461e69-7d43-439c-adfa-92dab68f4c10`) scheduled for deletion.
- State: **PendingDeletion**
- Deletion date: **2026-07-11**
- Cost drops from ~$1.00/mo to $0 on that date; cancellable until then.

**Step 4 — Rescue cleanup**

Rescue instance, security group, and key pair all deleted after backup was
confirmed.

## Final resource sweep (2026-07-04, post-CDK teardown)

Checked: EC2 instances, EBS volumes, snapshots, Elastic IPs, ECS clusters,
EFS filesystems, VPCs (non-default), CloudFormation stacks, S3 buckets,
KMS keys, Route 53 zones, Lambda functions, budgets.

**All Minecraft-related resources confirmed gone.**

| Category | Result |
|---|---|
| EC2 instances | ✅ None |
| EBS volumes | ✅ None |
| Snapshots | ✅ None |
| Elastic IPs | ✅ None |
| ECS clusters | ✅ None |
| EFS filesystems | ✅ None |
| Non-default VPCs | ✅ None |
| CloudFormation stacks | ✅ None |
| S3 buckets | ✅ None (CDK bootstrap bucket deleted) |
| KMS customer key `alias/mc` | ⏳ PendingDeletion — deletes 2026-07-11 |
| Budgets | ✅ None |

**Remaining (non-Minecraft, irreducible):**

| Resource | Monthly cost | Notes |
|---|---|---|
| Route 53 `andrewbrett.xyz.` | ~$0.50 | Root domain — unrelated to Minecraft |
| Lambda `email_reminder_lambda` | ~$0 | Unrelated project, within free tier |
| 4 AWS-managed KMS keys (`aws/s3`, `aws/lambda`, `aws/elasticfilesystem`, `aws/backup`) | $0 | AWS-managed keys are free |

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
- KMS (~$1/mo) was the `alias/mc` customer key for the CDK EFS. EFS (~$0.41/mo) was
  the CDK Fargate world store. Both were Minecraft-related — the earlier note calling
  them "unrelated" was incorrect; that was written before the CDK stack was discovered.
- Route 53 (~$1/mo) covered two hosted zones. `minecraft.andrewbrett.xyz.` (deleted
  2026-07-04) and `andrewbrett.xyz.` (root domain, remains at ~$0.50/mo).
- **Post-decommission going-forward cost: ~$0.50/mo** (root domain only) once the KMS
  key deletion completes on 2026-07-11. Minecraft-related spend: $0.

## Follow-up

**2026-07-11** — KMS key `alias/mc` auto-deletes. No action needed; just
confirms the $1.00/mo charge disappears from the next bill.

**~2026-08-04** — Check AWS Cost Explorer to confirm the July bill shows
only the `andrewbrett.xyz.` Route 53 charge (~$0.50) and nothing else
Minecraft-related. There may be a small trailing charge for partial-month
EC2/EFS usage from before today's teardown; that is expected and should
not recur. No budget alert remains, so this check must be done manually.
