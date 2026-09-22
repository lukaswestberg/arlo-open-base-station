# Installation Guide

## What This Replaces

This project is a complete replacement for:

| Commercial Product | What It Does | Status After Migration |
|-------------------|--------------|------------------------|
| **Arlo Base Station VMB4000** | WiFi hub for Arlo Pro cameras | Not needed |
| **Arlo Base Station VMB5000** | WiFi hub for Arlo Pro 2/3 cameras | Not needed |
| **Arlo SmartHub VMB4540** | Newer base station model | Not needed |
| **Arlo Cloud Subscription** | Cloud storage, notifications | Replaced by local storage + ntfy |
| **Arlo App** | Mobile viewing, alerts | Replaced by web viewer |

### What You Gain
- No monthly subscription fees
- Local storage (no cloud dependency)
- Extended WiFi range (with proper hardware)
- Self-hosted push notifications
- Full control over your camera system

### What You Lose
- Arlo app integration
- Geofencing / smart home integrations
- Cloud backup redundancy
- Official support

## Hardware Requirements

### Compute
- Linux machine (Ubuntu 20.04+ recommended)
- Raspberry Pi 4, old laptop, or mini PC all work fine
- **RAM**: 1GB minimum, 2GB+ recommended
- **Storage**: 10GB for OS + packages, plus 1-2GB per day of recordings
  (20GB minimum for 7-day retention with 2 cameras)

### WiFi Access Point (CRITICAL)

**The WiFi hardware choice is critical.** Arlo cameras sleep deeply to conserve battery and expect the WiFi connection to remain stable during sleep. Consumer USB WiFi adapters often drop sleeping clients, forcing cameras to reconnect every ~30 minutes and drain battery.

| Hardware Type | Sleep Support | Result |
|--------------|---------------|--------|
| Enterprise AP (TP-Link Omada) | Excellent | Cameras sleep 2-5 hours |
| Consumer USB (RTL8812AU) | Poor | Cameras reconnect every 30 min |
| Intel integrated WiFi | Varies | Usually poor |

**Recommended:** TP-Link Omada EAP225 or similar enterprise AP
- Proper 802.11n power save support
- Cameras sleep for hours, wake instantly on motion
- No configuration needed beyond basic SSID/password

**Not Recommended:** USB WiFi adapters with RTL8812AU/RTL8814AU chipsets
- Great range (30 dBm) but driver issues in AP mode
- Power management conflicts with sleeping clients
- Results in constant reconnections and battery drain

See [WIFI-HARDWARE.md](WIFI-HARDWARE.md) for the full technical investigation.

### Cameras
- Arlo Pro VMC4030 (upstream) and Arlo Ultra VMC5040 (firmware 58.0.15) tested
- No custom firmware needed: cameras pair to your own AP over WPS

## External Infrastructure (Optional)

For remote access to recordings and push notifications from outside your home network, you'll need:

### Domain Name
- A domain pointing to your public server (e.g., `security.yourdomain.com`)
- Used for accessing the web viewer and receiving notifications remotely

### Public Server (VPS)
- A small VPS or cloud instance (512MB RAM is sufficient)
- Runs [bore](https://github.com/ekzhang/bore) server to tunnel traffic
- Runs reverse proxy (Caddy/nginx) for SSL termination

### SSL Certificates
- Required for HTTPS access and ntfy push notifications
- Caddy provides automatic Let's Encrypt certificates
- Or use your own certificate provider

### Example Setup
```
┌─────────────────┐         ┌─────────────────┐
│   arlo-base     │  bore   │   VPS/Droplet   │
│   (home LAN)    │ ──────> │ (public IP)     │
├─────────────────┤         ├─────────────────┤
│ :3003 viewer    │ ──────> │ :8084 ──> Caddy │──> security.domain.com
│ :8085 ntfy      │ ──────> │ :8085 ──> Caddy │──> ntfy.domain.com
└─────────────────┘         └─────────────────┘
```

### Local-Only Operation
If you only need access from your home network:
- Skip bore tunnel setup
- Access viewer directly at `http://arlo-base:3003`
- Use public `ntfy.sh` for notifications (no self-hosting needed)

## Quick Start

Tested on an Orange Pi 5 Pro (Ubuntu 22.04, arm64) using its onboard WiFi as
the camera access point. Any Debian/Ubuntu machine with an AP-capable radio
that is **not** its uplink should work.

```bash
git clone <your fork> arlo-open-base-station
cd arlo-open-base-station

# Optional: every setting has a working default
cp config/install.conf.example config/install.conf
nano config/install.conf

sudo scripts/install.sh          # add --yes to skip the prompt

sudo arlo-pair                   # then hold the camera's SYNC button ~2 s
```

No reboot is needed. The installer finishes with health checks and prints the
viewer URL and login.

## What the Installer Does

| Step | Detail |
|------|--------|
| Preflight | Refuses to use a WiFi interface that carries the default route or any SSH session. Validates SSID/password characters. Warns if ports 4000/5000/3003 are taken or Python is newer than 3.10 |
| Packages | hostapd, dnsmasq-base (binary only, no system dnsmasq service), iw, GStreamer (good/bad plugins), ffmpeg (thumbnails only), python3-venv, nodejs/npm |
| Layout | Everything under `BASE_DIR` (default `~/arlo`): `app/` (backend, venv, config.yaml, arlo.db), `viewer/`, `recordings/`, `logs/`, `.env`. Services run as your login user |
| WiFi AP | Writes `/etc/hostapd/hostapd.conf` (WPA2-CCMP, WMM, WPS push-button). The AP address comes from a hostapd systemd drop-in, not netplan. The radio is marked unmanaged in NetworkManager **without restarting NM**, so SSH is not interrupted |
| DHCP | A private dnsmasq instance, `arlo-dhcp.service` with `/etc/arlo/dnsmasq.conf`: DHCP only (`port=0`), tied to hostapd. `/etc/dnsmasq.conf`, `/etc/dnsmasq.d` and any Pi-hole are left alone |
| Services | `arlo.service` and `arlo-viewer.service`, plus optional bore tunnels. The backend log is rotated weekly |
| Helpers | `arlo-pair` (WPS pairing and waits for registration) and `arlo-status` |

**What it does not touch:** the firewall, the system dnsmasq/Pi-hole, port 53
and IP forwarding. Cameras need no internet access. If your host firewall
defaults to DROP on the camera interface, allow inbound TCP 4000 and UDP 67
there. Also allow the RTP/RTCP replies to recordings: the host pulls RTSP from
camera:554 over UDP, so allow inbound UDP from the camera subnet, or at least
ESTABLISHED/RELATED. Allow TCP 3003 (and 5000 if wanted) from your LAN.

**Re-running** redeploys the code and keeps `config.yaml`, `arlo.db`, `.env`
and the AP's SSID and passphrase (unless you set them explicitly), so paired
cameras stay paired. If an older install lives elsewhere (e.g. `/opt/arlo-cam-api`),
point `BASE_DIR` at it or its database and camera names will not carry over.
A hand-built `/etc/dnsmasq.d/arlo.conf` is migrated to `arlo-dhcp.service`.

## Updating

After pushing changes to your fork, on the host:

```bash
cd ~/arlo-open-base-station
scripts/update.sh
```

This pulls with `--ff-only`, shows the new commits, and runs
`sudo scripts/install.sh --update`, which:

- redeploys `src/` into the live install and refreshes pip/npm dependencies;
- takes the install location, user, WiFi interface and node binary from
  the live setup (systemd units and `hostapd.conf`), not from `install.conf`;
- restarts only `arlo` and `arlo-viewer`. hostapd and DHCP keep running, so
  cameras stay connected;
- keeps `config.yaml`, `arlo.db` and `.env`, and records the deployed commit in
  `BASE_DIR/.deployed-version`.

`--update` skips packages, all WiFi/DHCP setup and the bore tunnel units.
A host set up by hand or by an older installer (no `arlo-dhcp.service`) is
refused until it has had one full `sudo scripts/install.sh` run. After changes to those, or
to add a key a new version needs in `config.yaml`, run the full
`sudo scripts/install.sh` instead; it is equally safe to re-run.
`update.sh` points this out when the installer itself changed.

Don't edit files in the live install directly. `--update` replaces `app/`
and `viewer/` code (everything except `config.yaml`, `arlo.db`, `venv/` and
`node_modules/`) with what is in the repo.

## Configuration Reference

`config/install.conf` (all optional):

| Variable | Default | Description |
|----------|---------|-------------|
| `ARLO_USER` | user who ran sudo | Account the services run as |
| `BASE_DIR` | `~/arlo` | Install root |
| `WIFI_INTERFACE` | `wlan0` | AP radio (`iw dev` to list) |
| `WIFI_SSID` | current, else `ARLO_VMB` | Camera network name. Changing it later means re-pairing |
| `WIFI_PASSWORD` | current, else generated | WPA2 passphrase, alphanumeric recommended |
| `WIFI_COUNTRY` | `US` | Regulatory domain for both AP and cameras |
| `WIFI_CHANNEL` | `6` | 2.4 GHz channel |
| `AP_SUBNET` | `172.14.1` | Camera subnet. Base station is `.1`, cameras `.100-.199` |
| `VIEWER_PASSWORD` | generated | Web viewer login |
| `RETENTION_DAYS` | `7` | Recording retention |
| `MOTION_CLIP_SECONDS` | `10` | Clip length per motion event |
| `NTFY_*` | disabled | Push notifications via [ntfy](https://ntfy.sh) |
| `BORE_*` | disabled | Remote access via [bore](https://github.com/ekzhang/bore) |

Runtime settings live in `BASE_DIR/app/config.yaml` (see
`config/config.yaml.example`). Restart `arlo` after editing it. Settings
that are sent to the camera, such as the country code and PIR, only apply when
the camera re-registers. It does that on its own every few hours; to force
it, pull the battery for ~2 s.

## Pairing a Camera

```bash
sudo arlo-pair
```

1. Unplug any real Arlo base station.
2. Keep the camera within a few metres of the host.
3. Run `arlo-pair`, then hold the camera's **SYNC** button ~2 s until it
   blinks blue.
4. The camera associates, finishes WPS, reconnects with WPA2, gets a DHCP
   lease and registers. This usually takes under 20 s. `arlo-pair` prints the
   serial, so you can add a friendly name under `CameraAliases`.

A hostapd line like `IEEE 802.1X: authentication failed - EAP type: 0` right
after the first association is the normal end of WPS, not an error.

Pairing to your own AP removes the camera from Arlo's ecosystem. Going back to
an Arlo base station requires a factory reset.

## Verification

```bash
arlo-status                          # services, WiFi clients, leases, cameras
curl http://localhost:5000/cameras/status
```

## Troubleshooting

```bash
tail -f ~/arlo/logs/arlo-service.log
journalctl -u hostapd -u arlo-dhcp -f
journalctl -u arlo-viewer -f
```

| Symptom | Fix |
|---------|-----|
| hostapd: `Could not configure driver mode` / `nl80211 driver initialization failed` | Something else holds the radio (wpa_supplicant, NetworkManager), or a P2P device exists: find the `p2p-dev-wlan0` wdev id in `iw dev`, then `sudo iw wdev <id> del && sudo systemctl restart hostapd` |
| Camera associates but never registers | Check that `arlo` is listening on :4000 and that the camera got a lease with gateway `AP_SUBNET.1` |
| Camera shows offline | The connectivity checker runs every 5 min using `iw station dump`, with the ARP cache as fallback |
| Motion alerts but no clip | Check `recordings/gst-*.log`. Recording uses GStreamer because ffmpeg cannot open the Ultra's RTSP stream |
| No motion alerts at all | The camera must re-register after an upgrade so it receives the PIR settings. Pull its battery for ~2 s |
