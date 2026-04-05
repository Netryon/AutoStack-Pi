#!/usr/bin/env bash
set -Eeuo pipefail

BASE_DIR="/opt/deployment"
LOG_DIR="${BASE_DIR}/logs"
LOG_FILE="${LOG_DIR}/weekly-os-update.log"

mkdir -p "${LOG_DIR}"

{
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] Starting weekly OS update"
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get -y full-upgrade
  apt-get -y autoremove
  apt-get clean
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] Weekly OS update complete"
} >>"${LOG_FILE}" 2>&1
