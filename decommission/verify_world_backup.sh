#!/usr/bin/env bash
#
# Confirms a Minecraft world backup is actually loadable by booting a
# throwaway local server against it and checking the log for a clean
# startup. Run this BEFORE terminating the AWS instance (Step 1 of
# DECOMMISSION.md) -- a copied folder that fails to load is not a
# usable backup.
#
# Usage:
#   ./verify_world_backup.sh <path-to-world-backup-dir> <path-to-server.jar>
#
# <path-to-server.jar> must be the same Minecraft server version that
# produced the world, downloaded from
# https://www.minecraft.net/en-us/download/server -- mismatched
# versions can fail or silently upgrade the world format.
#
# Requires: java on PATH (same major version the server needs).

set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "Usage: $0 <path-to-world-backup-dir> <path-to-server.jar>" >&2
  exit 1
fi

WORLD_BACKUP="$1"
SERVER_JAR="$2"

if [[ ! -d "$WORLD_BACKUP" ]]; then
  echo "World backup directory not found: ${WORLD_BACKUP}" >&2
  exit 1
fi
if [[ ! -f "$SERVER_JAR" ]]; then
  echo "server.jar not found: ${SERVER_JAR}" >&2
  exit 1
fi
if ! command -v java >/dev/null 2>&1; then
  echo "java not found on PATH. Install a JDK matching the server version first." >&2
  exit 1
fi

WORK_DIR="$(mktemp -d -t mc-backup-verify.XXXXXX)"
trap 'rm -rf "$WORK_DIR"' EXIT

echo "=== Verifying world backup: ${WORLD_BACKUP} ==="
echo "Working directory: ${WORK_DIR}"

cp "$SERVER_JAR" "$WORK_DIR/server.jar"
cp -r "$WORLD_BACKUP" "$WORK_DIR/world"
echo "eula=true" > "$WORK_DIR/eula.txt"

# Minimal, isolated config: offline mode (no auth needed for this local
# smoke test), a query port unlikely to collide with anything else
# running, and no whitelist/ops enforcement getting in the way.
cat > "$WORK_DIR/server.properties" <<EOF
level-name=world
online-mode=false
server-port=25599
enable-query=false
white-list=false
EOF

LOG_FILE="${WORK_DIR}/verify.log"
STDIN_PIPE="${WORK_DIR}/stdin.pipe"
mkfifo "$STDIN_PIPE"

echo "Starting throwaway server to load the world..."
(cd "$WORK_DIR" && exec java -jar server.jar nogui < "$STDIN_PIPE" > "$LOG_FILE" 2>&1) &
SERVER_PID=$!

# Keep the pipe open for writing so the server doesn't see EOF on stdin
exec 3> "$STDIN_PIPE"

RESULT="TIMEOUT"
for _ in $(seq 1 60); do
  if ! kill -0 "$SERVER_PID" 2>/dev/null; then
    RESULT="CRASHED"
    break
  fi
  if grep -qE 'Done \([0-9.]+s\)!' "$LOG_FILE" 2>/dev/null; then
    RESULT="LOADED"
    break
  fi
  if grep -qiE 'Exception|Error loading|Corrupt' "$LOG_FILE" 2>/dev/null; then
    RESULT="ERROR"
    break
  fi
  sleep 1
done

if [[ "$RESULT" == "LOADED" ]]; then
  echo "stop" >&3
  # Give it a moment to shut down cleanly
  for _ in $(seq 1 20); do
    kill -0 "$SERVER_PID" 2>/dev/null || break
    sleep 1
  done
  kill "$SERVER_PID" 2>/dev/null || true
else
  kill "$SERVER_PID" 2>/dev/null || true
fi
exec 3>&-

echo
echo "=== Result: ${RESULT} ==="
case "$RESULT" in
  LOADED)
    echo "World backup loaded successfully -- safe to proceed with decommissioning."
    ;;
  CRASHED|ERROR)
    echo "World backup FAILED to load cleanly. Do not terminate the AWS instance yet."
    echo "Last 40 log lines:"
    tail -n 40 "$LOG_FILE"
    exit 1
    ;;
  TIMEOUT)
    echo "Server did not finish starting within the timeout. Inspect manually:"
    echo "  ${LOG_FILE}"
    exit 1
    ;;
esac
