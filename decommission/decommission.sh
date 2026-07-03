#!/usr/bin/env bash
#
# Decommissions the AWS resources created for this project so monthly
# spend goes to $0, and deletes the AWS Budget alert.
#
# Read decommission/DECOMMISSION.md before running this. It performs
# real, irreversible AWS actions (instance termination, resource
# deletion, budget deletion). It does NOT back up the Minecraft world
# file for you -- do that manually first (see Step 1 in the runbook),
# since it requires your SSH key and a live SCP session.
#
# Usage:
#   cp decommission.env.example decommission.env   # fill in your values
#   ./decommission.sh --dry-run                    # preview actions
#   ./decommission.sh                               # actually run
#   ./decommission.sh --check-cost                  # re-run ~1 month later
#                                                     # to confirm spend hit $0
#
# Requires: aws CLI v2, configured credentials with EC2 + Budgets access.
# --check-cost additionally requires ce:GetCostAndUsage permission.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/decommission.env"

DRY_RUN=false
CHECK_COST_ONLY=false
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=true ;;
    --check-cost) CHECK_COST_ONLY=true ;;
    *) echo "Unknown argument: $arg" >&2; exit 1 ;;
  esac
done

if [[ ! -f "$ENV_FILE" ]]; then
  echo "Missing ${ENV_FILE}." >&2
  echo "Copy decommission.env.example to decommission.env and fill in your values first." >&2
  exit 1
fi

# shellcheck disable=SC1090
source "$ENV_FILE"

: "${AWS_REGION:?Set AWS_REGION in decommission.env}"
: "${INSTANCE_ID:?Set INSTANCE_ID in decommission.env}"
: "${ACCOUNT_ID:?Set ACCOUNT_ID in decommission.env}"
: "${BUDGET_NAME:?Set BUDGET_NAME in decommission.env}"
# Optional: KEY_PAIR_NAME, SECURITY_GROUP_NAME

if [[ "$CHECK_COST_ONLY" == true ]]; then
  echo "=== Cost check for account ${ACCOUNT_ID} (last 30 days) ==="
  START_DATE=$(date -d '30 days ago' +%Y-%m-%d 2>/dev/null || date -v-30d +%Y-%m-%d)
  END_DATE=$(date +%Y-%m-%d)
  aws ce get-cost-and-usage \
    --time-period "Start=${START_DATE},End=${END_DATE}" \
    --granularity MONTHLY \
    --metrics UnblendedCost \
    --group-by Type=DIMENSION,Key=SERVICE \
    --query 'ResultsByTime[0].Groups[?Metrics.UnblendedCost.Amount!=`0`].[Keys[0],Metrics.UnblendedCost.Amount]' \
    --output table
  echo
  echo "If this is non-empty and not a one-time trailing charge from"
  echo "termination, see 'Step 7' in DECOMMISSION.md for common culprits."
  exit 0
fi

run() {
  echo "+ $*"
  if [[ "$DRY_RUN" == false ]]; then
    "$@"
  fi
}

confirm() {
  if [[ "$DRY_RUN" == true ]]; then
    return 0
  fi
  read -r -p "$1 [y/N] " reply
  [[ "$reply" =~ ^[Yy]$ ]]
}

echo "=== AWS Decommission: region=${AWS_REGION} instance=${INSTANCE_ID} ==="
echo "Dry run: ${DRY_RUN}"
echo

echo "Have you backed up the Minecraft world AND confirmed it loads locally"
echo "with verify_world_backup.sh (DECOMMISSION.md Step 1)?"
if ! confirm "Confirm the world backup exists and reported LOADED"; then
  echo "Aborting. Back up the world and run verify_world_backup.sh first." >&2
  exit 1
fi

echo
echo "--- Step 2: Terminate EC2 instance ${INSTANCE_ID} ---"
if confirm "Terminate instance ${INSTANCE_ID}? This is irreversible."; then
  run aws ec2 terminate-instances --instance-ids "$INSTANCE_ID" --region "$AWS_REGION"
  echo "Waiting for termination..."
  run aws ec2 wait instance-terminated --instance-ids "$INSTANCE_ID" --region "$AWS_REGION"
else
  echo "Skipped instance termination."
fi

echo
echo "--- Step 3: Check for orphaned Elastic IPs, volumes, snapshots ---"
echo "Elastic IPs:"
aws ec2 describe-addresses --region "$AWS_REGION" \
  --query 'Addresses[].{AllocationId:AllocationId,PublicIp:PublicIp,InstanceId:InstanceId}' \
  --output table || true
echo "Release any unattached Elastic IPs manually with:"
echo "  aws ec2 release-address --allocation-id <ALLOCATION_ID> --region ${AWS_REGION}"

echo
echo "Available (unattached) volumes:"
aws ec2 describe-volumes --region "$AWS_REGION" \
  --filters Name=status,Values=available \
  --query 'Volumes[].{VolumeId:VolumeId,Size:Size}' --output table || true
echo "Delete any leftover volumes manually with:"
echo "  aws ec2 delete-volume --volume-id <VOLUME_ID> --region ${AWS_REGION}"

echo
echo "Snapshots owned by this account:"
aws ec2 describe-snapshots --owner-ids self --region "$AWS_REGION" \
  --query 'Snapshots[].{SnapshotId:SnapshotId,VolumeSize:VolumeSize,StartTime:StartTime}' \
  --output table || true
echo "Delete any you no longer need with:"
echo "  aws ec2 delete-snapshot --snapshot-id <SNAPSHOT_ID> --region ${AWS_REGION}"

echo
echo "--- Step 4: Delete AWS Budget ${BUDGET_NAME} ---"
if confirm "Delete budget '${BUDGET_NAME}' for account ${ACCOUNT_ID}?"; then
  run aws budgets delete-budget --account-id "$ACCOUNT_ID" --budget-name "$BUDGET_NAME"
else
  echo "Skipped budget deletion."
fi

echo
echo "--- Step 5 (optional): key pair / security group cleanup ---"
if [[ -n "${KEY_PAIR_NAME:-}" ]]; then
  if confirm "Delete key pair '${KEY_PAIR_NAME}'?"; then
    run aws ec2 delete-key-pair --key-name "$KEY_PAIR_NAME" --region "$AWS_REGION"
  fi
fi
if [[ -n "${SECURITY_GROUP_NAME:-}" ]]; then
  if confirm "Delete security group '${SECURITY_GROUP_NAME}'?"; then
    run aws ec2 delete-security-group --group-name "$SECURITY_GROUP_NAME" --region "$AWS_REGION"
  fi
fi

echo
echo "--- Step 6: Verification ---"
echo "Remaining non-terminated instances:"
aws ec2 describe-instances --region "$AWS_REGION" \
  --filters Name=instance-state-name,Values=running,stopped,stopping,pending \
  --query 'Reservations[].Instances[].{Id:InstanceId,State:State.Name}' --output table || true

echo "Remaining budgets:"
aws budgets describe-budgets --account-id "$ACCOUNT_ID" \
  --query 'Budgets[].BudgetName' --output table || true

echo
echo "Done. Review the tables above -- they should be empty (or the budget gone) for \$0 ongoing spend."
