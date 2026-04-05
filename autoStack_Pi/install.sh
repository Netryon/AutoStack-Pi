#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="/opt/deployment"
COMPOSE_DIR="${BASE_DIR}/compose"
ENV_DIR="${BASE_DIR}/env"
DATA_DIR="${BASE_DIR}/data"
TARGET_SCRIPT_DIR="${BASE_DIR}/scripts"
LOG_DIR="${BASE_DIR}/logs"
BOOTSTRAP_LOG="/tmp/pi-homelab-installer.log"
LOG_FILE="${BOOTSTRAP_LOG}"
STATE_FILE="${HOME}/.pi-homelab-installer.state"

RUN_DEPLOY="yes"

DEFAULT_TIMEZONE="Etc/UTC"
DEFAULT_SSH_PORT="22"
DEFAULT_HEIMDALL_PORT="8080"
DEFAULT_PIHOLE_DNS_PORT="53"
DEFAULT_PIHOLE_ADMIN_PORT="8081"
DEFAULT_WG_UDP_PORT="51820"
DEFAULT_WG_WEB_PORT="51821"
DEFAULT_WG_DNS="1.1.1.1"
DEFAULT_WG_SUBNET="10.8.0.0/24"
DEFAULT_WATCHTOWER_SCHEDULE="0 30 4 * * 0"
DEFAULT_CLEANUP_CRON="0 0 5 * * 0"
DEFAULT_OS_UPDATE_CRON="0 0 4 * * 0"

# If invoked as "bash install.sh" from a CRLF copy, self-repair and relaunch.
if grep -q $'\r' "$0" 2>/dev/null; then
  tmp_self="$(mktemp /tmp/pi-homelab-installer.XXXXXX.sh)"
  tr -d '\r' < "$0" > "${tmp_self}"
  chmod +x "${tmp_self}"
  exec bash "${tmp_self}" "$@"
fi

log() {
  local level="${1}"
  shift
  local message="$*"
  local ts
  ts="$(date '+%Y-%m-%d %H:%M:%S')"
  echo "[${ts}] [${level}] ${message}" | tee -a "${LOG_FILE}"
}

STATE_GLOBALS_DONE="${STATE_GLOBALS_DONE:-0}"
STATE_PHASE1_DONE="${STATE_PHASE1_DONE:-0}"
STATE_DUCKDNS_FILES_DONE="${STATE_DUCKDNS_FILES_DONE:-0}"
STATE_HEIMDALL_FILES_DONE="${STATE_HEIMDALL_FILES_DONE:-0}"
STATE_PIHOLE_FILES_DONE="${STATE_PIHOLE_FILES_DONE:-0}"
STATE_WGEASY_FILES_DONE="${STATE_WGEASY_FILES_DONE:-0}"
STATE_WATCHTOWER_FILES_DONE="${STATE_WATCHTOWER_FILES_DONE:-0}"
STATE_PHASE34_DONE="${STATE_PHASE34_DONE:-0}"
STATE_DEPLOY_DUCKDNS_DONE="${STATE_DEPLOY_DUCKDNS_DONE:-0}"
STATE_DEPLOY_HEIMDALL_DONE="${STATE_DEPLOY_HEIMDALL_DONE:-0}"
STATE_DEPLOY_PIHOLE_DONE="${STATE_DEPLOY_PIHOLE_DONE:-0}"
STATE_PIHOLE_PASSWORD_DONE="${STATE_PIHOLE_PASSWORD_DONE:-0}"
STATE_DEPLOY_WGEASY_DONE="${STATE_DEPLOY_WGEASY_DONE:-0}"
STATE_DEPLOY_WATCHTOWER_DONE="${STATE_DEPLOY_WATCHTOWER_DONE:-0}"
STATE_FIREWALL_DONE="${STATE_FIREWALL_DONE:-0}"
STATE_INSTALL_COMPLETE="${STATE_INSTALL_COMPLETE:-0}"
DETECTED_LAN_SUBNET="${DETECTED_LAN_SUBNET:-}"

save_state() {
  cat >"${STATE_FILE}" <<EOF
GLOBAL_TIMEZONE=${GLOBAL_TIMEZONE:-}
SSH_PORT=${SSH_PORT:-22}
RUN_DEPLOY=${RUN_DEPLOY:-yes}
DETECTED_LAN_SUBNET=${DETECTED_LAN_SUBNET:-}
HEIMDALL_PORT=${HEIMDALL_PORT:-}
PIHOLE_DNS_PORT=${PIHOLE_DNS_PORT:-}
PIHOLE_ADMIN_PORT=${PIHOLE_ADMIN_PORT:-}
WG_UDP_PORT=${WG_UDP_PORT:-}
WG_WEB_PORT=${WG_WEB_PORT:-}
STATE_GLOBALS_DONE=${STATE_GLOBALS_DONE}
STATE_PHASE1_DONE=${STATE_PHASE1_DONE}
STATE_DUCKDNS_FILES_DONE=${STATE_DUCKDNS_FILES_DONE}
STATE_HEIMDALL_FILES_DONE=${STATE_HEIMDALL_FILES_DONE}
STATE_PIHOLE_FILES_DONE=${STATE_PIHOLE_FILES_DONE}
STATE_WGEASY_FILES_DONE=${STATE_WGEASY_FILES_DONE}
STATE_WATCHTOWER_FILES_DONE=${STATE_WATCHTOWER_FILES_DONE}
STATE_PHASE34_DONE=${STATE_PHASE34_DONE}
STATE_DEPLOY_DUCKDNS_DONE=${STATE_DEPLOY_DUCKDNS_DONE}
STATE_DEPLOY_HEIMDALL_DONE=${STATE_DEPLOY_HEIMDALL_DONE}
STATE_DEPLOY_PIHOLE_DONE=${STATE_DEPLOY_PIHOLE_DONE}
STATE_PIHOLE_PASSWORD_DONE=${STATE_PIHOLE_PASSWORD_DONE}
STATE_DEPLOY_WGEASY_DONE=${STATE_DEPLOY_WGEASY_DONE}
STATE_DEPLOY_WATCHTOWER_DONE=${STATE_DEPLOY_WATCHTOWER_DONE}
STATE_FIREWALL_DONE=${STATE_FIREWALL_DONE}
STATE_INSTALL_COMPLETE=${STATE_INSTALL_COMPLETE}
EOF
}

load_state() {
  if [[ -f "${STATE_FILE}" ]]; then
    # shellcheck disable=SC1090
    source "${STATE_FILE}"
    log "INFO" "Resume state loaded from ${STATE_FILE}"
  fi
}

mark_state_done() {
  local key="$1"
  printf -v "${key}" "%s" "1"
  save_state
  log "INFO" "Checkpoint: ${key}=1"
}

on_error() {
  local line="$1"
  log "ERROR" "Installer failed on line ${line} while running: ${BASH_COMMAND}"
  log "ERROR" "Check ${LOG_FILE}"
  save_state
  if declare -f print_summary >/dev/null 2>&1; then
    echo
    echo "Installer ended with errors. Partial system summary:"
    print_summary || true
  fi
  exit 1
}

trap 'on_error ${LINENO}' ERR

require_root_or_sudo() {
  if [[ "${EUID}" -ne 0 ]] && ! sudo -n true 2>/dev/null; then
    echo "This installer needs sudo privileges." >&2
    exit 1
  fi
}

run_cmd() {
  log "INFO" "Running: $*"
  "$@" >>"${LOG_FILE}" 2>&1
}

run_apt_with_repair() {
  local apt_args=("$@")
  if run_cmd sudo env DEBIAN_FRONTEND=noninteractive apt-get "${apt_args[@]}"; then
    return 0
  fi

  log "WARN" "apt-get ${apt_args[*]} failed. Attempting repair and retry."
  run_cmd sudo dpkg --configure -a || true
  run_cmd sudo env DEBIAN_FRONTEND=noninteractive apt-get -f -y install || true
  run_cmd sudo apt-get update || true

  if run_cmd sudo env DEBIAN_FRONTEND=noninteractive apt-get "${apt_args[@]}"; then
    return 0
  fi

  log "ERROR" "apt-get ${apt_args[*]} failed after repair retry."
  return 1
}

run_compose_cmd() {
  if docker compose version >/dev/null 2>&1; then
    docker compose "$@"
    return 0
  fi
  if command -v docker-compose >/dev/null 2>&1; then
    docker-compose "$@"
    return 0
  fi
  log "ERROR" "No docker compose command available."
  return 1
}

prompt_default() {
  local var_name="$1"
  local prompt_text="$2"
  local default_value="$3"
  local input
  read -r -p "${prompt_text} [${default_value}]: " input
  if [[ -z "${input}" ]]; then
    input="${default_value}"
  fi
  printf -v "${var_name}" "%s" "${input}"
  log "INFO" "Input captured: ${var_name}"
}

prompt_required() {
  local var_name="$1"
  local prompt_text="$2"
  local input
  while true; do
    read -r -p "${prompt_text}: " input
    if [[ -n "${input}" ]]; then
      printf -v "${var_name}" "%s" "${input}"
      log "INFO" "Input captured: ${var_name}"
      return 0
    fi
    echo "Value is required."
  done
}

prompt_secret_required() {
  local var_name="$1"
  local prompt_text="$2"
  local input
  while true; do
    read -r -s -p "${prompt_text}: " input
    echo
    if [[ -n "${input}" ]]; then
      printf -v "${var_name}" "%s" "${input}"
      log "INFO" "Secret input captured: ${var_name}"
      return 0
    fi
    echo "Value is required."
  done
}

prompt_yes_no() {
  local var_name="$1"
  local prompt_text="$2"
  local default_value="${3:-yes}"
  local input normalized
  while true; do
    read -r -p "${prompt_text} [${default_value}] (yes/no): " input
    if [[ -z "${input}" ]]; then
      input="${default_value}"
    fi
    normalized="$(echo "${input}" | tr '[:upper:]' '[:lower:]')"
    if [[ "${normalized}" == "yes" || "${normalized}" == "no" ]]; then
      printf -v "${var_name}" "%s" "${normalized}"
      log "INFO" "Input captured: ${var_name}=${normalized}"
      return 0
    fi
    echo "Please enter yes or no."
  done
}

validate_port() {
  local value="$1"
  [[ "${value}" =~ ^[0-9]+$ ]] && (( value >= 1 && value <= 65535 ))
}

prompt_port() {
  local var_name="$1"
  local prompt_text="$2"
  local default_value="$3"
  local port_input
  while true; do
    read -r -p "${prompt_text} [${default_value}]: " port_input
    if [[ -z "${port_input}" ]]; then
      port_input="${default_value}"
    fi
    if validate_port "${port_input}"; then
      printf -v "${var_name}" "%s" "${port_input}"
      log "INFO" "Input captured: ${var_name}=${port_input}"
      return 0
    fi
    echo "Invalid port value. Must be 1-65535."
  done
}

ensure_command() {
  local cmd="$1"
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    log "ERROR" "Required command missing: ${cmd}"
    exit 1
  fi
}

safe_write_file() {
  local path="$1"
  local temp_file="$2"
  if [[ -f "${path}" ]]; then
    local overwrite
    prompt_yes_no overwrite "File ${path} exists. Overwrite?" "no"
    if [[ "${overwrite}" != "yes" ]]; then
      log "INFO" "Skipped existing file: ${path}"
      rm -f "${temp_file}"
      return 1
    fi
  fi
  mkdir -p "$(dirname "${path}")"
  mv "${temp_file}" "${path}"
  return 0
}

fetch_latest_github_release_tag() {
  local repo="$1"
  local tag
  tag="$(curl -fsSL "https://api.github.com/repos/${repo}/releases/latest" \
    | python3 -c "import json,sys; print(json.load(sys.stdin).get('tag_name',''))" 2>/dev/null || true)"
  echo "${tag}"
}

fetch_latest_docker_hub_numeric_tag() {
  local image="$1"
  local tag
  tag="$(curl -fsSL "https://registry.hub.docker.com/v2/repositories/${image}/tags?page_size=100" \
    | python3 -c "import json,re,sys
data=json.load(sys.stdin)
bad=('latest','edge','nightly')
for row in data.get('results',[]):
    name=row.get('name','')
    if name in bad:
        continue
    if any(k in name.lower() for k in ('alpha','beta','rc','dev')):
        continue
    if re.match(r'^[vV]?[0-9]+([._-][0-9]+)+$', name):
        print(name)
        break
" 2>/dev/null || true)"
  echo "${tag}"
}

detect_lan_subnet() {
  local iface_cidr
  iface_cidr="$(ip -o -f inet addr show scope global 2>/dev/null | awk '$2 !~ /^(docker|veth|br-|wg|tun)/ {print $4; exit}')"
  if [[ -z "${iface_cidr}" ]]; then
    echo "192.168.1.0/24"
    return 0
  fi

  python3 - "${iface_cidr}" <<'PY'
import ipaddress
import sys
cidr = sys.argv[1]
try:
    net = ipaddress.ip_interface(cidr).network
    print(str(net))
except Exception:
    print("192.168.1.0/24")
PY
}

detect_primary_lan_ip() {
  local ip
  ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
  if [[ -z "${ip}" ]]; then
    ip="127.0.0.1"
  fi
  echo "${ip}"
}

read_env_value() {
  local env_file="$1"
  local key="$2"
  if [[ ! -f "${env_file}" ]]; then
    return 0
  fi
  awk -F= -v target="${key}" '$1==target {sub(/^[^=]*=/,"",$0); print $0; exit}' "${env_file}"
}

choose_wg_subnet() {
  local lan_subnet="$1"
  local candidates=(
    "10.8.0.0/24"
    "10.9.0.0/24"
    "10.10.0.0/24"
    "172.22.0.0/24"
    "172.23.0.0/24"
  )
  local candidate
  for candidate in "${candidates[@]}"; do
    if python3 - "${lan_subnet}" "${candidate}" <<'PY'
import ipaddress
import sys
lan = ipaddress.ip_network(sys.argv[1], strict=False)
vpn = ipaddress.ip_network(sys.argv[2], strict=False)
sys.exit(1 if lan.overlaps(vpn) else 0)
PY
    then
      echo "${candidate}"
      return 0
    fi
  done
  echo "${DEFAULT_WG_SUBNET}"
}

apply_system_log_policies() {
  log "INFO" "Applying log rotation and journal size limits."

  run_cmd sudo python3 - <<'PY'
from pathlib import Path

logrotate_conf = """/opt/deployment/logs/*.log {
  weekly
  rotate 8
  compress
  delaycompress
  missingok
  notifempty
  copytruncate
  create 0640 root root
}
"""

Path("/etc/logrotate.d/opt-deployment").write_text(logrotate_conf, encoding="utf-8")
PY

  run_cmd sudo python3 - <<'PY'
from pathlib import Path

path = Path("/etc/systemd/journald.conf")
text = path.read_text(encoding="utf-8") if path.exists() else ""
lines = text.splitlines()

wanted = {
    "SystemMaxUse": "100M",
    "RuntimeMaxUse": "50M",
    "MaxRetentionSec": "2week",
}

seen = set()
out = []
for line in lines:
    stripped = line.strip()
    replaced = False
    for key, value in wanted.items():
        if stripped.startswith(f"{key}=") or stripped.startswith(f"#{key}="):
            out.append(f"{key}={value}")
            seen.add(key)
            replaced = True
            break
    if not replaced:
        out.append(line)

for key, value in wanted.items():
    if key not in seen:
        out.append(f"{key}={value}")

path.write_text("\n".join(out).rstrip() + "\n", encoding="utf-8")
PY

  run_cmd sudo systemctl restart systemd-journald
}

phase1_host_prep() {
  if [[ "${STATE_PHASE1_DONE}" == "1" ]]; then
    log "INFO" "Phase 1 already complete. Skipping."
    return 0
  fi
  log "INFO" "Phase 1/5: Host preparation started."
  require_root_or_sudo
  ensure_command curl
  ensure_command python3

  run_cmd sudo apt-get update
  run_apt_with_repair -y full-upgrade
  run_apt_with_repair -y install ca-certificates curl gnupg lsb-release ufw docker.io logrotate

  # Compose plugin is not available on all Pi OS repos. Fall back to docker-compose.
  if ! run_apt_with_repair -y install docker-compose-plugin; then
    log "INFO" "docker-compose-plugin unavailable; installing docker-compose fallback."
    run_apt_with_repair -y install docker-compose
  fi

  run_apt_with_repair -y autoremove
  run_cmd sudo apt-get clean

  run_cmd sudo systemctl enable docker
  run_cmd sudo systemctl start docker

  # Merge log options into daemon.json to avoid filling SD storage.
  run_cmd sudo python3 - <<'PY'
import json, os
path = "/etc/docker/daemon.json"
data = {}
if os.path.exists(path):
    with open(path, "r", encoding="utf-8") as fh:
        try:
            data = json.load(fh)
        except Exception:
            data = {}
data.setdefault("log-driver", "json-file")
opts = data.setdefault("log-opts", {})
opts["max-size"] = "10m"
opts["max-file"] = "3"
with open(path, "w", encoding="utf-8") as fh:
    json.dump(data, fh, indent=2)
PY
  run_cmd sudo systemctl restart docker
  run_compose_cmd version >>"${LOG_FILE}" 2>&1

  mkdir -p "${COMPOSE_DIR}" "${ENV_DIR}" "${DATA_DIR}" "${TARGET_SCRIPT_DIR}" "${LOG_DIR}"
  apply_system_log_policies
  LOG_FILE="${LOG_DIR}/installer-$(date +%Y%m%d-%H%M%S).log"
  touch "${LOG_FILE}"
  log "INFO" "Logging switched to ${LOG_FILE}"
  log "INFO" "Phase 1/5: Host preparation complete."
  mark_state_done STATE_PHASE1_DONE
}

collect_global_inputs() {
  if [[ "${STATE_GLOBALS_DONE}" == "1" ]]; then
    log "INFO" "Global settings already captured. Reusing from state."
    return 0
  fi
  log "INFO" "Collecting global settings."
  prompt_default GLOBAL_TIMEZONE "Timezone" "${DEFAULT_TIMEZONE}"
  SSH_PORT="${DEFAULT_SSH_PORT}"
  DETECTED_LAN_SUBNET="$(detect_lan_subnet)"
  log "INFO" "Detected LAN subnet: ${DETECTED_LAN_SUBNET}"
  prompt_yes_no RUN_DEPLOY "Deploy containers after generating files?" "yes"
  mark_state_done STATE_GLOBALS_DONE
}

write_duckdns_files() {
  if [[ "${STATE_DUCKDNS_FILES_DONE}" == "1" ]]; then
    log "INFO" "DuckDNS files already generated. Skipping."
    return 0
  fi
  local env_path="${ENV_DIR}/duckdns/duckdns.env"
  local compose_path="${COMPOSE_DIR}/duckdns/duckdns.yaml"
  local env_tmp compose_tmp
  env_tmp="$(mktemp)"
  compose_tmp="$(mktemp)"

  prompt_required DUCKDNS_TOKEN "DuckDNS token"
  prompt_required DUCKDNS_SUBDOMAINS "DuckDNS subdomains (comma-separated)"
  DUCKDNS_UID="1000"
  DUCKDNS_GID="1000"
  DUCKDNS_IMAGE_TAG="latest"
  log "INFO" "DuckDNS image tag fixed to ${DUCKDNS_IMAGE_TAG}"

  cat >"${env_tmp}" <<EOF
TZ=${GLOBAL_TIMEZONE}
PUID=${DUCKDNS_UID}
PGID=${DUCKDNS_GID}
TOKEN=${DUCKDNS_TOKEN}
SUBDOMAINS=${DUCKDNS_SUBDOMAINS}
DUCKDNS_IMAGE_TAG=${DUCKDNS_IMAGE_TAG}
EOF

  cat >"${compose_tmp}" <<EOF
services:
  duckdns:
    image: lscr.io/linuxserver/duckdns:${DUCKDNS_IMAGE_TAG}
    container_name: duckdns
    env_file:
      - /opt/deployment/env/duckdns/duckdns.env
    volumes:
      - /opt/deployment/data/duckdns:/config
    restart: unless-stopped
EOF

  safe_write_file "${env_path}" "${env_tmp}" || true
  safe_write_file "${compose_path}" "${compose_tmp}" || true
  mark_state_done STATE_DUCKDNS_FILES_DONE
}

write_heimdall_files() {
  if [[ "${STATE_HEIMDALL_FILES_DONE}" == "1" ]]; then
    log "INFO" "Heimdall files already generated. Skipping."
    return 0
  fi
  local env_path="${ENV_DIR}/heimdall/heimdall.env"
  local compose_path="${COMPOSE_DIR}/heimdall/heimdall.yaml"
  local env_tmp compose_tmp
  env_tmp="$(mktemp)"
  compose_tmp="$(mktemp)"

  HEIMDALL_UID="1000"
  HEIMDALL_GID="1000"
  HEIMDALL_PORT="${DEFAULT_HEIMDALL_PORT}"
  HEIMDALL_IMAGE_TAG="latest"
  log "INFO" "Heimdall port fixed to ${HEIMDALL_PORT}"
  log "INFO" "Heimdall image tag fixed to ${HEIMDALL_IMAGE_TAG}"

  cat >"${env_tmp}" <<EOF
TZ=${GLOBAL_TIMEZONE}
PUID=${HEIMDALL_UID}
PGID=${HEIMDALL_GID}
HEIMDALL_PORT=${HEIMDALL_PORT}
HEIMDALL_IMAGE_TAG=${HEIMDALL_IMAGE_TAG}
EOF

  cat >"${compose_tmp}" <<EOF
services:
  heimdall:
    image: lscr.io/linuxserver/heimdall:${HEIMDALL_IMAGE_TAG}
    container_name: heimdall
    env_file:
      - /opt/deployment/env/heimdall/heimdall.env
    ports:
      - "${HEIMDALL_PORT}:80/tcp"
    volumes:
      - /opt/deployment/data/heimdall:/config
    restart: unless-stopped
EOF

  safe_write_file "${env_path}" "${env_tmp}" || true
  safe_write_file "${compose_path}" "${compose_tmp}" || true
  mark_state_done STATE_HEIMDALL_FILES_DONE
}

write_pihole_files() {
  if [[ "${STATE_PIHOLE_FILES_DONE}" == "1" ]]; then
    log "INFO" "Pi-hole files already generated. Skipping."
    return 0
  fi
  local env_path="${ENV_DIR}/pihole/pihole.env"
  local compose_path="${COMPOSE_DIR}/pihole/pihole.yaml"
  local env_tmp compose_tmp
  env_tmp="$(mktemp)"
  compose_tmp="$(mktemp)"

  local suggested_tag
  suggested_tag="$(fetch_latest_docker_hub_numeric_tag "pihole/pihole")"
  if [[ -z "${suggested_tag}" ]]; then
    suggested_tag="latest"
  fi

  PIHOLE_DNS_PORT="${DEFAULT_PIHOLE_DNS_PORT}"
  PIHOLE_ADMIN_PORT="${DEFAULT_PIHOLE_ADMIN_PORT}"
  PIHOLE_IMAGE_TAG="${suggested_tag}"
  log "INFO" "Pi-hole upstream DNS left unset (configure in web UI)."
  log "INFO" "Pi-hole ports fixed to DNS=${PIHOLE_DNS_PORT}, ADMIN=${PIHOLE_ADMIN_PORT}"
  log "INFO" "Pi-hole image tag selected: ${PIHOLE_IMAGE_TAG}"

  cat >"${env_tmp}" <<EOF
TZ=${GLOBAL_TIMEZONE}
FTLCONF_dns_listeningMode=all
FTLCONF_webserver_port=80
PIHOLE_DNS_PORT=${PIHOLE_DNS_PORT}
PIHOLE_ADMIN_PORT=${PIHOLE_ADMIN_PORT}
PIHOLE_IMAGE_TAG=${PIHOLE_IMAGE_TAG}
EOF

  cat >"${compose_tmp}" <<EOF
services:
  pihole:
    image: pihole/pihole:${PIHOLE_IMAGE_TAG}
    container_name: pihole
    env_file:
      - /opt/deployment/env/pihole/pihole.env
    ports:
      - "${PIHOLE_DNS_PORT}:53/tcp"
      - "${PIHOLE_DNS_PORT}:53/udp"
      - "${PIHOLE_ADMIN_PORT}:80/tcp"
    volumes:
      - /opt/deployment/data/pihole/etc-pihole:/etc/pihole
      - /opt/deployment/data/pihole/etc-dnsmasq.d:/etc/dnsmasq.d
    cap_add:
      - NET_ADMIN
    restart: unless-stopped
EOF

  safe_write_file "${env_path}" "${env_tmp}" || true
  safe_write_file "${compose_path}" "${compose_tmp}" || true
  mark_state_done STATE_PIHOLE_FILES_DONE
}

write_wgeasy_files() {
  local env_path="${ENV_DIR}/wg-easy/wg-easy.env"
  local compose_path="${COMPOSE_DIR}/wg-easy/wg-easy.yaml"
  local env_tmp compose_tmp
  env_tmp="$(mktemp)"
  compose_tmp="$(mktemp)"

  if [[ "${STATE_WGEASY_FILES_DONE}" == "1" && -f "${env_path}" && -f "${compose_path}" ]]; then
    # Force regeneration if legacy v14-style keys are present.
    if grep -Eq "^(WG_HOST|WG_ADMIN_USER|PASSWORD|WG_DEFAULT_DNS|WG_DEFAULT_ADDRESS)=" "${env_path}"; then
      log "INFO" "WG-Easy legacy env detected. Regenerating WG-Easy files."
      STATE_WGEASY_FILES_DONE="0"
      save_state
    else
      log "INFO" "WG-Easy files already generated. Skipping."
      return 0
    fi
  fi

  local suggested_tag
  suggested_tag="$(fetch_latest_github_release_tag "wg-easy/wg-easy")"
  if [[ -z "${suggested_tag}" ]]; then
    suggested_tag="15.2.2"
  fi

  # v15 no longer uses WG_HOST/PASSWORD/WG_ADMIN_USER env vars.
  WG_UDP_PORT="${DEFAULT_WG_UDP_PORT}"
  WG_WEB_PORT="${DEFAULT_WG_WEB_PORT}"
  WG_EASY_IMAGE_TAG="${suggested_tag#v}"
  WG_INSECURE="true"
  log "INFO" "WG-Easy ports fixed to UDP=${WG_UDP_PORT}, WEB=${WG_WEB_PORT}"
  log "INFO" "WG-Easy web mode set to INSECURE=${WG_INSECURE} (HTTP UI)"
  log "INFO" "WG-Easy image tag selected: ${WG_EASY_IMAGE_TAG}"

  cat >"${env_tmp}" <<EOF
TZ=${GLOBAL_TIMEZONE}
WG_EASY_IMAGE_TAG=${WG_EASY_IMAGE_TAG}
WG_WEB_PORT=${WG_WEB_PORT}
WG_UDP_PORT=${WG_UDP_PORT}
WG_INSECURE=${WG_INSECURE}
EOF

  cat >"${compose_tmp}" <<EOF
services:
  wg-easy:
    image: ghcr.io/wg-easy/wg-easy:${WG_EASY_IMAGE_TAG}
    container_name: wg-easy
    env_file:
      - /opt/deployment/env/wg-easy/wg-easy.env
    environment:
      - INSECURE=${WG_INSECURE}
    ports:
      - "${WG_UDP_PORT}:51820/udp"
      - "${WG_WEB_PORT}:51821/tcp"
    volumes:
      - /opt/deployment/data/wg-easy:/etc/wireguard
      - /lib/modules:/lib/modules:ro
    cap_add:
      - NET_ADMIN
      - SYS_MODULE
    sysctls:
      - net.ipv4.ip_forward=1
      - net.ipv4.conf.all.src_valid_mark=1
      - net.ipv6.conf.all.disable_ipv6=0
      - net.ipv6.conf.all.forwarding=1
      - net.ipv6.conf.default.forwarding=1
    restart: unless-stopped
EOF

  safe_write_file "${env_path}" "${env_tmp}" || true
  safe_write_file "${compose_path}" "${compose_tmp}" || true
  mark_state_done STATE_WGEASY_FILES_DONE
}

write_watchtower_files() {
  local env_path="${ENV_DIR}/watchtower/watchtower.env"
  local compose_path="${COMPOSE_DIR}/watchtower/watchtower.yaml"
  local env_tmp compose_tmp
  env_tmp="$(mktemp)"
  compose_tmp="$(mktemp)"

  if [[ "${STATE_WATCHTOWER_FILES_DONE}" == "1" && -f "${env_path}" && -f "${compose_path}" ]]; then
    # Regenerate if legacy "vX.Y.Z" tag format is present for Docker Hub image.
    if grep -Eq '^WATCHTOWER_IMAGE_TAG=v' "${env_path}"; then
      log "INFO" "Watchtower legacy tag format detected. Regenerating Watchtower files."
      STATE_WATCHTOWER_FILES_DONE="0"
      save_state
    else
      log "INFO" "Watchtower files already generated. Skipping."
      return 0
    fi
  fi

  local suggested_tag
  suggested_tag="$(fetch_latest_github_release_tag "containrrr/watchtower")"
  if [[ -z "${suggested_tag}" ]]; then
    suggested_tag="latest"
  fi

  WATCHTOWER_SCHEDULE="${DEFAULT_WATCHTOWER_SCHEDULE}"
  WATCHTOWER_IMAGE_TAG="${suggested_tag#v}"
  log "INFO" "Watchtower schedule fixed to ${WATCHTOWER_SCHEDULE}"
  log "INFO" "Watchtower image tag selected: ${WATCHTOWER_IMAGE_TAG}"

  cat >"${env_tmp}" <<EOF
TZ=${GLOBAL_TIMEZONE}
WATCHTOWER_CLEANUP=true
WATCHTOWER_SCHEDULE=${WATCHTOWER_SCHEDULE}
WATCHTOWER_INCLUDE_RESTARTING=true
WATCHTOWER_ROLLING_RESTART=true
WATCHTOWER_IMAGE_TAG=${WATCHTOWER_IMAGE_TAG}
EOF

  cat >"${compose_tmp}" <<EOF
services:
  watchtower:
    image: containrrr/watchtower:${WATCHTOWER_IMAGE_TAG}
    container_name: watchtower
    env_file:
      - /opt/deployment/env/watchtower/watchtower.env
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
    command: --cleanup --schedule "${WATCHTOWER_SCHEDULE}"
    restart: unless-stopped
EOF

  safe_write_file "${env_path}" "${env_tmp}" || true
  safe_write_file "${compose_path}" "${compose_tmp}" || true
  mark_state_done STATE_WATCHTOWER_FILES_DONE
}

ensure_phase2_state_is_current() {
  local wg_env="${ENV_DIR}/wg-easy/wg-easy.env"
  local wt_env="${ENV_DIR}/watchtower/watchtower.env"

  # If resume state says done but legacy keys still exist, force regeneration.
  if [[ "${STATE_WGEASY_FILES_DONE}" == "1" && -f "${wg_env}" ]]; then
    if grep -Eq "^(WG_HOST|WG_ADMIN_USER|PASSWORD|WG_DEFAULT_DNS|WG_DEFAULT_ADDRESS)=" "${wg_env}"; then
      log "INFO" "Legacy WG-Easy env detected during phase precheck. Forcing WG-Easy file regeneration."
      STATE_WGEASY_FILES_DONE="0"
      save_state
    fi
  fi

  if [[ "${STATE_WATCHTOWER_FILES_DONE}" == "1" && -f "${wt_env}" ]]; then
    if grep -Eq '^WATCHTOWER_IMAGE_TAG=v' "${wt_env}"; then
      log "INFO" "Legacy Watchtower tag detected during phase precheck. Forcing Watchtower file regeneration."
      STATE_WATCHTOWER_FILES_DONE="0"
      save_state
    fi
  fi
}

phase2_generate_files() {
  ensure_phase2_state_is_current
  if [[ "${STATE_DUCKDNS_FILES_DONE}" == "1" && "${STATE_HEIMDALL_FILES_DONE}" == "1" && "${STATE_PIHOLE_FILES_DONE}" == "1" && "${STATE_WGEASY_FILES_DONE}" == "1" && "${STATE_WATCHTOWER_FILES_DONE}" == "1" ]]; then
    log "INFO" "Phase 2 already complete. Skipping."
    return 0
  fi
  log "INFO" "Phase 2/5: Generating compose/env files."

  mkdir -p \
    "${COMPOSE_DIR}/duckdns" "${ENV_DIR}/duckdns" "${DATA_DIR}/duckdns" \
    "${COMPOSE_DIR}/heimdall" "${ENV_DIR}/heimdall" "${DATA_DIR}/heimdall" \
    "${COMPOSE_DIR}/pihole" "${ENV_DIR}/pihole" "${DATA_DIR}/pihole" \
    "${COMPOSE_DIR}/wg-easy" "${ENV_DIR}/wg-easy" "${DATA_DIR}/wg-easy" \
    "${COMPOSE_DIR}/watchtower" "${ENV_DIR}/watchtower" "${DATA_DIR}/watchtower"

  write_duckdns_files
  write_heimdall_files
  write_pihole_files
  write_wgeasy_files
  write_watchtower_files

  log "INFO" "Phase 2/5 complete."
  save_state
}

install_maintenance_scripts() {
  log "INFO" "Installing maintenance scripts."
  run_cmd cp "${SCRIPT_DIR}/maintenance/weekly-os-update.sh" "${TARGET_SCRIPT_DIR}/weekly-os-update.sh"
  run_cmd cp "${SCRIPT_DIR}/maintenance/docker-cleanup.sh" "${TARGET_SCRIPT_DIR}/docker-cleanup.sh"
  run_cmd cp "${SCRIPT_DIR}/maintenance/firewall-harden.sh" "${TARGET_SCRIPT_DIR}/firewall-harden.sh"
  run_cmd cp "${SCRIPT_DIR}/maintenance/verify-stack.sh" "${TARGET_SCRIPT_DIR}/verify-stack.sh"

  # Normalize line endings on target scripts in case files were copied from Windows.
  run_cmd sed -i 's/\r$//' "${TARGET_SCRIPT_DIR}/weekly-os-update.sh"
  run_cmd sed -i 's/\r$//' "${TARGET_SCRIPT_DIR}/docker-cleanup.sh"
  run_cmd sed -i 's/\r$//' "${TARGET_SCRIPT_DIR}/firewall-harden.sh"
  run_cmd sed -i 's/\r$//' "${TARGET_SCRIPT_DIR}/verify-stack.sh"

  run_cmd chmod +x \
    "${TARGET_SCRIPT_DIR}/weekly-os-update.sh" \
    "${TARGET_SCRIPT_DIR}/docker-cleanup.sh" \
    "${TARGET_SCRIPT_DIR}/firewall-harden.sh" \
    "${TARGET_SCRIPT_DIR}/verify-stack.sh"
}

install_cron_entries() {
  log "INFO" "Configuring cron schedules."
  prompt_default OS_UPDATE_CRON "Cron for weekly OS update" "${DEFAULT_OS_UPDATE_CRON}"
  prompt_default CLEANUP_CRON "Cron for weekly Docker cleanup" "${DEFAULT_CLEANUP_CRON}"

  local current_cron new_cron
  current_cron="$(sudo crontab -l 2>/dev/null || true)"
  new_cron="$(printf "%s\n" "${current_cron}" | sed '/opt\/deployment\/scripts\/weekly-os-update.sh/d;/opt\/deployment\/scripts\/docker-cleanup.sh/d')"
  new_cron="${new_cron}"$'\n'"${OS_UPDATE_CRON} ${TARGET_SCRIPT_DIR}/weekly-os-update.sh >> ${LOG_DIR}/weekly-os-update.log 2>&1"
  new_cron="${new_cron}"$'\n'"${CLEANUP_CRON} ${TARGET_SCRIPT_DIR}/docker-cleanup.sh >> ${LOG_DIR}/docker-cleanup.log 2>&1"
  printf "%s\n" "${new_cron}" | sudo crontab -
}

fix_generated_compose_paths() {
  log "INFO" "Normalizing generated compose path references."
  local compose_files=(
    "${COMPOSE_DIR}/duckdns/duckdns.yaml"
    "${COMPOSE_DIR}/heimdall/heimdall.yaml"
    "${COMPOSE_DIR}/pihole/pihole.yaml"
    "${COMPOSE_DIR}/wg-easy/wg-easy.yaml"
    "${COMPOSE_DIR}/watchtower/watchtower.yaml"
  )
  local file
  for file in "${compose_files[@]}"; do
    if [[ -f "${file}" ]]; then
      run_cmd sed -i 's|\.\./\.\./\.\./env/|/opt/deployment/env/|g' "${file}"
      run_cmd sed -i 's|\.\./\.\./env/|/opt/deployment/env/|g' "${file}"
      run_cmd sed -i 's|\.\./\.\./\.\./data/|/opt/deployment/data/|g' "${file}"
      run_cmd sed -i 's|\.\./\.\./data/|/opt/deployment/data/|g' "${file}"
    fi
  done
}

materialize_compose_variables_from_env() {
  log "INFO" "Materializing compose variables from env files."
  run_cmd python3 - <<'PY'
import os
import re
from pathlib import Path

pairs = [
    (Path("/opt/deployment/compose/duckdns/duckdns.yaml"), Path("/opt/deployment/env/duckdns/duckdns.env")),
    (Path("/opt/deployment/compose/heimdall/heimdall.yaml"), Path("/opt/deployment/env/heimdall/heimdall.env")),
    (Path("/opt/deployment/compose/pihole/pihole.yaml"), Path("/opt/deployment/env/pihole/pihole.env")),
    (Path("/opt/deployment/compose/wg-easy/wg-easy.yaml"), Path("/opt/deployment/env/wg-easy/wg-easy.env")),
    (Path("/opt/deployment/compose/watchtower/watchtower.yaml"), Path("/opt/deployment/env/watchtower/watchtower.env")),
]

pattern = re.compile(r"\$\{([A-Za-z_][A-Za-z0-9_]*)\}")

def load_env(path: Path):
    out = {}
    if not path.exists():
        return out
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, val = line.split("=", 1)
        out[key.strip()] = val.strip()
    return out

for compose_path, env_path in pairs:
    if not compose_path.exists():
        continue
    env_map = load_env(env_path)
    text = compose_path.read_text(encoding="utf-8")
    def repl(match):
        key = match.group(1)
        return env_map.get(key, os.environ.get(key, match.group(0)))
    rendered = pattern.sub(repl, text)
    compose_path.write_text(rendered, encoding="utf-8")
PY
}

phase3_and_4_maintenance_and_scheduling() {
  if [[ "${STATE_PHASE34_DONE}" == "1" ]]; then
    log "INFO" "Phase 3/4 already complete. Refreshing maintenance scripts only."
    install_maintenance_scripts
    return 0
  fi
  log "INFO" "Phase 3/5 + 4/5: Maintenance scripts and scheduling."
  install_maintenance_scripts
  install_cron_entries
  log "INFO" "Phase 3/5 + 4/5 complete."
  mark_state_done STATE_PHASE34_DONE
}

verify_container_running() {
  local container_name="$1"
  local must_have_port="$2"
  if ! docker ps --format '{{.Names}}' | grep -Fxq "${container_name}"; then
    log "ERROR" "Container not running: ${container_name}"
    return 1
  fi
  if [[ -n "${must_have_port}" ]]; then
    if ! ss -lntu | grep -q ":${must_have_port} "; then
      log "ERROR" "Expected listening port not detected: ${must_have_port}"
      return 1
    fi
  fi
  return 0
}

deploy_one_app() {
  local app_name="$1"
  local container_name="$2"
  local port_check="${3:-}"
  local compose_file="${COMPOSE_DIR}/${app_name}/${app_name}.yaml"
  local env_file="${ENV_DIR}/${app_name}/${app_name}.env"

  log "INFO" "Deploying ${app_name}"
  run_cmd run_compose_cmd -f "${compose_file}" --env-file "${env_file}" up -d
  sleep 4
  if ! verify_container_running "${container_name}" "${port_check}"; then
    log "ERROR" "Deployment failed for ${app_name}"
    echo "Failure: ${app_name}"
    echo "Check: docker logs ${container_name}"
    echo "Installer log: ${LOG_FILE}"
    exit 1
  fi
  log "INFO" "${app_name} verified."
}

configure_pihole_password() {
  if [[ "${STATE_PIHOLE_PASSWORD_DONE}" == "1" ]]; then
    log "INFO" "Pi-hole password already configured. Skipping."
    return 0
  fi

  if ! docker ps --format '{{.Names}}' | grep -Fxq "pihole"; then
    log "ERROR" "Cannot set Pi-hole password because container is not running."
    return 1
  fi

  if [[ -t 0 && -t 1 ]]; then
    log "INFO" "Launching interactive Pi-hole password setup."
    echo
    echo "Set Pi-hole web password now (interactive)."
    echo "When prompted, enter your desired password."
    sudo docker exec -it pihole pihole setpassword
    log "INFO" "Pi-hole password was set via pihole setpassword."
    mark_state_done STATE_PIHOLE_PASSWORD_DONE
  else
    log "WARN" "Skipping Pi-hole password setup (no interactive terminal)."
    log "WARN" "Run manually: sudo docker exec -it pihole pihole setpassword"
  fi
}

phase5_deploy_and_verify() {
  if [[ "${STATE_INSTALL_COMPLETE}" == "1" ]]; then
    log "INFO" "Install already completed previously. Nothing to do."
    return 0
  fi
  if [[ "${RUN_DEPLOY}" != "yes" ]]; then
    log "INFO" "Deployment skipped by user choice."
    return 0
  fi

  fix_generated_compose_paths
  materialize_compose_variables_from_env
  log "INFO" "Phase 5/5: Deploying services one by one."
  if [[ "${STATE_DEPLOY_DUCKDNS_DONE}" != "1" ]]; then
    deploy_one_app "duckdns" "duckdns"
    mark_state_done STATE_DEPLOY_DUCKDNS_DONE
  fi
  if [[ "${STATE_DEPLOY_HEIMDALL_DONE}" != "1" ]]; then
    deploy_one_app "heimdall" "heimdall" "${HEIMDALL_PORT}"
    mark_state_done STATE_DEPLOY_HEIMDALL_DONE
  fi
  if [[ "${STATE_DEPLOY_PIHOLE_DONE}" != "1" ]]; then
    deploy_one_app "pihole" "pihole" "${PIHOLE_DNS_PORT}"
    mark_state_done STATE_DEPLOY_PIHOLE_DONE
  fi
  configure_pihole_password
  if [[ "${STATE_DEPLOY_WGEASY_DONE}" != "1" ]]; then
    deploy_one_app "wg-easy" "wg-easy" "${WG_UDP_PORT}"
    mark_state_done STATE_DEPLOY_WGEASY_DONE
  fi
  if [[ "${STATE_DEPLOY_WATCHTOWER_DONE}" != "1" ]]; then
    deploy_one_app "watchtower" "watchtower"
    mark_state_done STATE_DEPLOY_WATCHTOWER_DONE
  fi

  run_cmd "${TARGET_SCRIPT_DIR}/verify-stack.sh" "${BASE_DIR}"
  if [[ "${STATE_FIREWALL_DONE}" != "1" ]]; then
    log "INFO" "Applying firewall hardening at end of deployment."
    run_cmd "${TARGET_SCRIPT_DIR}/firewall-harden.sh" "${SSH_PORT}" "${HEIMDALL_PORT}" "${PIHOLE_DNS_PORT}" "${PIHOLE_ADMIN_PORT}" "${WG_UDP_PORT}" "${WG_WEB_PORT}"
    mark_state_done STATE_FIREWALL_DONE
  fi
  mark_state_done STATE_INSTALL_COMPLETE
  log "INFO" "Phase 5/5 complete."
}

print_summary() {
  local lan_ip duck_subdomains wg_web_port heimdall_port pihole_admin_port
  lan_ip="$(detect_primary_lan_ip)"
  duck_subdomains="$(read_env_value "${ENV_DIR}/duckdns/duckdns.env" "SUBDOMAINS")"
  wg_web_port="$(read_env_value "${ENV_DIR}/wg-easy/wg-easy.env" "WG_WEB_PORT")"
  heimdall_port="$(read_env_value "${ENV_DIR}/heimdall/heimdall.env" "HEIMDALL_PORT")"
  pihole_admin_port="$(read_env_value "${ENV_DIR}/pihole/pihole.env" "PIHOLE_ADMIN_PORT")"

  if [[ -z "${wg_web_port}" ]]; then wg_web_port="${DEFAULT_WG_WEB_PORT}"; fi
  if [[ -z "${heimdall_port}" ]]; then heimdall_port="${DEFAULT_HEIMDALL_PORT}"; fi
  if [[ -z "${pihole_admin_port}" ]]; then pihole_admin_port="${DEFAULT_PIHOLE_ADMIN_PORT}"; fi

  cat <<EOF

Installer finished.
Deployment root: ${BASE_DIR}
Compose files:    ${COMPOSE_DIR}
Env files:        ${ENV_DIR}
Data files:       ${DATA_DIR}
Scripts:          ${TARGET_SCRIPT_DIR}
Logs:             ${LOG_DIR}
Latest log:       ${LOG_FILE}

Service links (LAN):
  Heimdall:        http://${lan_ip}:${heimdall_port}
  Pi-hole Admin:   http://${lan_ip}:${pihole_admin_port}/admin
  WG-Easy UI:      http://${lan_ip}:${wg_web_port}

Service links (hostname/domain):
  DuckDNS host:    ${duck_subdomains:-<set in duckdns.env>}.duckdns.org

Important files and where to change things:
  DuckDNS env:     ${ENV_DIR}/duckdns/duckdns.env
  DuckDNS compose: ${COMPOSE_DIR}/duckdns/duckdns.yaml
  Heimdall env:    ${ENV_DIR}/heimdall/heimdall.env
  Heimdall compose:${COMPOSE_DIR}/heimdall/heimdall.yaml
  Pi-hole env:     ${ENV_DIR}/pihole/pihole.env
  Pi-hole compose: ${COMPOSE_DIR}/pihole/pihole.yaml
  WG-Easy env:     ${ENV_DIR}/wg-easy/wg-easy.env
  WG-Easy compose: ${COMPOSE_DIR}/wg-easy/wg-easy.yaml
  Watchtower env:  ${ENV_DIR}/watchtower/watchtower.env
  Watchtower comp: ${COMPOSE_DIR}/watchtower/watchtower.yaml
  Firewall script: ${TARGET_SCRIPT_DIR}/firewall-harden.sh
  Cron scripts:    ${TARGET_SCRIPT_DIR}/weekly-os-update.sh, ${TARGET_SCRIPT_DIR}/docker-cleanup.sh

Useful commands:
  sudo docker ps
  sudo docker compose -f ${COMPOSE_DIR}/pihole/pihole.yaml --env-file ${ENV_DIR}/pihole/pihole.env ps
  sudo docker compose -f ${COMPOSE_DIR}/wg-easy/wg-easy.yaml --env-file ${ENV_DIR}/wg-easy/wg-easy.env ps
  sudo docker exec -it pihole pihole setpassword
  sudo ${TARGET_SCRIPT_DIR}/verify-stack.sh ${BASE_DIR}
  sudo ufw status verbose
EOF
}

main() {
  echo "Raspberry Pi Homelab Installer (Pi 3B / 3B+)"
  echo "This script prepares files first, then deploys and verifies services."
  load_state
  collect_global_inputs
  phase1_host_prep
  phase2_generate_files
  phase3_and_4_maintenance_and_scheduling
  phase5_deploy_and_verify
  print_summary
}

main "$@"
