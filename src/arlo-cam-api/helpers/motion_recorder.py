"""Motion-triggered recording for Arlo cameras, via GStreamer.

ffmpeg cannot open this camera's RTSP server at all. Every variant tested (udp,
tcp, with and without an explicit port) fails at the handshake with "Invalid
data found when processing input". GStreamer's rtspsrc negotiates it fine.
That is consistent with docs/DEPENDENCIES.md, which already required GStreamer
for live streaming, and with upstream's note that libVLC works where ffmpeg
needs workarounds.

ffmpeg is still used, but only to pull a thumbnail out of the finished local
file, which it handles without trouble.
"""
import os
import signal
import subprocess
import threading
import time

import yaml

from helpers.safe_print import s_print

_APP_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
with open(os.path.join(_APP_DIR, 'config.yaml')) as _f:
    _config = yaml.safe_load(_f)

CLIP_SECONDS = int(_config.get('MotionClipSeconds', 10))
RTSP_PORT = int(_config.get('MotionRtspPort', 554))
RTSP_LATENCY_MS = int(_config.get('MotionRtspLatencyMs', 200))

# The camera serves exactly one RTSP session. A second gst-launch started while
# a recording is live dies at the SDP with "Failed to connect", so overlapping
# motion alerts must not race each other for the stream.
_active = set()
_active_lock = threading.Lock()


def _pipeline(ip, filename):
    """gst-launch argv. Port 554 is H.264 1080p, port 555 is 4K HEVC."""
    if RTSP_PORT == 555:
        depay, parse = 'rtph265depay', 'h265parse'
    else:
        depay, parse = 'rtph264depay', 'h264parse'
    location = 'rtsp://' + ip + ':' + str(RTSP_PORT) + '/live'
    return [
        'gst-launch-1.0', '-e',
        'rtspsrc', 'location=' + location,
        'protocols=udp',
        'latency=' + str(RTSP_LATENCY_MS),
        '!', depay,
        '!', parse,
        '!', 'matroskamux',
        '!', 'filesink', 'location=' + filename,
    ]


def _make_thumbnail(filename, thumbnail_filename):
    """Local file decode, which ffmpeg is perfectly happy with."""
    for seek in (['-ss', '1'], []):
        cmd = (['ffmpeg', '-hide_banner', '-loglevel', 'error', '-y',
                '-i', filename] + seek
               + ['-frames:v', '1', '-q:v', '2', '-an', thumbnail_filename])
        try:
            subprocess.run(cmd, capture_output=True, timeout=20)
        except Exception:
            continue
        if (os.path.exists(thumbnail_filename)
                and os.path.getsize(thumbnail_filename) > 0):
            return True
    return False


def monitor_and_record(ip, rtsp_url, filename, serial_number, zones,
                       webhook_manager, friendly_name, hostname):
    """Record one motion clip, unless this camera is already recording."""
    with _active_lock:
        if serial_number in _active:
            s_print('[' + ip + '] motion while already recording, skipped '
                    '(the camera serves one RTSP session at a time)')
            return
        _active.add(serial_number)
    try:
        _record(ip, filename, serial_number, zones, webhook_manager,
                friendly_name, hostname)
    finally:
        with _active_lock:
            _active.discard(serial_number)


def _record(ip, filename, serial_number, zones, webhook_manager,
            friendly_name, hostname):
    thumbnail_filename = filename.replace('.mkv', '.jpg')
    # Pair the log with the clip (arlo-X.mkv -> gst-X.log) so the viewer's
    # retention sweep removes both together.
    stem = os.path.basename(filename)[:-len('.mkv')]
    if stem.startswith('arlo-'):
        stem = stem[len('arlo-'):]
    logfile = os.path.join(os.path.dirname(filename), 'gst-' + stem + '.log')

    cmd = _pipeline(ip, filename)
    s_print('[' + ip + '] gst recording ' + str(CLIP_SECONDS) + 's from port '
            + str(RTSP_PORT))

    log = open(logfile, 'w')
    try:
        proc = subprocess.Popen(cmd, stdout=log, stderr=log)
    except Exception as exc:
        log.close()
        s_print('[' + ip + '] could not start gst-launch: ' + str(exc))
        return

    # The camera usually ends the stream before CLIP_SECONDS is up, and -e has
    # already finalised the container by then. Poll rather than sleeping the
    # full clip length, so the next motion alert is not locked out of a stream
    # that is no longer being used.
    deadline = time.monotonic() + CLIP_SECONDS
    while time.monotonic() < deadline and proc.poll() is None:
        time.sleep(0.5)
    # -e turns SIGINT into an EOS, which finalises the matroska container.
    if proc.poll() is None:
        proc.send_signal(signal.SIGINT)
    try:
        proc.wait(timeout=10)
    except subprocess.TimeoutExpired:
        s_print('[' + ip + '] gst-launch would not stop, killing')
        proc.kill()
        proc.wait()
    finally:
        log.close()

    if not os.path.exists(filename) or os.path.getsize(filename) < 10000:
        size = os.path.getsize(filename) if os.path.exists(filename) else 0
        reason = ''
        try:
            with open(logfile) as fh:
                if 'Failed to connect' in fh.read():
                    reason = ' - camera refused the RTSP connection'
        except OSError:
            pass
        s_print('[' + ip + '] recording failed, ' + str(size) + ' bytes'
                + reason + ', see ' + logfile)
        return

    s_print('[' + ip + '] wrote ' + filename + ' ('
            + str(os.path.getsize(filename)) + ' bytes)')

    if _make_thumbnail(filename, thumbnail_filename):
        s_print('[' + ip + '] thumbnail ready')
    else:
        s_print('[' + ip + '] thumbnail failed')

    try:
        webhook_manager.motion_detected(ip, friendly_name, hostname,
                                        serial_number, zones, filename)
    except Exception as exc:
        s_print('[' + ip + '] notification failed: ' + str(exc))
