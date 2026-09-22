"""Camera connectivity detection.

Primary source is the AP's associated-station list (iw), which is
authoritative for "is this camera still on the WiFi" and costs the camera
nothing. Falls back to the kernel ARP cache for when the cameras live on an
external AP and we no longer host their BSS.

Also backfills camera.mac_address, which nothing else in the codebase writes.
"""
import os
import sqlite3
import subprocess
import threading
import time
import logging

APP_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DB_PATH = os.path.join(APP_DIR, 'arlo.db')
AP_INTERFACE = os.environ.get('ARLO_AP_INTERFACE', 'wlan0')
CHECK_INTERVAL = 300


def associated_macs():
    """MACs associated to our AP, or None if we cannot ask (no such
    interface, iw missing). An empty set is authoritative: nobody is on."""
    try:
        out = subprocess.run(['iw', 'dev', AP_INTERFACE, 'station', 'dump'],
                             capture_output=True, text=True, timeout=5)
        if out.returncode != 0:
            return None
        return {ln.split()[1].lower() for ln in out.stdout.splitlines()
                if ln.startswith('Station ')}
    except Exception:
        return None


def arp_table():
    """{ip: mac} from the kernel ARP cache."""
    table = {}
    try:
        with open('/proc/net/arp') as f:
            next(f)
            for line in f:
                parts = line.split()
                if len(parts) >= 4 and parts[3] != '00:00:00:00:00:00':
                    table[parts[0]] = parts[3].lower()
    except Exception as e:
        logging.error(f"[CONNECTIVITY] ARP read failed: {e}")
    return table


def update_camera_connectivity():
    arp = arp_table()
    assoc = associated_macs()
    try:
        with sqlite3.connect(DB_PATH) as conn:
            c = conn.cursor()
            c.execute("SELECT serialnumber, ip, mac_address, friendlyname FROM camera")
            for serial, ip, mac, name in c.fetchall():
                if not mac and ip and ip in arp:
                    mac = arp[ip]
                    c.execute("UPDATE camera SET mac_address = ? WHERE serialnumber = ?",
                              (mac, serial))
                    logging.info(f"[CONNECTIVITY] {name} ({serial}): learned MAC {mac}")

                if mac and assoc is not None:
                    online = mac in assoc
                elif mac:
                    online = mac in arp.values()
                else:
                    online = False

                c.execute("UPDATE camera SET connected = ? WHERE serialnumber = ?",
                          (1 if online else 0, serial))
                logging.info(f"[CONNECTIVITY] {name} ({serial}): "
                             f"{'Connected' if online else 'Offline'}")
            conn.commit()
    except Exception as e:
        logging.error(f"[CONNECTIVITY] Update failed: {e}")


class ConnectivityChecker(threading.Thread):
    def __init__(self):
        super().__init__()
        self.daemon = True
        self.interval = CHECK_INTERVAL

    def run(self):
        logging.info(f"[CONNECTIVITY] started (interval {self.interval}s, "
                     f"iface {AP_INTERFACE}, db {DB_PATH})")
        update_camera_connectivity()
        while True:
            time.sleep(self.interval)
            update_camera_connectivity()
