#!/usr/bin/env bash
set -Eeuo pipefail

BASE_DIR="${1:-/opt/deployment}"
LOG_DIR="${BASE_DIR}/logs"
LOG_FILE="${LOG_DIR}/verify-stack.log"
mkdir -p "${LOG_DIR}"

check_container() {
  local name="$1"
  if docker ps --format '{{.Names}}' | grep -Fxq "${name}"; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] OK: ${name} is running" | tee -a "${LOG_FILE}"
  else
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] FAIL: ${name} is not running" | tee -a "${LOG_FILE}"
    exit 1
  fi
}

check_container "duckdns"
check_container "heimdall"
check_container "pihole"
check_container "wg-easy"
check_container "watchtower"

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Stack verification complete." | tee -a "${LOG_FILE}"
