# Arlo Ultra (VMC5040) Fixes

Upstream was written against an Arlo Pro VMC4030. These problems were found
while bringing up a real VMC5040 on an Orange Pi 5 Pro (arm64, Ubuntu 22.04,
Python 3.10), running the onboard WiFi as the camera AP. Several of them
affect every camera model, not just the Ultra.

## Bugs fixed (roughly by severity)

1. **ffmpeg cannot open the Ultra's RTSP server.** Every variant (udp, tcp,
   with or without an explicit `:554`) fails with `Invalid data found when
   processing input`, but GStreamer's `rtspsrc` works. Motion recording now
   uses `helpers/motion_recorder.py`:
   `gst-launch-1.0 -e rtspsrc ! rtph264depay ! h264parse ! matroskamux ! filesink`.
   The recorder sends SIGINT after `MotionClipSeconds`; `-e` turns that into
   EOS so the MKV is finalised. ffmpeg is now only used to take a thumbnail
   from the finished local file.
2. **`REGISTER_SET_INITIAL_ULTRA` had no PIR block**, so the camera was never
   armed and never streamed on motion. It now includes `PIRTargetState`,
   `PIRStartSensitivity`, `PIRAction: "Stream"` (the critical one),
   `AudioTargetState`, `VideoMotionEstimationEnable`,
   `VideoMotionSensitivity` and `DefaultMotionStreamTimeLimit`.
3. **Camera table schema mismatch.** `CREATE TABLE` made 6 columns but the
   code reads and writes 10. On a fresh `arlo.db` the first registration threw
   inside the connection thread, which died silently, so the camera never
   received its register set. Fixed with the full schema plus an idempotent
   `ALTER TABLE` migration for older databases.
4. **`mac_address` was never written**, so every camera showed offline
   forever. `helpers/connectivity_checker.py` now checks the AP's
   `iw station dump` first, falls back to `/proc/net/arp`, and backfills
   `mac_address`.
5. **`WifiCountryCode` was set on the wrong key.** The camera honours
   `SetValues.WifiCountryCode`, which was hardcoded to FR (Ultra) or EU
   (others). Both keys are now set, on a `deepcopy` of the template, because
   `Message()` does not copy and would otherwise mutate the module-level dict.
6. **Disarm-on-registration used the same wrong keys**, so it did nothing. It
   now writes `SetValues.PIRTargetState` and the related keys.
7. **`/camera/<serial>/userstreamactive` crashed.** It called
   `~/arlo-record-oneshot.sh`, a script that was never in the repo.
8. **Blank webhook URLs killed the recording thread** (`requests` raised
   `MissingSchema`). Blank now means disabled, and notification failures are
   caught.
9. **Hardcoded paths.** The DB path now comes from the app directory, the log
   file from `ARLO_LOG_FILE`, the AP interface from `ARLO_AP_INTERFACE`, and
   the viewer's config path and retention from `ARLO_CONFIG` and
   `RETENTION_DAYS`.
10. **`logMessage` frames** used to dump multi-KB firmware blobs into the log.
    They are now summarised on one line.
11. **Viewer cleanup only removed `ffmpeg-*.log`.** It now also removes the
    `gst-<serial>-<time>.log` that the recorder writes next to each clip.

## Known, not fixed

- `idx_camera_ip` is UNIQUE, and `persist()` parks displaced cameras at the
  literal `'UNKNOWN'`, so two cameras can collide there at once.
- The `arm` API endpoint sends `PIRTargetState: 1` (int), while register sets
  use `"Armed"`. Both appear to work.
- `userstreamactive` returns `{"result": false}` even though the camera obeys.
- `gst_hls_stream.py` hardcodes `rtph264depay`, so 4K (port 555, HEVC) live
  view would need an H.265 pipeline. Live view has not been tested on the
  Ultra.
- Viewer retention cleanup only runs when `/api/recordings` is requested.
- `SpotlightEnabled: false` is not proven to be absolute. Every key it writes
  is named `*Alert`, so they plausibly govern only what the lamp does on a
  motion alert, not the camera's own ambient-light behaviour. If the spotlight
  still lights, no register set will fix it and the fallback is physical.
- The `IRLedState` / `IRCutState` values that *enable* infrared are unverified.
  Only `"off"` and `"engaged"` have ever been observed; the camera does not
  error on a value it does not recognise, so a wrong guess shows up as black
  night footage. `arlo/messages.py` carries a ladder of candidates to try.
- `camera.py` builds `Message(arlo.messages.REGISTER_SET)` without `deepcopy`
  in `pir_led`, `arm`, `mic_request` and `speaker_request`, then assigns
  `SetValues`, permanently mutating the module-level template for the life of
  the process.

## Camera facts (VMC5040, HW H10, FW 58.0.15)

- Two RTSP servers: `:554/live` is H.264 1080p and `:555/live` is 4K HEVC. The
  SDP on 554 offers H264 plus AAC-hbr 16k mono and Opus 48k audio.
- The RTSP listener stays bound once the camera registers, so a TCP connect to
  554 tells you nothing about readiness. A hand-written RTSP DESCRIBE probe is
  not reliable either.
- Pairing is WPS push-button against your own hostapd (`wps_state=2`). You
  choose the SSID and PSK; the old base station's credentials are never
  needed.
- Register-set changes only apply on registration, which happens every few
  hours on its own. Pulling the battery for ~2 s forces it.
- Deep sleep works on a hostapd AP (`set PM2 mode`, `glacial_timer 3600`).
- The camera runs its own ambient-light (ALS) state machine, independent of the
  base station and still running while disconnected. It tracks two separate
  channels, IR and Spotlight, each with its own day/night state:
  `Entering night mode for Spotlight. Current lux: 151, enter lux threshold:
  600. Trigger count: 0 (thr:2), bitmask: 0x2, force: 0`. It also logs
  `(non manual mode), updating lights`, so the firmware distinguishes a manual
  light mode from automatic and defaults to automatic.
- The registration `Capabilities` list advertises `IRLED`, `IRCutFilter` and
  `NightVision`, but no spotlight capability, even though the firmware clearly
  drives one.
