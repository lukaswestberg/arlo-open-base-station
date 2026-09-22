# CLAUDE.md - Arlo Open Base Station

This is the development documentation for the Arlo Open Base Station project - a DIY replacement for Arlo's commercial base stations.

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

### What is NOT in the Repository
- `config.yaml` with real camera serials, ntfy topics, passwords
- `arlo.db` database
- `arlo-recordings/` video files
- `node_modules/`
- Python `venv/`

### Development Workflow
1. Make changes in the repo, then redeploy with `sudo scripts/install.sh --yes` (idempotent; keeps config.yaml, arlo.db, .env and the WiFi PSK). Hot-fixes can be made in `~/arlo/app` or `~/arlo/viewer` directly
2. Test by restarting services
3. If you hot-fixed the live copy, copy the change back to the repo
4. Commit and push to GitHub

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
│   ├── install.sh             # One-shot, idempotent installer
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

## Configuration

Runtime configuration is in `~/arlo/app/config.yaml` (template: `config/config.yaml.example`):

```yaml
# Recording settings
RecordOnMotionAlert: true
RecordingBasePath: "/home/user/arlo/recordings/"   # trailing slash required
MotionClipSeconds: 10
MotionRtspPort: 554   # 555 = 4K HEVC on Ultra
MotionRecordingTimeout: 120

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

The project uses GStreamer for live streaming because:
- FFmpeg sends RTCP at 10-second intervals (hardcoded)
- Arlo cameras require RTCP every 5 seconds
- GStreamer correctly sends RTCP at 5-second intervals

Key streaming files:
- `src/arlo-cam-api/helpers/stream_manager.py`
- `src/arlo-cam-api/helpers/gst_hls_stream.py`

## Hardware Requirements

- Linux computer (Raspberry Pi, old laptop, etc.)
- Enterprise WiFi access point with proper power save support
- Recommended: TP-Link Omada EAP225 or EAP245
- NOT recommended: Consumer USB adapters (RTL8812AU) - drops sleeping cameras
- USB Ethernet adapter (to connect to Omada AP)

## Security Notes

- All recordings stored locally (no cloud)
- Web viewer uses cookie-based authentication
- Push notifications via self-hosted ntfy (optional)
- No internet required for core functionality
