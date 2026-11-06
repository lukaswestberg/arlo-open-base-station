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
# tcp, not udp: over UDP the camera ends the session early (one measured run
# stopped at 47 s) and delivers fewer frames. Over TCP it streamed past 75 s.
RTSP_PROTOCOLS = str(_config.get('MotionRtspProtocols', 'tcp'))

# Between motion events the camera tears its network stack down, and a PIR
# alert can land before its RTSP server answers again. gst-launch then dies at
# the connect step ("Failed to connect", before OPTIONS is ever sent) within a
# second, so a retry is cheap. It is a retry and not a readiness probe: a TCP
# connect to 554 always succeeds, and a DESCRIBE probe was unreliable and used
# up the camera's only session.
CONNECT_ATTEMPTS = max(1, int(_config.get('MotionRtspConnectAttempts', 3)))
CONNECT_RETRY_SECONDS = 2

# The camera serves exactly one RTSP session. A second gst-launch started while
# a recording is live dies at the SDP with "Failed to connect", so overlapping
# motion alerts must not race each other for the stream.
_active = set()
_active_lock = threading.Lock()


def _pipeline(ip, ts_filename):
    """gst-launch argv writing MPEG-TS. Port 554 is H.264 1080p, 555 is 4K HEVC.

    mpegtsmux rather than matroskamux: the camera drops from 24 to 15 fps
    mid-stream, which changes both the framerate field and codec_data. Matroska
    cannot take a caps change and aborts the recording, so clips were truncated
    at whatever second the camera happened to switch (3.4 s and 9.1 s were both
    observed). Matroska also stamped the frames it did get from the declared
    framerate rather than real time, so a 47 s stream was written as a 20 s
    file. MPEG-TS carries parameter sets in-band, takes the change in its
    stride, and keeps the timestamps honest.
    """
    if RTSP_PORT == 555:
        depay, parse = 'rtph265depay', 'h265parse'
    else:
        depay, parse = 'rtph264depay', 'h264parse'
    location = 'rtsp://' + ip + ':' + str(RTSP_PORT) + '/live'
    return [
        'gst-launch-1.0', '-e',
        'rtspsrc', 'location=' + location,
        'protocols=' + RTSP_PROTOCOLS,
        'latency=' + str(RTSP_LATENCY_MS),
        '!', depay,
        '!', parse,
        '!', 'mpegtsmux',
        '!', 'filesink', 'location=' + ts_filename,
    ]


def _remux(ts_filename, filename):
    """Stream-copy the .ts into the .mkv the viewer expects. Local file, so
    ffmpeg handles it fine - it is only the camera's RTSP server it cannot
    open."""
    cmd = ['ffmpeg', '-hide_banner', '-loglevel', 'error', '-y',
           '-i', ts_filename, '-c', 'copy', filename]
    try:
        subprocess.run(cmd, capture_output=True, timeout=120)
    except Exception as exc:
        s_print('remux failed: ' + str(exc))
        return False
    return os.path.exists(filename) and os.path.getsize(filename) > 0


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


def _log_says(logfile, offset, needle):
    """True if needle appears in logfile past offset (this attempt's output)."""
    try:
        with open(logfile) as fh:
            fh.seek(offset)
            return needle in fh.read()
    except OSError:
        return False


def _run_gst(ip, cmd, logfile, attempt):
    """Run one gst-launch for at most CLIP_SECONDS, appending to logfile.

    Returns False only if the process could not be started at all.
    """
    log = open(logfile, 'w' if attempt == 1 else 'a')
    if attempt > 1:
        log.write('\n--- attempt ' + str(attempt) + ' ---\n')
        log.flush()
    try:
        proc = subprocess.Popen(cmd, stdout=log, stderr=log)
    except Exception as exc:
        log.close()
        s_print('[' + ip + '] could not start gst-launch: ' + str(exc))
        return False

    # The camera usually ends the stream before CLIP_SECONDS is up, and -e has
    # already finalised the container by then. Poll rather than sleeping the
    # full clip length, so the next motion alert is not locked out of a stream
    # that is no longer being used. It also makes a refused connect return in
    # about a second, which is what keeps the retry cheap.
    deadline = time.monotonic() + CLIP_SECONDS
    while time.monotonic() < deadline and proc.poll() is None:
        time.sleep(0.5)
    # -e turns SIGINT into an EOS, which finalises the container.
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
    return True


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

    # gst writes MPEG-TS; the .mkv the viewer serves is remuxed from it below.
    ts_filename = filename[:-len('.mkv')] + '.ts'
    cmd = _pipeline(ip, ts_filename)
    s_print('[' + ip + '] gst recording ' + str(CLIP_SECONDS) + 's from port '
            + str(RTSP_PORT) + ' over ' + RTSP_PROTOCOLS)

    for attempt in range(1, CONNECT_ATTEMPTS + 1):
        log_offset = os.path.getsize(logfile) if attempt > 1 else 0
        if not _run_gst(ip, cmd, logfile, attempt):
            return
        size = os.path.getsize(ts_filename) if os.path.exists(ts_filename) else 0
        if size >= 10000:
            break
        refused = _log_says(logfile, log_offset, 'Failed to connect')
        if refused and attempt < CONNECT_ATTEMPTS:
            s_print('[' + ip + '] RTSP not answering yet, retry '
                    + str(attempt) + '/' + str(CONNECT_ATTEMPTS - 1)
                    + ' in ' + str(CONNECT_RETRY_SECONDS) + 's')
            time.sleep(CONNECT_RETRY_SECONDS)
            continue
        reason = ' - camera refused the RTSP connection' if refused else ''
        s_print('[' + ip + '] recording failed after ' + str(attempt)
                + ' attempt(s), ' + str(size) + ' bytes' + reason
                + ', see ' + logfile)
        if os.path.exists(ts_filename):
            os.remove(ts_filename)
        return

    if not _remux(ts_filename, filename):
        s_print('[' + ip + '] remux failed, keeping ' + ts_filename)
        return
    os.remove(ts_filename)

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
