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

## Get AWS CLI access (5 steps, ~5 minutes)

1. **Install AWS CLI v2** if not already installed:
   - macOS: `brew install awscli`
   - Linux: see https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html
   - Windows: download/run the MSI from the same page.
2. **Get an access key**: AWS Console → IAM → Users → (your user) →
   Security credentials tab → Create access key. (If the original
   `ACCESS_KEY`/`SECRET_KEY` this project used, per the values that
   would have gone into `configuration.py`, are still active, you can
   reuse those instead of creating new ones.)
3. **Configure the CLI**: `aws configure` — paste in the Access Key ID,
   Secret Access Key, the region this project's instance runs in
   (matches `ec2_region` in `configuration.py`), and `json` for output
   format.
4. **Verify it works**: `aws sts get-caller-identity` — should print
   your account ID and user ARN, not an error.
5. **Verify it has enough permissions**: `aws ec2 describe-instances
   --region <your-region>` and `aws budgets describe-budgets
   --account-id <account-id-from-step-4>`. If either returns
   `AccessDenied`, attach a broader policy to the IAM user in the
   Console (e.g. `AmazonEC2FullAccess` plus a Budgets permission) before
   continuing — the runbook and script need EC2, Budgets, and (for the
   later cost check) Cost Explorer (`ce:GetCostAndUsage`) permissions.

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
