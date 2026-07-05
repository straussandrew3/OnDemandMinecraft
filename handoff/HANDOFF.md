# Handoff: AWS Decommission for OnDemandMinecraft

## Context

Goal: get this project's AWS monthly spend from ~$3 to $0 by
terminating all billable resources and deleting the AWS Budget, while
preserving the Minecraft world file. Everything needed to do this is
already written and committed under `decommission/` — nothing has been
**executed** yet. This file exists because the agent that wrote the
runbook (in a cloud sandbox session) had no AWS credentials and could
not run any AWS CLI commands itself. You're picking this up on the
user's local computer, where real `aws` CLI access can be set up.

## What's already done (committed on this branch)

- `decommission/DECOMMISSION.md` — the full runbook: back up world →
  verify the backup actually loads → terminate EC2 instance → clean up
  orphaned Elastic IPs/volumes/snapshots → delete the AWS Budget →
  verify resources are gone → check back in ~30 days that billed cost
  actually hit $0. Also documents a mobile-only path via AWS CloudShell
  if needed, but you have CLI access so just follow the main steps.
- `decommission/decommission.sh` — automates termination, EIP/volume/
  snapshot reporting, budget deletion, optional key pair/security group
  cleanup. Supports `--dry-run` and `--check-cost` (re-run ~30 days
  later to confirm via Cost Explorer that spend is actually $0).
- `decommission/verify_world_backup.sh` — boots the backed-up world on
  a throwaway local server and confirms it loads cleanly before
  anything on AWS gets terminated. Requires a local JDK matching the
  Minecraft server version.
- `decommission/decommission.env.example` — template for
  `AWS_REGION`/`INSTANCE_ID`/`ACCOUNT_ID`/`BUDGET_NAME` (and optional
  key pair/security group names). Copy to `decommission.env` and fill
  in real values; it's gitignored so account specifics never get
  committed.

## What's NOT done yet

- No AWS commands have actually been run. The instance, budget, and any
  other resources are presumably still live and billing.
- The world file has not been backed up or verified.
- A follow-up check-in is already scheduled for **2026-08-02** in the
  originating chat session to ask the user whether cost actually
  dropped to $0 — if you complete the decommission before then, that
  check-in will just confirm success; no action needed on your end for
  that specifically.

## Get AWS CLI access (~2 minutes, plus security notes)

**1. Install:**
```bash
# macOS
brew install awscli

# Linux
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip" && unzip awscliv2.zip && sudo ./aws/install

# Windows (PowerShell)
winget install Amazon.AWSCLI
```

**2. Configure:**
```bash
aws configure
```
Paste in an Access Key ID, Secret Access Key, the region this
project's instance runs in (matches `ec2_region` in
`configuration.py`), and `json` for output format. `aws configure`
writes these to `~/.aws/credentials` in plaintext on disk — normal and
expected for local CLI use, just don't let that file get synced to a
cloud backup, dotfiles repo, or committed anywhere.

**3. Verify:** `aws sts get-caller-identity` should print an account ID
and user ARN, not an error.

### Which access key to use — do this part securely

- **Don't paste secret keys into chat, commit messages, or any file in
  this repo.** `decommission.env` is already gitignored for exactly
  this reason — keep it that way.
- If the original `ACCESS_KEY`/`SECRET_KEY` this project used (the
  values that would have gone into `configuration.py`) are still
  active, you *can* reuse them for speed — but since that key has been
  sitting around since initial setup and its exact scope/history isn't
  tracked anywhere, prefer creating a **fresh** access key for this
  one-off decommission task instead: AWS Console → IAM → Users → your
  user → Security credentials tab → Create access key.
- Either way, this task only needs EC2, Budgets, and (for the later
  cost check) Cost Explorer (`ce:GetCostAndUsage`) permissions. If
  `aws ec2 describe-instances --region <region>` or `aws budgets
  describe-budgets --account-id <account-id>` returns `AccessDenied`,
  attach what's missing rather than reaching for a broad admin policy.
- **When the decommission is fully done and verified**, deactivate or
  delete whichever access key you used (IAM → Users → Security
  credentials → Deactivate/Delete) rather than leaving it live
  indefinitely — it won't be needed again after this task, and a key
  with EC2-terminate/Budgets-delete permissions is not something to
  leave lying around unused.

## What to do next

1. `cd decommission`
2. `cp decommission.env.example decommission.env` and fill in
   `AWS_REGION`, `INSTANCE_ID`, `ACCOUNT_ID`, `BUDGET_NAME` (get the
   budget name from `aws budgets describe-budgets --account-id
   <account-id>` if unknown).
3. Follow `DECOMMISSION.md` Step 1: back up the world file via `scp`,
   then run `./verify_world_backup.sh <backup-dir> <path-to-server.jar>`
   and confirm it reports `LOADED`. **Do not proceed past this until it
   does.**
4. Run `./decommission.sh --dry-run` first to preview every action,
   then `./decommission.sh` for real. It will prompt for confirmation
   before each irreversible step (instance termination, budget
   deletion, etc.) and refuses to proceed unless you confirm the world
   backup is done and verified.
5. Report back in this repo (or to the user directly) with: final
   state of each resource type, confirmation the world backup exists
   and loaded successfully, and the local path where the world backup
   was saved.
6. ~30 days after running the above, run `./decommission.sh
   --check-cost` (or check AWS Cost Explorer/Billing directly) to
   confirm actual billed spend is $0. If not, `DECOMMISSION.md` Step 7
   has a list of common leftover-cost culprits (S3, Route 53 hosted
   zones, CloudWatch, trailing data transfer) to check.

## Notes

- This is a hobby project with no Terraform/IaC — everything was set
  up manually per `readme.md`, so there's no code-level "undo"; every
  step here is a live AWS API/console action.
- Treat `decommission.sh` and `verify_world_backup.sh` as scripts that
  perform real, mostly irreversible actions. Read them before running,
  same as the runbook says.
