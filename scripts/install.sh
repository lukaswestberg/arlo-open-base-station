#!/usr/bin/env bash
# Arlo Open Base Station - one-shot installer.
#
#   cp config/install.conf.example config/install.conf   # optional, defaults work
#   sudo scripts/install.sh [--yes]
#   sudo scripts/install.sh --update     # code-only redeploy (see scripts/update.sh)
#
# Safe to re-run: code is redeployed, while config.yaml, arlo.db, .env and the
# WiFi passphrase are kept. --update skips packages and all WiFi/DHCP setup,
# takes paths from the live units, and restarts only arlo and arlo-viewer,
# so cameras stay connected. It deliberately does NOT touch the firewall,
# /etc/dnsmasq.conf or port 53, so it can share a host with Docker, Pi-hole,
# Tailscale, etc.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
CONFIG_FILE="$PROJECT_DIR/config/install.conf"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
die()       { log_error "$1"; exit 1; }
# Alphanumeric only: some camera supplicants mishandle symbols in the PSK.
gen_secret() { python3 -c "import secrets,string; a=string.ascii_letters+string.digits; print(''.join(secrets.choice(a) for _ in range($1)))"; }

ASSUME_YES=0
UPDATE=0
for arg in "$@"; do
    case "$arg" in
        -y|--yes) ASSUME_YES=1 ;;
        --update) UPDATE=1 ;;
        *) die "Unknown option: $arg (use --yes and/or --update)" ;;
    esac
done

[ "$EUID" -eq 0 ] || die "Please run as root: sudo $0"

# ===== Load configuration =====
if [ -f "$CONFIG_FILE" ]; then
    log_info "Loading $CONFIG_FILE"
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
else
    log_warn "No config/install.conf, using defaults from install.conf.example"
    # shellcheck disable=SC1091
    source "$PROJECT_DIR/config/install.conf.example"
fi

# --update deploys into whatever is live, whatever install.conf says.
if [ "$UPDATE" -eq 1 ]; then
    UNIT=/etc/systemd/system/arlo.service
    [ -f "$UNIT" ] || die "No existing install (no $UNIT). Run without --update first."
    # Only the full installer writes arlo-dhcp.service; without it this is an
    # older or hand-built setup that needs one full run to migrate.
    [ -f /etc/systemd/system/arlo-dhcp.service ] \
        || die "This host predates the current installer. Run the full installer once: sudo $0"
    live_app="$(sed -n 's/^WorkingDirectory=//p' "$UNIT" | sed 's|/$||')"
    [ "$(basename "$live_app")" = app ] \
        || die "arlo.service runs from $live_app, not a <BASE_DIR>/app layout. Run the full installer once."
    BASE_DIR="$(dirname "$live_app")"
    live_user="$(sed -n 's/^User=//p' "$UNIT")"
    [ -n "$live_user" ] && ARLO_USER="$live_user"
    # The AP config is the authority on which radio hosts the cameras.
    live_iface="$(sed -n 's/^interface=//p' /etc/hostapd/hostapd.conf 2>/dev/null | head -1 || true)"
    [ -n "$live_iface" ] || live_iface="$(sed -n 's/^Environment=ARLO_AP_INTERFACE=//p' "$UNIT")"
    [ -n "$live_iface" ] || die "Cannot determine the live WiFi interface. Run the full installer."
    WIFI_INTERFACE="$live_iface"
    # Keep the node the live viewer already uses (sudo's PATH may differ).
    live_node="$(sed -n 's/^ExecStart=\([^ ]*\) server.js$/\1/p' /etc/systemd/system/arlo-viewer.service 2>/dev/null || true)"
    [ -n "$live_node" ] && [ -x "$live_node" ] && NODE_BIN="$live_node"
    live_ip="$(sed -n 's|.* addr replace \([0-9.]*\)/24 .*|\1|p' \
        /etc/systemd/system/hostapd.service.d/10-arlo*.conf 2>/dev/null | head -1 || true)"
    [ -n "$live_ip" ] && AP_SUBNET="${live_ip%.*}"
fi

ARLO_USER="${ARLO_USER:-${SUDO_USER:-}}"
[ -n "$ARLO_USER" ] && [ "$ARLO_USER" != "root" ] \
    || die "Set ARLO_USER in config/install.conf (or run via sudo from your login user)"
id "$ARLO_USER" >/dev/null 2>&1 || die "User $ARLO_USER does not exist"
ARLO_GROUP="$(id -gn "$ARLO_USER")"
ARLO_HOME="$(getent passwd "$ARLO_USER" | cut -d: -f6)"

HOSTAPD_CONF="/etc/hostapd/hostapd.conf"
OLD_PSK=""; OLD_SSID=""
if [ -f "$HOSTAPD_CONF" ]; then
    OLD_PSK="$(sed -n 's/^wpa_passphrase=//p' "$HOSTAPD_CONF")"
    OLD_SSID="$(sed -n 's/^ssid=//p' "$HOSTAPD_CONF")"
fi

BASE_DIR="${BASE_DIR:-$ARLO_HOME/arlo}"
WIFI_INTERFACE="${WIFI_INTERFACE:-wlan0}"
# Blank SSID/passphrase keep whatever the cameras are already paired to.
WIFI_SSID="${WIFI_SSID:-${OLD_SSID:-ARLO_VMB}}"
WIFI_PASSWORD="${WIFI_PASSWORD:-${OLD_PSK:-}}"
WIFI_COUNTRY="${WIFI_COUNTRY:-US}"
WIFI_CHANNEL="${WIFI_CHANNEL:-6}"
AP_SUBNET="${AP_SUBNET:-172.14.1}"
AP_IP="$AP_SUBNET.1"
RETENTION_DAYS="${RETENTION_DAYS:-7}"
MOTION_CLIP_SECONDS="${MOTION_CLIP_SECONDS:-10}"
NTFY_ENABLED="${NTFY_ENABLED:-false}"

APP_DIR="$BASE_DIR/app"
VIEWER_DIR="$BASE_DIR/viewer"
REC_DIR="$BASE_DIR/recordings"
LOG_DIR="$BASE_DIR/logs"
ENV_FILE="$BASE_DIR/.env"
DHCP_CONF="/etc/arlo/dnsmasq.conf"

if [ "$UPDATE" -eq 0 ]; then
# ===== Preflight =====
[ -d "/sys/class/net/$WIFI_INTERFACE" ] \
    || die "WiFi interface '$WIFI_INTERFACE' not found. Available: $(ls /sys/class/net | tr '\n' ' ')"

# Never take over the link we are managed through.
if ip route show default 2>/dev/null | grep -qw "dev $WIFI_INTERFACE"; then
    die "$WIFI_INTERFACE carries the default route. Converting it to an AP would cut this machine off. Use ethernet for uplink."
fi
# sudo strips SSH_CONNECTION, so look at live sshd sockets instead.
for wifi_ip in $(ip -o -4 addr show dev "$WIFI_INTERFACE" 2>/dev/null | awk '{print $4}' | cut -d/ -f1); do
    [ "$wifi_ip" = "$AP_IP" ] && continue
    if ss -Htn state established '( sport = :22 )' 2>/dev/null | awk '{print $3}' | grep -q "^$wifi_ip:"; then
        die "An SSH session arrives over $WIFI_INTERFACE ($wifi_ip). Reconnect over ethernet first."
    fi
done

# Values land in sed replacements, YAML and systemd EnvironmentFile.
case "$BASE_DIR$WIFI_SSID" in *[\|\&\"\\\']*) die "BASE_DIR and WIFI_SSID must not contain | & \" \\ or '" ;; esac
[ ${#WIFI_SSID} -le 32 ] || die "WIFI_SSID must be at most 32 characters"
case "${WIFI_PASSWORD}${VIEWER_PASSWORD:-}" in *[!A-Za-z0-9._@%+=:,-]*) die "WIFI_PASSWORD/VIEWER_PASSWORD: use letters, digits and . _ @ % + = : , - only" ;; esac
if [ -n "$WIFI_PASSWORD" ] && { [ ${#WIFI_PASSWORD} -lt 8 ] || [ ${#WIFI_PASSWORD} -gt 63 ]; }; then
    die "WIFI_PASSWORD must be 8-63 characters"
fi

# Existing deployment somewhere else? A fresh BASE_DIR means a fresh arlo.db,
# config.yaml and viewer password.
if [ -f /etc/systemd/system/arlo.service ]; then
    old_wd="$(sed -n 's/^WorkingDirectory=//p' /etc/systemd/system/arlo.service | sed 's|/$||')"
    if [ -n "$old_wd" ] && [ "$old_wd" != "$APP_DIR" ]; then
        log_warn "arlo.service currently runs from $old_wd, not $APP_DIR."
        log_warn "Set BASE_DIR to the existing install to keep its database and config."
    fi
fi

PY_MINOR="$(python3 -c 'import sys; print(sys.version_info[1])' 2>/dev/null || echo 0)"
if [ "$PY_MINOR" -ge 11 ]; then
    log_warn "Python 3.$PY_MINOR detected. The pinned Flask 1.x stack is tested on 3.10;"
    log_warn "if pip fails below, that is the cause."
fi

for port in 4000 5000 3003; do
    owner="$(ss -Hltnp "sport = :$port" 2>/dev/null | grep -o 'users:(("[^"]*' | cut -d'"' -f2 | head -1 || true)"
    case "$owner" in
        ""|python3|python|node) ;;
        *) log_warn "Port $port is already used by '$owner'; arlo will fail to bind it." ;;
    esac
done

echo ""
log_info "Install plan:"
log_info "  Run as user:      $ARLO_USER"
log_info "  Base directory:   $BASE_DIR"
log_info "  Camera AP:        $WIFI_INTERFACE  SSID=$WIFI_SSID  ch=$WIFI_CHANNEL  country=$WIFI_COUNTRY"
if { [ -n "$OLD_SSID" ] && [ "$OLD_SSID" != "$WIFI_SSID" ]; } \
        || { [ -n "$OLD_PSK" ] && [ "$OLD_PSK" != "$WIFI_PASSWORD" ]; }; then
    log_warn "  SSID/passphrase differ from the running AP: every paired camera must be RE-PAIRED."
fi
log_info "  Camera subnet:    $AP_SUBNET.0/24 (base station $AP_IP)"
log_info "  Firewall / :53:   untouched (private DHCP-only dnsmasq, arlo-dhcp.service)"
echo ""
if [ "$ASSUME_YES" -ne 1 ]; then
    read -r -p "Continue? [y/N] " reply || die "No terminal to confirm on; re-run with --yes"
    [[ "$reply" =~ ^[Yy]$ ]] || { log_info "Cancelled"; exit 0; }
fi
fi  # full install only: preflight

[ "$UPDATE" -eq 1 ] && log_info "Updating code in $BASE_DIR (WiFi/DHCP untouched)"

if [ "$UPDATE" -eq 0 ]; then
# ===== Packages =====
log_info "Installing packages..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq || log_warn "apt-get update reported errors (often an unrelated third-party repo); continuing"

# DHCP comes from our own dnsmasq instance (arlo-dhcp.service) using only
# dnsmasq-base: no system dnsmasq.service, nothing added to /etc/dnsmasq.d,
# so an existing dnsmasq or Pi-hole is never affected. hostapd auto-starts on
# install on some distros; hold it until its config exists.
dpkg -s hostapd >/dev/null 2>&1 || systemctl mask hostapd >/dev/null 2>&1 || true

apt-get install -y -qq --no-install-recommends \
    hostapd dnsmasq-base iw rfkill iproute2 psmisc procps rsync openssl curl logrotate \
    python3 python3-venv python3-dev python3-gst-1.0 build-essential \
    ffmpeg nodejs npm \
    gstreamer1.0-tools gstreamer1.0-plugins-base \
    gstreamer1.0-plugins-good gstreamer1.0-plugins-bad

IP_BIN="$(command -v ip)"
DNSMASQ_BIN="$(command -v dnsmasq)" || die "dnsmasq binary not found after install"
fi  # full install only: packages

NODE_BIN="${NODE_BIN:-$(command -v node || command -v nodejs || true)}"
[ -n "$NODE_BIN" ] || die "node not found (install nodejs, or run the full installer)"
log_info "Using node $("$NODE_BIN" --version) at $NODE_BIN"

# ===== Directories and code =====
log_info "Deploying code to $BASE_DIR"
install -d -o "$ARLO_USER" -g "$ARLO_GROUP" "$BASE_DIR" "$APP_DIR" "$VIEWER_DIR" "$REC_DIR" "$LOG_DIR"

rsync -a --delete \
    --exclude venv/ --exclude config.yaml --exclude "arlo.db*" --exclude __pycache__/ \
    "$PROJECT_DIR/src/arlo-cam-api/" "$APP_DIR/"
rsync -a --delete --exclude node_modules/ \
    "$PROJECT_DIR/src/arlo-viewer/" "$VIEWER_DIR/"
chown -R "$ARLO_USER:$ARLO_GROUP" "$APP_DIR" "$VIEWER_DIR"

as_user() { sudo -u "$ARLO_USER" -H "$@"; }

log_info "Python virtualenv..."
[ -x "$APP_DIR/venv/bin/python3" ] || as_user python3 -m venv "$APP_DIR/venv"
as_user "$APP_DIR/venv/bin/pip" install -q --upgrade pip wheel
as_user "$APP_DIR/venv/bin/pip" install -q -r "$APP_DIR/requirements.txt" \
    || die "pip install failed (see above). On Python >= 3.11 the Flask 1.x pins may not build."

log_info "Node dependencies..."
(cd "$VIEWER_DIR" && as_user env PATH="$(dirname "$NODE_BIN"):$PATH" npm install --production --no-audit --no-fund --loglevel=error)

# ===== config.yaml (created once, then yours to edit) =====
if [ ! -f "$APP_DIR/config.yaml" ]; then
    log_info "Generating $APP_DIR/config.yaml"
    cat > "$APP_DIR/config.yaml" <<EOF
WifiCountryCode: "$WIFI_COUNTRY"
MotionRecordingTimeout: 120
AudioRecordingTimeout: 10
RecordOnMotionAlert: true
RecordOnAudioAlert: false
# Trailing slash required: paths are built by string concatenation.
RecordingBasePath: "$REC_DIR/"

# GStreamer motion recorder. Port 554 = H.264 1080p, 555 = 4K HEVC (Ultra).
MotionClipSeconds: $MOTION_CLIP_SECONDS
MotionRtspPort: 554
MotionRtspLatencyMs: 200

# Leave blank to disable a webhook.
MotionRecordingWebHookUrl: ""
AudioRecordingWebHookUrl: ""
UserRecordingWebHookUrl: ""
StatusUpdateWebHookUrl: ""
RegistrationWebHookUrl: ""
NotifyOnMotionAlert: true
NotifyOnAudioAlert: false
NotifyOnButtonPressAlert: true

NtfyEnabled: $NTFY_ENABLED
NtfyUrl: "${NTFY_URL:-https://ntfy.sh}"
NtfyTopic: "${NTFY_TOPIC:-your-arlo-alerts}"
NtfyPriority: "${NTFY_PRIORITY:-high}"
NtfyIncludeThumbnail: true
NtfyThumbnailBaseUrl: "${NTFY_THUMBNAIL_URL:-}"
NtfyClickUrl: "${NTFY_CLICK_URL:-}"

# Serial -> friendly name. Names must be unique. Serials appear in
# 'arlo-pair' output and the log once a camera registers.
CameraAliases: {}

BatteryWarningEnabled: true
BatteryWarningLow: 25
BatteryWarningCritical: 10

# false = the Ultra's white spotlight never lights; night video is IR
# black-and-white instead. Applied when a camera next registers.
SpotlightEnabled: false
EOF
    chown "$ARLO_USER:$ARLO_GROUP" "$APP_DIR/config.yaml"
else
    log_info "Keeping existing $APP_DIR/config.yaml"
fi

# ===== Viewer .env (created once) =====
if [ ! -f "$ENV_FILE" ]; then
    VIEWER_PASSWORD="${VIEWER_PASSWORD:-$(gen_secret 16)}"
    NEW_VIEWER_PASSWORD="$VIEWER_PASSWORD"
    cat > "$ENV_FILE" <<EOF
RECORDINGS_DIR=$REC_DIR
ARLO_CONFIG=$APP_DIR/config.yaml
RETENTION_DAYS=$RETENTION_DAYS
AUTH_PASSWORD=$VIEWER_PASSWORD
AUTH_SECRET=$(openssl rand -hex 32)
EOF
    chown "$ARLO_USER:$ARLO_GROUP" "$ENV_FILE"
    chmod 600 "$ENV_FILE"
else
    log_info "Keeping existing $ENV_FILE (viewer password unchanged)"
fi

if [ "$UPDATE" -eq 0 ]; then
# ===== Release the radio from other network managers =====
rfkill unblock wifi 2>/dev/null || true

if systemctl is-active --quiet NetworkManager; then
    log_info "Marking $WIFI_INTERFACE unmanaged in NetworkManager (no NM restart)"
    install -d /etc/NetworkManager/conf.d
    cat > /etc/NetworkManager/conf.d/99-arlo-unmanaged.conf <<EOF
[keyfile]
unmanaged-devices+=interface-name:$WIFI_INTERFACE
EOF
    nmcli device set "$WIFI_INTERFACE" managed no 2>/dev/null || true
fi

if systemctl is-active --quiet dhcpcd && [ -f /etc/dhcpcd.conf ] \
        && ! grep -q "^denyinterfaces $WIFI_INTERFACE" /etc/dhcpcd.conf; then
    log_info "Excluding $WIFI_INTERFACE from dhcpcd"
    echo "denyinterfaces $WIFI_INTERFACE" >> /etc/dhcpcd.conf
    # Release just this interface; restarting dhcpcd could drop the uplink.
    dhcpcd -k "$WIFI_INTERFACE" >/dev/null 2>&1 || true
fi

if systemctl is-active --quiet "wpa_supplicant@$WIFI_INTERFACE"; then
    systemctl disable --now "wpa_supplicant@$WIFI_INTERFACE" || true
fi
# A client supplicant (e.g. started by a dhcpcd hook) would keep the radio
# in station mode and hostapd would fail with "Could not configure driver mode".
pkill -f "wpa_supplicant.*-i ?$WIFI_INTERFACE( |\$)" 2>/dev/null || true

# ===== hostapd =====
WIFI_PASSWORD="${WIFI_PASSWORD:-$(gen_secret 24)}"

log_info "Writing $HOSTAPD_CONF"
install -d /etc/hostapd
# Notes: CCMP only (TKIP drops the BSS to 802.11g rates); WMM on (needed for
# power save); no PMF/SAE (Arlo cannot do WPA3); SSID broadcast (WPS needs it).
cat > "$HOSTAPD_CONF" <<EOF
interface=$WIFI_INTERFACE
driver=nl80211
ctrl_interface=/var/run/hostapd
ctrl_interface_group=0

ssid=$WIFI_SSID
country_code=$WIFI_COUNTRY
ieee80211d=1
hw_mode=g
channel=$WIFI_CHANNEL
ieee80211n=1
wmm_enabled=1

auth_algs=1
wpa=2
wpa_key_mgmt=WPA-PSK
rsn_pairwise=CCMP
ieee80211w=0
wpa_passphrase=$WIFI_PASSWORD

# WPS push-button pairing (see arlo-pair)
eap_server=1
wps_state=2
config_methods=push_button
ap_setup_locked=1
device_name=$WIFI_SSID
manufacturer=Netgear
model_name=VMB5000
model_number=VMB5000
EOF
chmod 600 "$HOSTAPD_CONF"
[ -f /etc/default/hostapd ] && \
    sed -i "s|^#\?DAEMON_CONF=.*|DAEMON_CONF=\"$HOSTAPD_CONF\"|" /etc/default/hostapd

# The AP address rides on hostapd's lifecycle rather than netplan/NM.
install -d /etc/systemd/system/hostapd.service.d
cat > /etc/systemd/system/hostapd.service.d/10-arlo.conf <<EOF
[Service]
ExecStartPost=$IP_BIN addr replace $AP_IP/24 dev $WIFI_INTERFACE
Restart=on-failure
RestartSec=5
EOF

# ===== Camera DHCP: private dnsmasq instance, DHCP only =====
# Own config file and unit, so a system dnsmasq / Pi-hole is never affected
# and nothing ever listens on :53 for us.
log_info "Writing $DHCP_CONF and arlo-dhcp.service"
install -d /etc/arlo
cat > "$DHCP_CONF" <<EOF
# Arlo camera DHCP (arlo-dhcp.service). port=0 disables DNS.
port=0
bind-interfaces
except-interface=lo
interface=$WIFI_INTERFACE
# Infinite leases: camera IPs are unique keys in arlo.db.
dhcp-range=$AP_SUBNET.100,$AP_SUBNET.199,255.255.255.0,infinite
# Cameras find the base station by connecting to TCP 4000 on their gateway.
dhcp-option=3,$AP_IP
dhcp-option=6
dhcp-authoritative
dhcp-leasefile=/var/lib/arlo-dhcp/dnsmasq.leases
log-dhcp
EOF

cat > /etc/systemd/system/arlo-dhcp.service <<EOF
[Unit]
Description=Arlo camera DHCP (dnsmasq, DHCP only)
# Follows the AP: started whenever hostapd starts, stopped when it stops.
BindsTo=hostapd.service
After=hostapd.service

[Service]
Type=simple
StateDirectory=arlo-dhcp
ExecStart=$DNSMASQ_BIN --keep-in-foreground --conf-file=$DHCP_CONF --pid-file=/run/arlo-dhcp.pid
Restart=on-failure
RestartSec=5

[Install]
WantedBy=hostapd.service
EOF

# Migrate from the hand-built setup, which put arlo.conf into the system
# dnsmasq's conf-dir. That dnsmasq existed only for the cameras.
if [ -f /etc/dnsmasq.d/arlo.conf ]; then
    log_warn "Removing legacy /etc/dnsmasq.d/arlo.conf; camera DHCP moves to arlo-dhcp.service"
    rm -f /etc/dnsmasq.d/arlo.conf /etc/systemd/system/dnsmasq.service.d/10-arlo-order.conf
    # Only stop the system dnsmasq if it has nothing else to do.
    if ! ls /etc/dnsmasq.d/*.conf >/dev/null 2>&1 \
            && ! grep -qv '^[[:space:]]*\(#\|$\)' /etc/dnsmasq.conf 2>/dev/null; then
        systemctl disable --now dnsmasq >/dev/null 2>&1 || true
    else
        log_warn "System dnsmasq has other config; left running. Check it no longer serves $WIFI_INTERFACE."
        systemctl restart dnsmasq >/dev/null 2>&1 || true
    fi
fi

# Drop-in name used by earlier hand-built installs; superseded by 10-arlo.conf.
rm -f /etc/systemd/system/hostapd.service.d/10-arlo-addr.conf
fi  # full install only: WiFi AP and DHCP

# ===== arlo services =====
log_info "Installing systemd units"
cat > /etc/systemd/system/arlo.service <<EOF
[Unit]
Description=Arlo Control Service (arlo-cam-api)
After=network-online.target hostapd.service
Wants=network-online.target hostapd.service

[Service]
Type=simple
User=$ARLO_USER
Group=$ARLO_GROUP
WorkingDirectory=$APP_DIR
Environment=ARLO_LOG_FILE=$LOG_DIR/arlo-service.log
Environment=ARLO_AP_INTERFACE=$WIFI_INTERFACE
Environment=PYTHONUNBUFFERED=1
ExecStart=$APP_DIR/venv/bin/python3 $APP_DIR/server.py
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/arlo-viewer.service <<EOF
[Unit]
Description=Arlo Recording Viewer
After=network.target arlo.service

[Service]
Type=simple
User=$ARLO_USER
Group=$ARLO_GROUP
WorkingDirectory=$VIEWER_DIR
EnvironmentFile=$ENV_FILE
ExecStartPre=/bin/sh -c "/usr/bin/fuser -k 3003/tcp || true"
ExecStart=$NODE_BIN server.js
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

# Remove the upstream-installer unit location so it cannot shadow ours.
[ -f /lib/systemd/system/arlo.service ] && rm -f /lib/systemd/system/arlo.service

# The backend log is no longer in /tmp, so rotate it.
cat > /etc/logrotate.d/arlo <<EOF
$LOG_DIR/arlo-service.log {
    weekly
    rotate 4
    compress
    missingok
    notifempty
    copytruncate
    su $ARLO_USER $ARLO_GROUP
}
EOF

# ===== Helper commands =====
for helper in arlo-pair arlo-status; do
    sed -e "s|@WIFI_INTERFACE@|$WIFI_INTERFACE|g" \
        -e "s|@LOG_FILE@|$LOG_DIR/arlo-service.log|g" \
        -e "s|@APP_DIR@|$APP_DIR|g" \
        "$SCRIPT_DIR/$helper" > "/usr/local/bin/$helper"
    chmod 755 "/usr/local/bin/$helper"
done

# ===== Optional bore tunnels (full install only) =====
if [ "$UPDATE" -eq 0 ] && [ -n "${BORE_REMOTE_SERVER:-}" ]; then
    log_info "Installing bore tunnel units"
    [ -x /usr/local/bin/bore ] || log_warn "/usr/local/bin/bore not found; install it before starting the tunnels"
    for spec in "security-bore-tunnel:3003:${BORE_VIEWER_PORT:-8084}:viewer" \
                "ntfy-bore-tunnel:8085:${BORE_NTFY_PORT:-8085}:ntfy"; do
        IFS=: read -r name lport rport what <<<"$spec"
        cat > "/etc/systemd/system/$name.service" <<EOF
[Unit]
Description=Bore tunnel ($what :$lport -> $BORE_REMOTE_SERVER:$rport)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$ARLO_USER
ExecStart=/usr/local/bin/bore local $lport --to $BORE_REMOTE_SERVER --port $rport
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
    done
fi

# Record what is deployed (root reading a user-owned repo needs safe.directory).
DEPLOYED="$(git -c safe.directory="$PROJECT_DIR" -C "$PROJECT_DIR" describe --always --dirty 2>/dev/null || echo unknown)"
echo "$DEPLOYED" > "$BASE_DIR/.deployed-version"

# ===== Start everything =====
log_info "Starting services"
systemctl daemon-reload
# Failures here are reported by the health checks below, with hints.
if [ "$UPDATE" -eq 0 ]; then
    systemctl unmask hostapd >/dev/null 2>&1 || true
    systemctl enable hostapd arlo-dhcp arlo arlo-viewer >/dev/null 2>&1
    systemctl restart hostapd || true
    sleep 3
    systemctl restart arlo-dhcp || true
fi
systemctl restart arlo || true
systemctl restart arlo-viewer || true
if [ "$UPDATE" -eq 0 ] && [ -n "${BORE_REMOTE_SERVER:-}" ] && [ -x /usr/local/bin/bore ]; then
    systemctl enable --now security-bore-tunnel ntfy-bore-tunnel >/dev/null 2>&1 || true
fi
sleep 5

# ===== Verify =====
FAILED=0
check() {
    if eval "$2" >/dev/null 2>&1; then
        echo -e "  ${GREEN}OK${NC}   $1"
    else
        echo -e "  ${RED}FAIL${NC} $1"; FAILED=1
    fi
}
echo ""
log_info "Health checks:"
check "hostapd running"                "systemctl is-active --quiet hostapd"
check "AP address $AP_IP on $WIFI_INTERFACE" "ip -o addr show dev $WIFI_INTERFACE | grep -qw $AP_IP"
check "camera DHCP (arlo-dhcp) running" "systemctl is-active --quiet arlo-dhcp"
check "arlo listening on :4000"        "ss -Hltn 'sport = :4000' | grep -q ."
check "API listening on :5000"         "ss -Hltn 'sport = :5000' | grep -q ."
check "viewer listening on :3003"      "ss -Hltn 'sport = :3003' | grep -q ."
# Non-fatal: the connectivity checker falls back to the ARP cache.
if ! sudo -u "$ARLO_USER" iw dev "$WIFI_INTERFACE" station dump >/dev/null 2>&1; then
    echo -e "  ${YELLOW}WARN${NC} iw station dump fails as $ARLO_USER; online status will use ARP instead"
fi

HOST_IP="$(ip route get 1.1.1.1 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p')"
echo ""
if [ "$UPDATE" -eq 1 ]; then
    log_info "===== UPDATE COMPLETE ($DEPLOYED) ====="
    [ -n "${NEW_VIEWER_PASSWORD:-}" ] && log_warn ".env was missing; new viewer login: $NEW_VIEWER_PASSWORD"
    [ "$FAILED" -ne 0 ] && log_warn "Some checks failed. Try: journalctl -u arlo -u arlo-viewer -n 50"
    exit "$FAILED"
fi
log_info "===== INSTALL COMPLETE ($DEPLOYED) ====="
echo "  Viewer:        http://${HOST_IP:-<this-host>}:3003"
if [ -n "${NEW_VIEWER_PASSWORD:-}" ]; then
    echo "  Viewer login:  $NEW_VIEWER_PASSWORD   (stored in $ENV_FILE)"
else
    echo "  Viewer login:  unchanged, see AUTH_PASSWORD in $ENV_FILE"
fi
echo "  Camera WiFi:   $WIFI_SSID  (passphrase in $HOSTAPD_CONF)"
echo "  Config:        $APP_DIR/config.yaml"
echo "  Logs:          $LOG_DIR/arlo-service.log"
echo ""
echo "  Pair a camera: sudo arlo-pair     (then press the camera's sync button)"
echo "  Status:        arlo-status"
if [ "$FAILED" -ne 0 ]; then
    echo ""
    log_warn "Some checks failed. Try: journalctl -u hostapd -u arlo-dhcp -u arlo -u arlo-viewer -n 50"
    log_warn "If hostapd says 'Could not configure driver mode': something else holds the radio"
    log_warn "(wpa_supplicant, NetworkManager) or a P2P device exists. For the latter, find"
    log_warn "the p2p-dev-$WIFI_INTERFACE wdev id with 'iw dev', then: iw wdev <id> del; systemctl restart hostapd"
    exit 1
fi
