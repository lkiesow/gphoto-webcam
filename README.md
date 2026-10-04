# gphoto2 → PipeWire webcam

Expose a gphoto2-controlled DSLR as a **native PipeWire virtual camera**
(a `Video/Source` node), replacing the old `gphoto2 --stdout --capture-movie`
→ `v4l2loopback` approach. No kernel module required — Firefox, Chromium and
other apps that support the PipeWire camera portal pick it up directly.

## Usage

```sh
./gphoto2-pipewire-webcam.sh
```

Turning the camera off (or unplugging it) is treated as normal: the script
polls once a second and starts/restarts the stream whenever the camera is
present, and just waits whenever it isn't — no need to restart the script
yourself. Stop it with Ctrl-C.

Overrides via environment variables:

| Variable           | Default       | Meaning                                 |
|--------------------|---------------|-----------------------------------------|
| `CAMERA_NAME`      | `DSLR Webcam` | PipeWire client name                    |
| `NODE_NAME`        | `dslr-webcam` | PipeWire node name (no spaces)          |
| `NODE_DESCRIPTION` | `DSLR-Webcam` | PipeWire node description (no spaces)   |
| `PIXEL_FORMAT`     | `YUY2`        | Raw format negotiated after decoding    |
| `FRAMERATE`        | `30`          | Framerate imposed on the MJPEG stream   |
| `POLL_INTERVAL`    | `1`           | Seconds between camera-presence checks  |

## How it works

```
gphoto2 --stdout --capture-movie
  | gst-launch-1.0 fdsrc is-live=true do-timestamp=true \
      ! jpegparse ! queue leaky=downstream ! jpegdec \
      ! videoconvert ! videorate ! video/x-raw,format=YUY2,framerate=30/1 \
      ! pipewiresink mode=provide stream-properties="...,media.class=Video/Source,media.role=Camera"
```

`pipewiresink` in `mode=provide`, tagged with `media.class=Video/Source` and
`media.role=Camera`, creates a fully userspace PipeWire camera node — this is
the same mechanism used by e.g. OBS's PipeWire virtual camera. The explicit
`videoconvert ! video/x-raw,format=YUY2` forces a concrete raw format;
leaving it to auto-negotiation has been reported to cause "no more input
formats" errors in some consumers (notably OBS's own PipeWire camera source).

Three details in that pipeline are load-bearing, and getting them wrong is
what made earlier versions of this script fail:

- **`fdsrc is-live=true`** — without it GStreamer treats the pipe as a
  non-live stream and tries to preroll it, but `pipewiresink` in
  `mode=provide` never accepts a preroll buffer. The pipeline then either
  hangs in `PREROLLING` forever or fails with
  `stream error: no more input formats`.
- **`videorate` + an explicit `framerate=N/1`** — gphoto2's MJPEG output has
  no timing information whatsoever, so `jpegdec` emits `framerate=0/1`, which
  is not a framerate any PipeWire camera consumer can work with.
  `do-timestamp=true` on `fdsrc` supplies arrival timestamps to go with it.
- **A leaky `queue`** — the camera and the consumer run at independent rates;
  dropping old frames keeps latency from growing over a long call.

Note: it typically takes a few seconds after the camera is detected before
the stream actually starts flowing (gphoto2 initializing live view + GStreamer
caps negotiation) — this is normal, not a hang.

## Troubleshooting

- **`no more input formats` / stuck at `PREROLLING`**: the pipeline is missing
  `fdsrc is-live=true` or a fixed `framerate` — see "How it works" above.
- **Camera never detected**: check `gphoto2 --auto-detect` on its own. If it
  shows nothing, this is a gphoto2/USB issue, not a PipeWire one.
- **"Could not claim the USB device" / device busy**: usually
  `gvfs-gphoto2-volume-monitor` auto-mounting the camera as a storage device.
  The script already kills it on every loop iteration; if it still happens,
  check for a leftover `gphoto2 --stdout --capture-movie` from a previous run
  (`pgrep -af gphoto2`) and for other processes with `fuser`/`lsof` on the USB
  device.
- **Node doesn't show up anywhere**: verify PipeWire sees it directly with
  `wpctl status` (look under Video/Sources) or the `helvum` patchbay GUI,
  before troubleshooting any particular app.
- **Firefox doesn't list the camera**: check `about:config` →
  `media.webrtc.camera.allow-pipewire` is `true` (on Fedora 41+ this is
  already the default). Also requires `xdg-desktop-portal` plus a portal
  backend that implements the camera interface — GNOME/KDE do,
  `xdg-desktop-portal-wlr` does not.
- **Other apps (Zoom, older software)**: some apps don't yet speak the
  PipeWire camera portal natively. `pw-v4l2` (shipped with PipeWire) can wrap
  such an app to present PipeWire camera nodes as a V4L2 device instead.
