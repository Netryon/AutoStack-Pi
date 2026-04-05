# AutoStack Pi

**Version:** v0.1.0  
**Status:** Stable for current scope; see [Roadmap](#roadmap) for planned expansion.

Interactive **Bash** installer for Raspberry Pi **3B / 3B+** that prepares the host, generates **per-app Docker Compose + env files** under `/opt/deployment`, deploys services **one at a time** with verification, schedules maintenance, and applies **UFW** hardening.

## What ships in v0.1

| Service    | Role |
|-----------|------|
| **DuckDNS** | Dynamic DNS updates |
| **Heimdall** | Local web dashboard |
| **Pi-hole** | LAN DNS / ad-blocking |
| **WG-Easy** | WireGuard VPN (UI + management) |
| **Watchtower** | Scheduled container image updates |

The installer builds everything first, then deploys services in order with checks after each step. State is tracked for **rerun / resume** (`~/.pi-homelab-installer.state`).

---

## Why this exists

- Turn a fresh Pi into a **repeatable** home/lab edge node: DNS, portal, VPN, DDNS, and update hygiene.
- **No static dump of secrets in the repo** — values are collected at install time and written to `/opt/deployment/env/`.
- **SD-card aware**: Docker log limits, logrotate, scheduled cleanup, journald caps.

---

## Requirements

- **Hardware:** Raspberry Pi 3B or 3B+ (tested target).
- **OS:** Raspberry Pi OS (Bookworm or current supported image); **64-bit recommended** if your stack images require it.
- **Access:** Keyboard/SSH, `sudo`, outbound internet for images and updates.
- **Disk:** Prefer quality SD or USB boot; 32 GB+ typical for logs and image layers.

---

## Repository layout

| Path | Purpose |
|------|---------|
| `autoStack_Pi/install.sh` | Main interactive installer |
| `autoStack_Pi/maintenance/weekly-os-update.sh` | Scheduled OS updates |
| `autoStack_Pi/maintenance/docker-cleanup.sh` | Prune unused Docker data (volumes not auto-removed) |
| `autoStack_Pi/maintenance/verify-stack.sh` | Stack health check |
| `autoStack_Pi/maintenance/firewall-harden.sh` | UFW rules aligned with deployed ports |
| `instruction.txt` | Original design spec (reference) |

---

## Runtime layout (created on the Pi)

All generated assets live under **`/opt/deployment`** (not under `$HOME`):

```
/opt/deployment/
├── compose/     # per-app compose YAML
├── env/         # per-app .env (secrets live here on disk — never commit)
├── data/        # persistent volumes
├── scripts/     # deployed maintenance helpers
└── logs/        # installer + maintenance logs
```

---

## Quick start

1. **Clone or copy** this repository onto the Pi.
2. **Open the installer directory** (the folder that contains `install.sh`):

   ```bash
   cd /path/to/AutoStack-Pi/autoStack_Pi
   ```

   If your clone has an extra nested folder, adjust the path until `install.sh` is in the current directory.

3. **Make scripts executable:**

   ```bash
   chmod +x install.sh maintenance/*.sh
   ```

4. **Run the installer** (must be root for Docker/UFW/system paths):

   ```bash
   sudo ./install.sh
   ```

5. Follow prompts. On failure, check logs (see [Troubleshooting](#troubleshooting)) and re-run; resume state is stored in `~/.pi-homelab-installer.state`.

---

## Installer flow (summary)

1. Host prep — OS update, Docker Engine + Compose plugin, Docker log rotation, directories, logging.
2. File generation — compose + env + data dirs per app (prompts per service).
3. Maintenance scripts copied to `/opt/deployment/scripts`.
4. Cron — weekly OS update, Watchtower schedule, Docker cleanup (timings configurable during install).
5. Deploy in order with verification: **DuckDNS → Heimdall → Pi-hole → WG-Easy → Watchtower**.
6. Firewall hardening — UFW rules for SSH, LAN-scoped web/DNS where intended, WireGuard UDP.
7. Final summary — URLs, paths, useful commands.

---

## Important behavior notes

- **Pi-hole password** is set interactively after deployment via `pihole setpassword` inside the container (as implemented by the installer flow).
- **Pi-hole DNS listening** is forced LAN-safe: `FTLCONF_dns_listeningMode=all`.
- **Pi-hole upstream DNS** is not hardcoded in the installer narrative — choose in the web UI after deploy unless your generated env sets it.
- **WG-Easy** uses **v15-compatible** configuration (no legacy v14 auth env vars).
- **WG-Easy web UI** may use HTTP mode (`INSECURE=true`) unless you terminate TLS with a reverse proxy — **do not expose that UI to the public internet** without TLS and strong auth.

---

## Maintenance and SD card protection

- Docker daemon: `max-size=10m`, `max-file=3` (global log rotation).
- Weekly OS update + autoremove + apt cache clean.
- Weekly Docker cleanup (unused images/containers/networks/build cache); **volumes preserved by design**.
- Watchtower cleanup enabled where configured.
- Logrotate for `/opt/deployment/logs/*.log`.
- Journald size retention limits applied during host prep.

---

## Common commands

```bash
sudo docker ps
sudo /opt/deployment/scripts/verify-stack.sh /opt/deployment
sudo docker exec -it pihole pihole setpassword
sudo ufw status verbose
```

### Logs

```bash
sudo tail -n 120 /opt/deployment/logs/installer-*.log
sudo docker logs pihole --tail 120
sudo docker logs wg-easy --tail 120
sudo docker logs watchtower --tail 120
```

### Docker permission denied (non-root user)

```bash
sudo usermod -aG docker "$USER"
# then log out and back in
```

---

## Security and threat model

- Intended for **home / lab** on a **trusted LAN**. This is not a managed security product.
- **Secrets** only belong in `/opt/deployment/env/` on the Pi — **never** push `.env` files to Git.
- **SSH:** default assumption port **22**; change in installer if you use non-standard SSH.
- **UFW:** Heimdall, Pi-hole admin, and WG-Easy web are **LAN-scoped** in the hardening design; **WireGuard UDP** is exposed by design for remote VPN.
- **Before** exposing any admin UI to WAN: use **VPN first**, or put **TLS + reverse proxy** in front (planned expansion — see Roadmap).

---

## Roadmap (future expansion)

Planned directions (not promises for v0.1):

| Direction | Goal |
|-----------|------|
| **Modular catalog** | Pick which apps to install from a list instead of a fixed bundle. |
| **More services** | e.g. Vaultwarden, reverse proxy (Caddy/Traefik), optional AdGuard Home, etc. |
| **Guided presets** | “Minimal / Standard / Remote access” profiles with safe defaults for beginners. |
| **TLS termination** | Reverse proxy + Let’s Encrypt (DNS-01 or HTTP-01) where applicable. |
| **Backup / restore** | Documented export of `/opt/deployment/data` and env templates (not secrets). |
| **CI / shellcheck** | Lint installer on push; optional dry-run mode. |
| **ARM / Pi 4 / Pi 5** | Explicit test matrix and image pin verification per release. |

If you use this repo publicly, tag releases (e.g. `v0.1.0`) and note breaking changes in a `CHANGELOG.md` when you add them.

---

## For maintainers (commits & releases)

Do not commit anything copied from a Pi under **`/opt/deployment`**, live **`.env`** files, or **`~/.pi-homelab-installer.state`**. This repo includes a **`.gitignore`** for common mistakes; still run **`git status`** before every push. Optional later: **`.env.example`** stubs (no secrets) for each app.

---

## Troubleshooting

- Installer log: `sudo tail -n 120 /opt/deployment/logs/installer-*.log` (and `/tmp/pi-homelab-installer.log` during early bootstrap if used).
- Resume: re-run `sudo ./install.sh` — state file tracks completed phases.
- Compose issues: inspect `docker compose -f /opt/deployment/compose/<app>/<app>.yaml --env-file /opt/deployment/env/<app>/<app>.env ps`.

---

## Contributing / development

- Prefer **small PRs**: one feature or fix per change.
- Run **`shellcheck`** on `install.sh` and `maintenance/*.sh` before merging when possible.
- Keep **image tags pinned** to verified versions per `instruction.txt` design rules (avoid blind `latest` unless upstream recommends it).

---

## License

**MIT** — see [`LICENSE`](LICENSE) in this directory.

Homelab / learning use: review security and networking before relying on this in production.

---

## Author

Maintained by **[Netryon](https://github.com/Netryon)** — portfolio / homelab automation.
