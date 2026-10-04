#!/usr/bin/env bash
#
# Expose a gphoto2-controlled DSLR as a native PipeWire virtual camera
# (Video/Source node), without v4l2loopback. Consumers like Firefox,
# Chromium and Zoom can pick it up via the xdg-desktop-portal camera portal.
#
# The camera being off/unplugged is treated as normal, expected state, not
# an error: this script polls for it and (re)starts the stream whenever it
# appears, and goes back to waiting whenever it disappears or the pipeline
# dies (USB hiccup, camera going to sleep, user switching it off mid-call).

set -uo pipefail

CAMERA_NAME="${CAMERA_NAME:-DSLR Webcam}"
NODE_NAME="${NODE_NAME:-dslr-webcam}"
NODE_DESCRIPTION="${NODE_DESCRIPTION:-DSLR-Webcam}"
PIXEL_FORMAT="${PIXEL_FORMAT:-YUY2}"
# gphoto2's MJPEG stream carries no timing information at all, so a framerate
# has to be imposed downstream (see the videorate in the pipeline below).
FRAMERATE="${FRAMERATE:-30}"
POLL_INTERVAL="${POLL_INTERVAL:-1}"

log() {
  echo "[gphoto2-pipewire-webcam] $*"
}

run_pipeline() {
  # fdsrc is-live=true is essential: without it GStreamer treats the pipe as
  # a seekable, non-live stream and tries to preroll, but pipewiresink in
  # mode=provide never accepts a preroll buffer, so the pipeline sits in
  # PAUSED forever (or dies with "stream error: no more input formats").
  # do-timestamp=true stamps the frames with arrival time, since the MJPEG
  # bytes from gphoto2 carry no timestamps of their own.
  gphoto2 --stdout --capture-movie 2>/dev/null \
    | gst-launch-1.0 -e fdsrc fd=0 is-live=true do-timestamp=true blocksize=65536 \
        ! jpegparse \
        ! queue max-size-buffers=3 leaky=downstream \
        ! jpegdec \
        ! videoconvert \
        ! videorate \
        ! "video/x-raw,format=${PIXEL_FORMAT},framerate=${FRAMERATE}/1" \
        ! pipewiresink mode=provide \
            client-name="${CAMERA_NAME}" \
            stream-properties="properties,node.name=${NODE_NAME},node.description=${NODE_DESCRIPTION},media.type=Video,media.class=Video/Source,media.role=Camera"
}

# Whichever side of the pipe dies first, the survivor has to go too: a
# lingering gphoto2 keeps the USB device claimed and the next attempt fails
# with "Could not claim the USB device", and a lingering gst-launch keeps a
# stale PipeWire node of the same name around.
kill_tree() {
  local pid="$1" child
  for child in $(pgrep -P "$pid" 2>/dev/null); do
    kill_tree "$child"
  done
  kill -TERM "$pid" 2>/dev/null || true
}

stop=0
pipeline_pid=""

shutdown() {
  stop=1
  [ -n "$pipeline_pid" ] && kill_tree "$pipeline_pid"
}
trap shutdown INT TERM

while [ "$stop" -eq 0 ]; do
  # gvfs auto-mounting the camera as a storage device fights gphoto2 for
  # the USB connection ("device busy"); clear it out of the way each pass.
  pkill -f gvfs-gphoto2-volume-monitor 2>/dev/null || true

  if gphoto2 --auto-detect 2>/dev/null | grep -q usb; then
    log "camera detected, starting stream..."
    # Run the pipeline in the background and wait for it, so that INT/TERM are
    # handled immediately: a trap on a foreground command would only fire once
    # that command returned, i.e. never.
    run_pipeline &
    pipeline_pid=$!
    wait "$pipeline_pid" 2>/dev/null
    kill_tree "$pipeline_pid"
    wait "$pipeline_pid" 2>/dev/null
    pipeline_pid=""
    [ "$stop" -eq 0 ] && log "stream ended, will retry in ${POLL_INTERVAL}s..."
  else
    log "camera not found, waiting..."
  fi

  [ "$stop" -eq 0 ] && sleep "$POLL_INTERVAL"
done

log "stopped."
