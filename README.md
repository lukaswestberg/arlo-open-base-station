# Arlo Open Base Station

A DIY replacement for Arlo's commercial base stations (VMB4000/VMB5000/VMB4540) using commodity hardware. Run your Arlo cameras without cloud subscriptions or vendor lock-in.

## Project Status: Advanced / Experimental

This is a working system, not a polished product. Installation requires configuring networking, systemd services, external tunneling, and camera re-pairing. There is an install script, but expect to troubleshoot and adapt to your specific hardware and network.

**Using an AI coding assistant (like [Claude Code](https://docs.anthropic.com/en/docs/claude-code)) is strongly recommended** to work through the installation and configuration process. The number of moving parts (Linux networking, GStreamer, DNS, firewall rules, camera protocol) makes interactive AI assistance very helpful.

### Tested Hardware

| Component | Tested Model |
|-----------|-------------|
| Camera | Arlo Pro (VMC4030), Arlo Ultra (VMC5040) |
| WiFi AP | TP-Link Omada EAP225; Orange Pi 5 Pro onboard WiFi (brcmfmac) via hostapd |
| Compute | Surface Book 3 (Ubuntu 24.04); Orange Pi 5 Pro (Ubuntu 22.04, arm64) |

Other Arlo cameras that use the same registration protocol may work but have not been tested.

### Known Limitations

- Cameras must be re-paired from Arlo cloud (factory reset required)
- No geofencing, scheduling, or other cloud-based features
- Single WiFi subnet - all cameras on one AP
- GStreamer required for live streaming (FFmpeg RTCP timing is incompatible)
- Upstream protocol library ([arlo-cam-api](https://github.com/Meatballs1/arlo-cam-api)) has no license specified - see [LICENSE](LICENSE) for details

## What This Replaces

| Commercial Product | Replacement |
|-------------------|-------------|
| Arlo Base Station VMB4000/5000 | Linux computer + WiFi AP |
| Arlo Cloud Subscription | Local storage |
| Arlo App | Web-based viewer |
| Arlo Push Notifications | Self-hosted ntfy |

## Features

- **No subscription fees** - All recordings stored locally
- **No cloud dependency** - Works entirely offline
- **Extended range** - Use enterprise WiFi hardware for better coverage
- **Push notifications** - Motion alerts via ntfy (self-hosted or ntfy.sh)
- **Web viewer** - Browse and stream recordings from any browser
- **Live streaming** - On-demand camera streaming via HLS
- **Thumbnail previews** - Motion alerts include snapshot images

## Hardware Requirements

- **Compute**: Any Linux machine (Raspberry Pi 4, old laptop, mini PC)
- **WiFi AP**: Enterprise access point recommended (TP-Link Omada EAP225)
- **Cameras**: Arlo Pro (VMC4030) and Arlo Ultra (VMC5040) tested

> **Important**: WiFi hardware choice is critical. Consumer USB adapters often drop sleeping camera connections, causing battery drain. See [docs/WIFI-HARDWARE.md](docs/WIFI-HARDWARE.md) for details.

## Getting Started

```bash
git clone <your fork> arlo-open-base-station
cd arlo-open-base-station

# Optional: all settings have working defaults
cp config/install.conf.example config/install.conf

sudo scripts/install.sh      # packages, WiFi AP, DHCP, services, health checks
sudo arlo-pair               # then hold the camera's SYNC button ~2 s

scripts/update.sh            # later: pull your fork and redeploy (cameras stay connected)
```

The installer is safe to re-run and does not touch your firewall, port 53 or
`/etc/dnsmasq.conf`. See [docs/INSTALLATION.md](docs/INSTALLATION.md) for
details and for remote access (VPS, domain, bore tunnels). For what changed
to support the Arlo Ultra, see [docs/ULTRA-FIXES.md](docs/ULTRA-FIXES.md).

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│                    arlo-base (Linux)                     │
├─────────────────────────────────────────────────────────┤
│  arlo-cam-api (Python)          arlo-viewer (Node.js)   │
│  ├─ Camera registration         ├─ Web interface        │
│  ├─ Motion detection            ├─ Recording playback   │
│  ├─ Video recording             ├─ Live streaming       │
│  └─ Push notifications          └─ Status dashboard     │
├─────────────────────────────────────────────────────────┤
│  WiFi AP (hostapd/Omada)     │  Recordings (local disk) │
└─────────────────────────────────────────────────────────┘
         │
    ┌────┴────┐
    │  Arlo   │
    │ Cameras │
    └─────────┘
```

## Documentation

- [Installation Guide](docs/INSTALLATION.md) - Complete setup instructions
- [Dependencies](docs/DEPENDENCIES.md) - Required packages and external services
- [WiFi Hardware](docs/WIFI-HARDWARE.md) - Critical hardware compatibility info
- [System Architecture](docs/ARLO-SYSTEM-V1.0.md) - Technical deep-dive
- [Arlo Ultra Fixes](docs/ULTRA-FIXES.md) - Bugs fixed while bringing up a VMC5040

## Configuration

Install-time settings live in `config/install.conf` (interface, SSID, subnet,
viewer password, retention, and so on). Runtime settings (camera names, clip
length, notifications) live in `~/arlo/app/config.yaml`.

## Credits

This project builds on the work of others:

- [Meatballs1/arlo-cam-api](https://github.com/Meatballs1/arlo-cam-api) - Original Arlo protocol reverse-engineering
- [ntfy](https://github.com/binwiederhier/ntfy) - Push notification server
- [bore](https://github.com/ekzhang/bore) - TCP tunneling for remote access

## License

MIT - See [LICENSE](LICENSE) for details, including third-party notices.
