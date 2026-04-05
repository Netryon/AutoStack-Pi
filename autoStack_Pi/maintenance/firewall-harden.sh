#!/usr/bin/env bash
set -Eeuo pipefail

SSH_PORT="${1:-22}"
HEIMDALL_PORT="${2:-8080}"
PIHOLE_DNS_PORT="${3:-53}"
PIHOLE_ADMIN_PORT="${4:-8081}"
WG_UDP_PORT="${5:-51820}"
WG_WEB_PORT="${6:-51821}"
BASE_DIR="/opt/deployment"
LOG_DIR="${BASE_DIR}/logs"
LOG_FILE="${LOG_DIR}/firewall-harden.log"

mkdir -p "${LOG_DIR}"

{
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] Starting firewall hardening with UFW"

  sudo ufw --force reset
  sudo ufw default deny incoming
  sudo ufw default allow outgoing

  # Always keep SSH open for remote safety.
  sudo ufw allow "${SSH_PORT}/tcp" comment "SSH"

  # Heimdall and Pi-hole web are LAN-only.
  sudo ufw allow from 10.0.0.0/8 to any port "${HEIMDALL_PORT}" proto tcp comment "Heimdall LAN"
  sudo ufw allow from 172.16.0.0/12 to any port "${HEIMDALL_PORT}" proto tcp comment "Heimdall LAN"
  sudo ufw allow from 192.168.0.0/16 to any port "${HEIMDALL_PORT}" proto tcp comment "Heimdall LAN"

  sudo ufw allow "${PIHOLE_DNS_PORT}/udp" comment "Pi-hole DNS UDP"
  sudo ufw allow "${PIHOLE_DNS_PORT}/tcp" comment "Pi-hole DNS TCP"
  sudo ufw allow from 10.0.0.0/8 to any port "${PIHOLE_ADMIN_PORT}" proto tcp comment "Pi-hole Admin LAN"
  sudo ufw allow from 172.16.0.0/12 to any port "${PIHOLE_ADMIN_PORT}" proto tcp comment "Pi-hole Admin LAN"
  sudo ufw allow from 192.168.0.0/16 to any port "${PIHOLE_ADMIN_PORT}" proto tcp comment "Pi-hole Admin LAN"

  sudo ufw allow "${WG_UDP_PORT}/udp" comment "WireGuard UDP"
  sudo ufw allow from 10.0.0.0/8 to any port "${WG_WEB_PORT}" proto tcp comment "WG-Easy Web LAN"
  sudo ufw allow from 172.16.0.0/12 to any port "${WG_WEB_PORT}" proto tcp comment "WG-Easy Web LAN"
  sudo ufw allow from 192.168.0.0/16 to any port "${WG_WEB_PORT}" proto tcp comment "WG-Easy Web LAN"

  # Docker + UFW compatibility: route forwarded docker traffic through UFW policy chain.
  if ! grep -q "ufw-user-forward" /etc/ufw/after.rules; then
    sudo bash -c 'cat >> /etc/ufw/after.rules << "EOF"

# BEGIN PI-HOMELAB-UFW-DOCKER
*filter
:PI-HOMELAB-DOCKER - [0:0]
-A PI-HOMELAB-DOCKER -j RETURN
-A DOCKER-USER -j PI-HOMELAB-DOCKER
COMMIT
# END PI-HOMELAB-UFW-DOCKER
EOF'
  fi

  sudo ufw --force enable
  sudo ufw status verbose
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] Firewall hardening complete"
} >>"${LOG_FILE}" 2>&1
