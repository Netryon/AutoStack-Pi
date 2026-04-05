#!/usr/bin/env bash
set -Eeuo pipefail

BASE_DIR="/opt/deployment"
LOG_DIR="${BASE_DIR}/logs"
LOG_FILE="${LOG_DIR}/docker-cleanup.log"

mkdir -p "${LOG_DIR}"

{
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] Starting Docker cleanup"
  docker system df
  docker container prune -f
  docker image prune -a -f
  docker network prune -f
  docker builder prune -a -f
  docker system df
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] Docker cleanup complete"
} >>"${LOG_FILE}" 2>&1
