# AWS Decommission Runbook

Goal: back up the Minecraft world, terminate every billable AWS resource
this project created, and delete the AWS Budget so monthly spend goes to
$0 and the project is fully decommissioned.

This is written for an agent/operator who has AWS CLI access configured
on the user's machine (`aws configure` already run, or environment
variables `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY`/`AWS_DEFAULT_REGION`
already set). The session that authored this runbook did **not** have
AWS credentials and could not run any of these commands itself.

A companion script, `decommission.sh` in this same directory, automates
steps 2-5 below. Read it before running it — it terminates real AWS
resources and cannot be undone.

## Prerequisites

- AWS CLI v2 installed (`aws --version`).
- Credentials for the AWS account that owns this project, with
  permission to manage EC2, Elastic IPs, and Budgets.
- The values normally filled into the project's `configuration.py`:
  `INSTANCE_ID`, `ec2_region`, `SSH_KEY_FILE_PATH`, `ec2_keypair`.
- The AWS Account ID (`aws sts get-caller-identity --query Account --output text`).
- Your AWS Budget's name (`aws budgets describe-budgets --account-id <ACCOUNT_ID>`).

## Mobile-only path: AWS CloudShell

If you only have a phone and no computer, don't install anything or
hand your AWS credentials to any third party/agent. Use **AWS
CloudShell** instead — it's a browser-based terminal at
console.aws.amazon.com (works in a phone browser), already
authenticated as you, with the AWS CLI preinstalled. Every `aws ...`
command in Steps 1-7 below runs unmodified inside it. The only part
that needs adapting for phone use is getting the world backup file
*out* of CloudShell and onto your phone, since CloudShell can't `scp`
directly to a phone's filesystem:

1. Sign in at console.aws.amazon.com on your phone, then open
   **CloudShell** (icon in the top nav bar).
2. Use the CloudShell **Actions** menu → **Upload file** to upload your
   `.pem` key file (the same one used for `ssh`/`scp` to the instance).
   Then: `chmod 400 yourkey.pem`
3. Run Step 1's `describe-instances` and `scp` commands as written,
   using the uploaded key — this pulls the world folder into
   CloudShell's own storage.
4. Zip it up: `zip -r minecraft-world-backup.zip minecraft-world-backup`
5. Use CloudShell's **Actions** menu → **Download file**, enter the
   path (e.g. `minecraft-world-backup.zip`), and it downloads straight
   to your phone through the browser (Files app / Downloads).
6. To run `verify_world_backup.sh` inside CloudShell before
   terminating anything, install a JDK first (CloudShell is Amazon
   Linux): `sudo yum install -y java-21-amazon-corretto-headless`
   (match the major Java version your Minecraft server version needs),
   then run the script against the CloudShell copy of the backup and
   your uploaded/downloaded `server.jar`.
7. Continue with Steps 2-7 in the same CloudShell session — same
   commands, no changes needed.

Don't leave the world backup sitting in an S3 bucket as its permanent
home if the goal is genuine $0 spend — S3 storage isn't free. Treat S3
(if you use it at all) as a relay, not the final resting place: get the
zip onto your phone (or a Drive/cloud storage you already pay flat for)
via CloudShell's Download action, then delete any S3 copy per Step 5.

## Step 1 — Back up the world file (do this before anything else)

If the instance is stopped, start it first so you can reach it over SSH:

```bash
aws ec2 start-instances --instance-ids <INSTANCE_ID> --region <REGION>
aws ec2 wait instance-running --instance-ids <INSTANCE_ID> --region <REGION>
```

Get its public IP:

```bash
aws ec2 describe-instances --instance-ids <INSTANCE_ID> --region <REGION> \
  --query 'Reservations[0].Instances[0].PublicIpAddress' --output text
```

Pull the world down (adjust the remote path to match the world name in
`server.properties`, default is `world`):

```bash
scp -i <SSH_KEY_FILE_PATH> -r ubuntu@<PUBLIC_IP>:~/world ./minecraft-world-backup
```

Verify the backup landed and isn't empty before continuing:

```bash
du -sh ./minecraft-world-backup
```

### Confirm the backup actually loads (don't skip this)

A folder copy that isn't corrupted looking is not the same as a world
that boots. Prove it by launching a throwaway local server against the
backup with the companion script:

```bash
./verify_world_backup.sh ./minecraft-world-backup /path/to/matching-server.jar
```

`server.jar` must be the **same Minecraft server version** that was
running on the AWS instance (download from
https://www.minecraft.net/en-us/download/server if you don't have it
locally) — a version mismatch can fail to load or silently convert the
world. Requires a JDK matching that server version already on the local
machine.

The script boots the world on an isolated local port (`25599`,
offline-mode) with no player intervention, watches the log for a clean
`Done (...)!` startup line, then stops the server and reports
`LOADED`, `CRASHED`, or `ERROR`. If you want to actually walk around and
visually confirm builds/inventory, leave the throwaway server running
(comment out the `stop` in the script, or just start `server.jar`
manually in the copied `world` folder) and connect with a regular
Minecraft client to `localhost:25599`.

Do not proceed to Step 2 until `verify_world_backup.sh` reports
`LOADED`.

## Step 2 — Terminate the EC2 instance

```bash
aws ec2 terminate-instances --instance-ids <INSTANCE_ID> --region <REGION>
aws ec2 wait instance-terminated --instance-ids <INSTANCE_ID> --region <REGION>
```

## Step 3 — Clean up anything left that still bills

Elastic IPs bill hourly when unattached — release any associated with
this project:

```bash
aws ec2 describe-addresses --region <REGION>
aws ec2 release-address --allocation-id <ALLOCATION_ID> --region <REGION>
```

EBS volumes should auto-delete with the instance (default
`DeleteOnTermination=true`), but confirm none are left orphaned in
`available` state:

```bash
aws ec2 describe-volumes --region <REGION> \
  --filters Name=status,Values=available --query 'Volumes[].VolumeId'
aws ec2 delete-volume --volume-id <VOLUME_ID> --region <REGION>
```

Any snapshots created from this project's volumes also incur storage
charges — list and delete if no longer needed:

```bash
aws ec2 describe-snapshots --owner-ids self --region <REGION>
aws ec2 delete-snapshot --snapshot-id <SNAPSHOT_ID> --region <REGION>
```

## Step 4 — Delete the AWS Budget

Deleting the budget removes the alert; it does not itself stop charges,
which is why Steps 2-3 (actually terminating resources) come first.

```bash
aws budgets describe-budgets --account-id <ACCOUNT_ID>
aws budgets delete-budget --account-id <ACCOUNT_ID> --budget-name <BUDGET_NAME>
```

## Step 5 — Optional cleanup (no ongoing cost, but tidies the account)

These don't cost anything to leave behind, so they're optional:

```bash
# Security group created per the README setup (only if unused elsewhere)
aws ec2 describe-security-groups --region <REGION> --group-names minecraft
aws ec2 delete-security-group --group-name minecraft --region <REGION>

# Key pair
aws ec2 describe-key-pairs --region <REGION>
aws ec2 delete-key-pair --key-name <KEY_PAIR_NAME> --region <REGION>
```

If world backups were also copied to S3 at any point, check for and
remove that bucket/object separately, since S3 storage bills
independently of EC2:

```bash
aws s3 ls
aws s3 rb s3://<BUCKET_NAME> --force
```

## Step 6 — Verify $0 going forward

```bash
aws ec2 describe-instances --region <REGION> \
  --filters Name=instance-state-name,Values=running,stopped,stopping,pending
aws ec2 describe-addresses --region <REGION>
aws ec2 describe-volumes --region <REGION>
aws budgets describe-budgets --account-id <ACCOUNT_ID>
```

All of the above should return empty (or the budget should be gone) once
decommissioning is complete.

## Step 7 — Confirm actual spend hit $0 (check back ~1 month later)

Resource checks in Step 6 catch what's *visible* right now, but AWS
billing has a lag, and some charges (partial-month EC2/EBS usage from
before termination, small per-resource fees) only show up on the next
bill. Deleting the Budget in Step 4 also means you'll no longer get an
alert if something was missed — so this step has to be done manually.

**~30 days after running Steps 1-5**, check actual cost with Cost
Explorer (needs `ce:GetCostAndUsage` permission):

```bash
aws ce get-cost-and-usage \
  --time-period Start=$(date -d '30 days ago' +%Y-%m-%d),End=$(date +%Y-%m-%d) \
  --granularity MONTHLY \
  --metrics UnblendedCost \
  --group-by Type=DIMENSION,Key=SERVICE
```

(On macOS without GNU `date`, use `date -v-30d +%Y-%m-%d` instead of
`date -d '30 days ago' +%Y-%m-%d`.)

If the total is not $0, the `SERVICE` breakdown tells you where to look.
Common leftover-cost culprits this project can leave behind that Step 3
doesn't cover:

- **S3** — a world backup bucket left in place bills for storage even
  with no other activity.
- **Route 53** — a hosted zone (if one was ever created for the
  server's IP) bills ~$0.50/month regardless of traffic.
- **CloudWatch** — custom alarms, dashboards, or log groups with a
  retention policy can carry small storage/monitoring charges.
- **Data transfer** — any lingering charges from before termination
  will trail onto this bill; if the rest of the account is otherwise
  clean, a small one-time trailing charge on this next bill is expected
  and should disappear the bill after.

If a real ongoing (non-trailing) charge shows up, find and delete the
specific resource in the flagged service, then re-run this same Cost
Explorer check after the following billing cycle to confirm it's gone.
