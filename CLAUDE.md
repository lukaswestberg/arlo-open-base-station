# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

Arlo Open Base Station - a DIY replacement for Arlo's commercial base stations.

## Project Overview

This project provides a complete replacement for Arlo's commercial base station (VMB4000/VMB5000) using commodity hardware. It enables:

- Direct camera communication without Arlo cloud services
- Local motion-triggered recordings
- Self-hosted push notifications via ntfy
- Web-based video viewer
- Extended WiFi range compared to commercial base stations

## Repository vs. Live Deployment

**IMPORTANT**: This repository is for VERSION CONTROL only. It contains sanitized code and configuration templates. The actual running services read from a separate LIVE DEPLOYMENT.

### What's in the Repository (Version Control)
```
~/arlo-open-base-station/           # This repo
├── src/arlo-cam-api/               # Source code (sanitized)
├── src/arlo-viewer/                # Source code (sanitized)
├── config/*.example                # Config TEMPLATES (no secrets)
└── docs/                           # Documentation
```

### What's in the Live Deployment (Runtime)
```
~/arlo/                             # BASE_DIR from install.conf (default ~/arlo)
├── app/                            # RUNNING Python backend (arlo.service)
│   ├── config.yaml                 # LIVE config with real secrets
│   ├── arlo.db                     # LIVE database
│   └── venv/                       # Python virtualenv
├── viewer/                         # RUNNING Node.js frontend (arlo-viewer.service)
├── recordings/                     # LIVE video storage (NOT in repo)
├── logs/arlo-service.log           # Backend log
└── .env                            # Viewer secrets (AUTH_PASSWORD, ...)

/etc/hostapd/hostapd.conf           # Camera AP (contains the WiFi PSK)
/etc/arlo/dnsmasq.conf              # Camera DHCP (arlo-dhcp.service, DHCP only, port=0)
```

`ref/` is gitignored: local-only handoff notes and patches from the working
Orange Pi deployment. Useful context, never a build input.

### What is NOT in the Repository
- `config.yaml` with real camera serials, ntfy topics, passwords
- `arlo.db` database
- `arlo-recordings/` video files
- `node_modules/`
- Python `venv/`

### Development Workflow
1. Make changes in the repo, commit and push to the fork
2. On the host: `scripts/update.sh` (git pull --ff-only, then `install.sh --update`: code-only redeploy, restarts arlo + arlo-viewer, never touches hostapd/DHCP)
3. Changes to WiFi/DHCP/packages or `install.sh` networking: run the full `sudo scripts/install.sh` (idempotent)
4. Never hot-fix `~/arlo/app` or `~/arlo/viewer` without copying the change back: the next update overwrites it

### Fresh Install (New Machine)
1. Clone the repo
2. `sudo scripts/install.sh` - packages, AP, DHCP, services, health checks (no reboot)
3. `sudo arlo-pair` and press the camera's sync button
4. Add camera names under `CameraAliases` in `~/arlo/app/config.yaml`

## Directory Structure

```
arlo-open-base-station/
├── src/
│   ├── arlo-cam-api/          # Python backend (Flask + ArloSocket)
│   │   ├── server.py          # Main server entry point
│   │   ├── arlo/              # Camera protocol handlers
│   │   ├── api/               # Flask REST API endpoints
│   │   └── helpers/           # GStreamer streaming helpers
│   └── arlo-viewer/           # Node.js web frontend
│       ├── server.js          # Express server
│       └── public/            # Web interface (HTML/JS/CSS)
├── config/
│   ├── install.conf.example   # Installation configuration template
│   ├── config.yaml.example    # Main configuration template
│   └── dnsmasq.conf.example   # DHCP server configuration
├── systemd/
│   ├── arlo.service           # Main arlo-cam-api service
│   ├── arlo-viewer.service    # Web viewer service
│   ├── security-bore-tunnel.service  # Bore tunnel for viewer (optional)
│   └── ntfy-bore-tunnel.service      # Bore tunnel for ntfy (optional)
├── scripts/
│   ├── install.sh             # One-shot, idempotent installer (--update = code only)
│   ├── update.sh              # git pull + install.sh --update
│   ├── arlo-pair              # WPS pairing helper (-> /usr/local/bin)
│   └── arlo-status            # Health overview (-> /usr/local/bin)
└── docs/                      # Additional documentation
```

## Installation

```bash
cp config/install.conf.example config/install.conf   # optional, defaults work
sudo scripts/install.sh
sudo arlo-pair
```

The installer must never touch the firewall, the system dnsmasq (`/etc/dnsmasq.conf`,
`/etc/dnsmasq.d`) or port 53 (hosts commonly run Docker/Pi-hole/Tailscale). See docs/INSTALLATION.md.

### Installer invariants

Hold these when editing `scripts/install.sh`:

- **Never touch the firewall, `/etc/dnsmasq.conf`, `/etc/dnsmasq.d` or port 53.**
  Camera DHCP is a private dnsmasq instance (`arlo-dhcp.service`, `port=0`,
  `/etc/arlo/dnsmasq.conf`) precisely so a Pi-hole or Docker on the same host
  keeps working.
- **Re-running must be safe.** Existing secrets are preserved, not regenerated:
  changing the SSID or PSK forces every camera to be re-paired, so they are only
  written when explicitly set.
- **`arlo-dhcp.service` is the marker for `--update`.** Its absence means the
  host predates this installer and needs one full run first.
- The script runs under `set -euo pipefail`. Watch for SIGPIPE from
  `... | head`, bare `[ x ] && y` as the last statement of a function, and
  heredoc delimiters colliding with nested heredocs.
- `--update` touches code and units only. It must never restart hostapd or DHCP,
  and it must not write the optional bore units.

## Verification

There is no test suite. Nothing here can be exercised for real off a Linux host
with a spare AP-capable radio and a camera, so verify what can be verified:

```bash
# Python syntax (use the host venv; any python3 works on a dev box)
find src/arlo-cam-api -name '*.py' -print0 | xargs -0 python3 -m py_compile
node --check src/arlo-viewer/server.js
bash -n scripts/install.sh scripts/update.sh scripts/arlo-pair scripts/arlo-status
```

Installer changes get a container dry run. It exercises packages, the venv, npm,
GStreamer element resolution and `dnsmasq --test`, and with `systemctl` stubbed
it prints the service calls instead of making them:

```bash
docker run --rm -v "$PWD":/src:ro ubuntu:22.04 bash -c '
  apt-get update -qq
  apt-get install -y -qq --no-install-recommends sudo rsync ca-certificates
  useradd -m pi && echo "pi ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/pi
  printf "#!/bin/sh\necho \"systemctl \$*\"\nexit 0\n" > /usr/local/bin/systemctl
  chmod +x /usr/local/bin/systemctl
  cp -r /src /home/pi/repo && chown -R pi /home/pi/repo
  su pi -c "sudo bash /home/pi/repo/scripts/install.sh -y"'
```

Run it as a non-root user via `sudo` (as above). Running the installer directly
as root leaves `SUDO_USER=root` and it refuses, by design.

Worth re-checking after installer edits: a second run preserves the SSID, PSK
and `.env`; `/etc/dnsmasq.d` is never created; a bad SSID is rejected; and a
run with no TTY fails with a message instead of hanging on `read`.

## How a Camera Session Works

This is the part that needs several files to see, so it is written out here.

1. **Framing** (`arlo/socket.py`). Every frame is `L:<len> <json>`: the byte
   length, a space, then the JSON body. `ArloSocket.read()` parses the length,
   keeps calling `recv` until it has that many bytes, and returns a `Message`.
2. **One thread per connection** (`ConnectionThread` in `server.py`). A camera
   opens TCP 4000, sends a message, and the thread loops until the peer closes.
3. **Every message is acked** with a `RESPONSE` carrying the same `ID`. A camera
   that does not get its ack retries and eventually gives up on the base station.
4. **Registration is the only moment configuration reaches the camera.** On
   `registration` the server persists a `Camera` row and replies with a register
   set (`REGISTER_SET_INITIAL`, or `REGISTER_SET_INITIAL_ULTRA` for the VMC5040).
   Arming, motion zones, the WiFi country code and the video config all ride
   along here. Editing a register set does nothing until the camera re-registers,
   which it does on its own every few hours; a ~2 s battery pull forces it.
5. **Motion** (`pirMotionAlert`): the ack is sent *immediately*, before anything
   slow happens, then `motion_recorder.monitor_and_record` runs on its own
   thread. It waits for the camera's RTSP server, records a fixed-length clip
   with GStreamer, writes `arlo-<stamp>.mkv` plus a paired `gst-<stamp>.log`,
   makes a thumbnail with ffmpeg, and fires the webhook / ntfy notification.
6. **`arlo.db` (sqlite) is the shared state** between the socket server, the
   Flask API and the viewer. There is no in-memory camera registry: a `Camera`
   is loaded from the DB per request (`Camera.from_db_serial` / `from_db_ip`).
   `serialnumber`, `ip`, `friendlyname` and `hostname` all carry UNIQUE indexes.
7. **The viewer never talks to a camera.** It reads the recordings directory and
   proxies camera calls to the Flask API on :5000.

## Landmines

Things that cost real time to rediscover:

- **Deepcopy register sets before mutating them.** `Message(TEMPLATE)` does not
  copy the nested dicts, so writing into one permanently mutates the
  module-level template for every camera that registers afterwards.
- **The camera only honours keys under `SetValues`.** A top-level copy of the
  same key is silently ignored, which looks exactly like a camera that refuses
  the setting.
- **ffmpeg cannot open the Ultra's RTSP stream at all** (not a tuning problem).
  Recording and live streaming are GStreamer; ffmpeg is only used to cut
  thumbnails out of finished files.
- **The camera serves one RTSP session at a time.** A second recording started
  while one is live dies at the SDP. `motion_recorder` guards per serial.
- **A TCP connect to :554 always succeeds** whether or not the camera is
  streaming, so it is worthless as a readiness probe. Wait for actual data.
- **Friendly names must be unique**, and two unregistered cameras collide on the
  placeholder `'UNKNOWN'` IP because of `idx_camera_ip`.
- **Light/spotlight keys are policy, not ad-hoc edits.** `SpotlightEnabled`
  drives `apply_light_policy()` in `arlo/messages.py`, which only writes keys
  already present in the chosen template - that is what keeps non-Ultra
  register sets untouched.
- **`RecordingBasePath` needs its trailing slash** - it is concatenated, not joined.
- Known issues that are deliberately *not* fixed are listed in docs/ULTRA-FIXES.md.
  Check there before chasing one.

## Key Components

### arlo-cam-api (Python)
The core backend that handles:
- Camera registration and authentication (TCP port 4000)
- Motion detection alerts
- RTSP video recording (port 554)
- Push notifications via ntfy
- REST API for status and control (port 5000)

**Important Files:**
- `server.py` - Main entry point, starts Flask and ArloSocket
- `arlo/messages.py` - Register sets sent to cameras (`REGISTER_SET_INITIAL_ULTRA` for VMC5040)
- `helpers/motion_recorder.py` - GStreamer motion recording (ffmpeg can't open the Ultra's RTSP)
- `helpers/connectivity_checker.py` - Online status via `iw station dump` / ARP
- `api/api.py` - REST API endpoints (no `/api` prefix)

### arlo-viewer (Node.js)
Web interface for:
- Viewing recorded videos
- Camera status dashboard
- Live streaming (HLS via GStreamer)
- Recording management (view, delete)

**Important Files:**
- `server.js` - Express server with auth, API proxy, cleanup
- `public/index.html` - Recording gallery with LIVE button
- `public/status.html` - Camera status dashboard
- `public/stream.html` - Live stream viewer

## Network Architecture

```
Internet/LAN (ethernet)
       │
   arlo-base (your local machine)
       │
   WiFi AP (hostapd on this host, or external AP)
       │
   ┌───┴───┐
Camera1  Camera2
(.1xx)   (.1xx)   # AP_SUBNET, default 172.14.1.0/24
```

**Ports:**
- 4000/TCP - Camera control protocol (ArloSocket)
- 5000/TCP - REST API (Flask)
- 3003/TCP - Web viewer (Node.js)
- 554/TCP - RTSP streaming
- 67/UDP - DHCP (arlo-dhcp.service, private dnsmasq)

## Environment Contract

The units and the code agree on these; changing one side means changing both.

| Variable | Set by | Read by | Purpose |
|---|---|---|---|
| `ARLO_LOG_FILE` | `arlo.service` | `helpers/safe_print.py` | Backend log path (default `/tmp/arlo-service.log`) |
| `ARLO_AP_INTERFACE` | `arlo.service`, `arlo-pair`, `arlo-status` | `helpers/connectivity_checker.py` | Radio to ask for associated stations |
| `RECORDINGS_DIR` | `.env` | `arlo-viewer/server.js` | Gallery + cleanup root |
| `ARLO_CONFIG` | `.env` | `arlo-viewer/server.js` | Path to the backend `config.yaml` (aliases) |
| `RETENTION_DAYS` | `.env` | `arlo-viewer/server.js` | Cleanup age for clips, thumbnails and `gst-*.log` |
| `AUTH_PASSWORD`, `AUTH_SECRET` | `.env` | `arlo-viewer/server.js` | Viewer login and cookie signing |

`WorkingDirectory` in `arlo.service` must be the app directory: `config.yaml`
and `arlo.db` are opened by relative path, and `motion_recorder` reads its
config at import time.

## Configuration

Runtime configuration is in `~/arlo/app/config.yaml` (template: `config/config.yaml.example`):

```yaml
# Recording settings
RecordOnMotionAlert: true
RecordingBasePath: "/home/user/arlo/recordings/"   # trailing slash required
MotionClipSeconds: 10
MotionRtspPort: 554   # 555 = 4K HEVC on Ultra
MotionRecordingTimeout: 120

# false = the Ultra's spotlight never lights (night video becomes IR B/W)
SpotlightEnabled: false

# Push notifications (ntfy)
NtfyEnabled: true
NtfyUrl: "https://ntfy.sh"
NtfyTopic: "your-arlo-alerts"

# Camera aliases
CameraAliases:
  SERIAL1: "Front Door"
  SERIAL2: "Back Yard"
```

### Logs
```bash
# Main arlo service
tail -f ~/arlo/logs/arlo-service.log

# Viewer service
journalctl -u arlo-viewer -f

# DHCP leases
cat /var/lib/arlo-dhcp/dnsmasq.leases
```

## Common Tasks

### Check Camera Status
```bash
# View connected cameras
curl http://localhost:5000/cameras/status
arlo-status

# Check DHCP leases
cat /var/lib/arlo-dhcp/dnsmasq.leases

# Check WiFi clients
iw dev YOUR_INTERFACE station dump
```

### Manual Recording
```bash
# Start recording from camera
curl -X POST http://localhost:5000/camera/SERIAL/record

# Arm / disarm (camera must be awake)
curl -X POST http://localhost:5000/camera/SERIAL/arm
curl -X POST http://localhost:5000/camera/SERIAL/disarm
```

### Troubleshooting
```bash
# Check if services are running
systemctl status arlo.service
systemctl status arlo-viewer.service

# Check ports
ss -tlnp | grep -E '4000|5000|3003'

# Check AP / DHCP
journalctl -u hostapd -u arlo-dhcp -n 50
```

## GStreamer Streaming

Everything video is GStreamer: ffmpeg's hardcoded 10-second RTCP interval is
too slow for the cameras' 5-second requirement, and it cannot open the Ultra's
stream at all. Full reasoning in docs/ULTRA-FIXES.md.

- `src/arlo-cam-api/helpers/motion_recorder.py` - motion clips
- `src/arlo-cam-api/helpers/stream_manager.py`, `helpers/gst_hls_stream.py` - live HLS

## Hardware Requirements

Any Linux host plus an AP-capable 2.4 GHz radio. The radio is the part that
matters: consumer USB adapters (RTL8812AU) drop sleeping cameras. See
docs/INSTALLATION.md and docs/DEPENDENCIES.md for tested hardware.

## Security Notes

- All recordings stored locally (no cloud)
- Web viewer uses cookie-based authentication
- Push notifications via self-hosted ntfy (optional)
- No internet required for core functionality
