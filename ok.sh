#!/usr/bin/env bash

set -Eeuo pipefail


# =========================================================
# BASE CONFIG
# =========================================================

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ENV_FILE="${ENV_FILE:-$BASE_DIR/.env}"


# =========================================================
# LOAD .ENV
# =========================================================

if [[ -f "$ENV_FILE" ]]; then

  set -a
  source "$ENV_FILE"
  set +a

fi


# =========================================================
# REQUIRED VARIABLES
# =========================================================

: "${KICK_SOURCE_URL:?Set KICK_SOURCE_URL in .env}"
: "${KICK_RTMP_URL:?Set KICK_RTMP_URL in .env}"
: "${KICK_STREAM_KEY:?Set KICK_STREAM_KEY in .env}"


# =========================================================
# SETTINGS
# =========================================================

WIDTH="${WIDTH:-1920}"
HEIGHT="${HEIGHT:-1080}"

FPS="${FPS:-30}"

VIDEO_BITRATE="${VIDEO_BITRATE:-4500k}"
AUDIO_BITRATE="${AUDIO_BITRATE:-128k}"

X264_PRESET="${X264_PRESET:-ultrafast}"

DISPLAY_NUM="${DISPLAY_NUM:-99}"

SINK_NAME="${SINK_NAME:-kick_sink}"

PROFILE_DIR="${PROFILE_DIR:-$BASE_DIR/chromium-profile}"

PYTHON_BIN="${PYTHON_BIN:-$BASE_DIR/.venv/bin/python3}"

START_DELAY="${START_DELAY:-8}"

FULLSCREEN_DELAY="${FULLSCREEN_DELAY:-5}"

SCREENSHOT_FILE="${SCREENSHOT_FILE:-$BASE_DIR/stream-browser.png}"

PLAYER_CLICK_X="${PLAYER_CLICK_X:-$((WIDTH / 2))}"

PLAYER_CLICK_Y="${PLAYER_CLICK_Y:-$((HEIGHT / 3))}"

FULLSCREEN_BUTTON_X="${FULLSCREEN_BUTTON_X:-$((WIDTH * 81 / 100))}"

FULLSCREEN_BUTTON_Y="${FULLSCREEN_BUTTON_Y:-$((HEIGHT * 74 / 100))}"


# =========================================================
# DISPLAY
# =========================================================

DISPLAY=":$DISPLAY_NUM"

export DISPLAY
export WIDTH
export HEIGHT


# =========================================================
# PYTHON
# =========================================================

if [[ ! -x "$PYTHON_BIN" ]]; then

  PYTHON_BIN="$(command -v python3 || true)"

fi

[[ -n "$PYTHON_BIN" ]] || {

  printf 'Python3 not found.\n' >&2
  exit 1

}


# =========================================================
# FIND CHROMIUM
# =========================================================

CHROMIUM="${CHROMIUM_BIN:-}"


if [[ -z "$CHROMIUM" ]]; then

  for candidate in \
    google-chrome \
    google-chrome-stable \
    chromium \
    chromium-browser
  do

    candidate_path="$(
      command -v "$candidate" 2>/dev/null || true
    )"

    if [[ -n "$candidate_path" ]] \
      && "$candidate_path" --version >/dev/null 2>&1
    then

      CHROMIUM="$candidate_path"
      break

    fi

  done

fi


# =========================================================
# CHECK REQUIRED COMMANDS
# =========================================================

for required in \
  Xvfb \
  ffmpeg \
  pulseaudio \
  pactl \
  xdotool
do

  command -v "$required" >/dev/null 2>&1 || {

    printf \
      'Missing required command: %s\n' \
      "$required" >&2

    exit 1

  }

done


[[ -n "$CHROMIUM" ]] || {

  printf \
    'Missing Chromium/Chrome. Set CHROMIUM_BIN in .env or install Chromium.\n' \
    >&2

  exit 1

}


# =========================================================
# PROCESS VARIABLES
# =========================================================

XVFB_PID=""

CHROMIUM_PID=""

FFMPEG_PID=""

TELEGRAM_PID=""

SINK_MODULE=""


# =========================================================
# CLEANUP
# =========================================================

cleanup() {

  set +e

  printf '\nStopping processes...\n'

  [[ -n "$FFMPEG_PID" ]] && \
    kill "$FFMPEG_PID" 2>/dev/null

  [[ -n "$TELEGRAM_PID" ]] && \
    kill "$TELEGRAM_PID" 2>/dev/null

  [[ -n "$CHROMIUM_PID" ]] && \
    kill "$CHROMIUM_PID" 2>/dev/null

  [[ -n "$XVFB_PID" ]] && \
    kill "$XVFB_PID" 2>/dev/null

  if [[ -n "$SINK_MODULE" ]]; then

    pactl unload-module \
      "$SINK_MODULE" \
      >/dev/null 2>&1

  fi

}


trap cleanup EXIT INT TERM


# =========================================================
# CREATE DIRECTORIES
# =========================================================

mkdir -p "$PROFILE_DIR"


# =========================================================
# START XVFB
# =========================================================

printf \
  'Starting Xvfb on %s (%sx%s)...\n' \
  "$DISPLAY" \
  "$WIDTH" \
  "$HEIGHT"


Xvfb \
  "$DISPLAY" \
  -screen 0 "${WIDTH}x${HEIGHT}x24" \
  -ac \
  -nolisten tcp \
  -noreset \
  >/tmp/kick-watch-party-xvfb.log 2>&1 &


XVFB_PID=$!


sleep 2


# =========================================================
# START PULSEAUDIO
# =========================================================

printf 'Starting PulseAudio...\n'


pulseaudio \
  --start \
  --exit-idle-time=-1 \
  >/tmp/kick-watch-party-pulseaudio.log 2>&1 \
  || true


sleep 2


# =========================================================
# CREATE AUDIO SINK
# =========================================================

if ! pactl list short sinks \
  | awk '{print $2}' \
  | grep -Fxq "$SINK_NAME"
then

  SINK_MODULE="$(
    pactl load-module \
      module-null-sink \
      sink_name="$SINK_NAME" \
      sink_properties=device.description=KickSink
  )"

fi


pactl set-default-sink "$SINK_NAME"


# =========================================================
# START CHROMIUM
# =========================================================

printf 'Starting browser with Kick cookies...\n'


"$PYTHON_BIN" \
  "$BASE_DIR/kick_cookie_browser.py" \
  --chromium-bin "$CHROMIUM" \
  --profile-dir "$PROFILE_DIR" \
  --cookie-file "$BASE_DIR/cookies.json" \
  --kick-url "$KICK_SOURCE_URL" \
  --width "$WIDTH" \
  --height "$HEIGHT" \
  >/tmp/kick-watch-party-chromium.log 2>&1 &


CHROMIUM_PID=$!


# =========================================================
# WAIT FOR BROWSER
# =========================================================

printf \
  'Waiting %s seconds for browser...\n' \
  "$FULLSCREEN_DELAY"


sleep "$FULLSCREEN_DELAY"


# =========================================================
# INITIAL PLAYER CLICK
# =========================================================

CHROME_WINDOW="$(
  xdotool search \
    --onlyvisible \
    --class \
    "google-chrome|google-chrome-stable|chromium|chromium-browser" \
    2>/dev/null \
    | head -n 1 \
    || true
)"


if [[ -n "$CHROME_WINDOW" ]]; then

  printf \
    'Browser window found: %s\n' \
    "$CHROME_WINDOW"


  # Click player
  xdotool mousemove \
    --window "$CHROME_WINDOW" \
    "$PLAYER_CLICK_X" \
    "$PLAYER_CLICK_Y"


  xdotool click \
    --window "$CHROME_WINDOW" \
    1


  sleep 1


  # Click fullscreen button
  xdotool mousemove \
    --window "$CHROME_WINDOW" \
    "$FULLSCREEN_BUTTON_X" \
    "$FULLSCREEN_BUTTON_Y"


  xdotool click \
    --window "$CHROME_WINDOW" \
    1


  printf \
    'Clicked player at %s,%s\n' \
    "$PLAYER_CLICK_X" \
    "$PLAYER_CLICK_Y"


  printf \
    'Clicked fullscreen button at %s,%s\n' \
    "$FULLSCREEN_BUTTON_X" \
    "$FULLSCREEN_BUTTON_Y"


else

  printf \
    'Chrome window not found; skipped initial click.\n' \
    >&2

fi


# =========================================================
# START TELEGRAM BOT
# =========================================================

if [[ -n "${TELEGRAM_BOT_TOKEN:-}" ]] \
  && [[ -n "${TELEGRAM_ALLOWED_USER_ID:-}" ]]
then

  printf \
    'Starting Telegram browser control...\n'


  DISPLAY="$DISPLAY" \
  WIDTH="$WIDTH" \
  HEIGHT="$HEIGHT" \
  "$PYTHON_BIN" \
  "$BASE_DIR/telegram-fullscreen.py" \
  >/tmp/kick-watch-party-telegram.log 2>&1 &


  TELEGRAM_PID=$!


  printf \
    'Telegram control started. PID: %s\n' \
    "$TELEGRAM_PID"


else

  printf \
    'Telegram control disabled.\n'

fi


# =========================================================
# WAIT BEFORE STREAM
# =========================================================

sleep "$START_DELAY"


# =========================================================
# DIAGNOSTIC SCREENSHOT
# =========================================================

printf \
  'Saving diagnostic screenshot...\n'


ffmpeg \
  -hide_banner \
  -loglevel error \
  -y \
  -f x11grab \
  -video_size "${WIDTH}x${HEIGHT}" \
  -i "${DISPLAY}.0+0,0" \
  -frames:v 1 \
  "$SCREENSHOT_FILE" \
  || printf \
    'Could not save browser diagnostic screenshot.\n' \
    >&2


# =========================================================
# OUTPUT URL
# =========================================================

OUTPUT_URL="${KICK_RTMP_URL%/}/${KICK_STREAM_KEY}"


# =========================================================
# START FFMPEG STREAM
# =========================================================

printf '\nStarting FFmpeg stream...\n'


ffmpeg \
  -hide_banner \
  -loglevel warning \
  -thread_queue_size 2048 \
  -f x11grab \
  -draw_mouse 0 \
  -framerate "$FPS" \
  -video_size "${WIDTH}x${HEIGHT}" \
  -i "${DISPLAY}.0+0,0" \
  -thread_queue_size 2048 \
  -f pulse \
  -i "${SINK_NAME}.monitor" \
  -c:v libx264 \
  -preset "$X264_PRESET" \
  -tune zerolatency \
  -pix_fmt yuv420p \
  -r "$FPS" \
  -g "$((FPS * 2))" \
  -keyint_min "$((FPS * 2))" \
  -sc_threshold 0 \
  -b:v "$VIDEO_BITRATE" \
  -maxrate "$VIDEO_BITRATE" \
  -bufsize "${BUFFER_SIZE:-9000k}" \
  -c:a aac \
  -b:a "$AUDIO_BITRATE" \
  -ar 48000 \
  -ac 2 \
  -f flv \
  "$OUTPUT_URL" &


FFMPEG_PID=$!


printf '\n'
printf '=====================================\n'
printf 'STREAM IS RUNNING\n'
printf '=====================================\n'
printf 'Display: %s\n' "$DISPLAY"
printf 'Resolution: %sx%s\n' "$WIDTH" "$HEIGHT"
printf 'FPS: %s\n' "$FPS"
printf 'Source: %s\n' "$KICK_SOURCE_URL"
printf 'Telegram: %s\n' "${TELEGRAM_PID:-Disabled}"
printf 'Press Ctrl+C to stop.\n'
printf '=====================================\n'
printf '\n'


# =========================================================
# WAIT FOR FFMPEG
# =========================================================

wait "$FFMPEG_PID"