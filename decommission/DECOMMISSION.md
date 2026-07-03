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

Do not proceed to Step 2 until this backup exists and looks complete.

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
