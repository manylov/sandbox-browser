#!/usr/bin/env bash
set -euo pipefail

echo "=== Sandbox Browser Starting ==="

export DISPLAY=:1
export HOME=/tmp/openclaw-home
export XDG_CONFIG_HOME="${HOME}/.config"
export XDG_CACHE_HOME="${HOME}/.cache"
export TZ="America/New_York"

CHROME_CDP_PORT="9223"
VNC_PORT="5900"
WS_PORT="6081"
COMBINED_PORT="${PORT:-6080}"

mkdir -p "${HOME}" "${HOME}/.chrome" "${XDG_CONFIG_HOME}" "${XDG_CACHE_HOME}"
rm -f /tmp/.X1-lock /tmp/.X11-unix/X1 2>/dev/null || true
rm -rf "${HOME}/proxy-ext" 2>/dev/null || true

echo "Starting Xvfb..."
Xvfb :1 -screen 0 1920x1080x24 -ac -nolisten tcp &
sleep 1

# Create stealth extension directory
STEALTH_EXT_DIR="${HOME}/stealth-ext"
mkdir -p "${STEALTH_EXT_DIR}"
cat > "${STEALTH_EXT_DIR}/manifest.json" << 'EXTEOF'
{
  "manifest_version": 3,
  "name": "Stealth",
  "version": "1.0",
  "content_scripts": [{
    "matches": ["<all_urls>"],
    "js": ["stealth.js"],
    "run_at": "document_start",
    "all_frames": true,
    "world": "MAIN"
  }]
}
EXTEOF
cp /usr/local/bin/stealth.js "${STEALTH_EXT_DIR}/stealth.js"

CHROME_ARGS=(
  "--remote-debugging-address=0.0.0.0"
  "--remote-debugging-port=${CHROME_CDP_PORT}"
  "--user-data-dir=${HOME}/.chrome"
  "--no-first-run" "--no-default-browser-check"
  "--disable-dev-shm-usage"
  "--disable-background-networking"
  "--disable-features=TranslateUI"
  "--disable-breakpad"
  "--disable-crash-reporter"
  "--metrics-recording-only"
  "--no-sandbox"
  "--disable-blink-features=AutomationControlled"
  "--disable-infobars"
  "--window-size=1920,1080"
  "--lang=en-US"
  "--load-extension=${STEALTH_EXT_DIR}"
  "--flag-switches-begin" "--flag-switches-end"
)

# Proxy support
if [[ -n "${PROXY_URL:-}" ]]; then
  PROXY_AUTH=$(echo "${PROXY_URL}" | sed -nE 's|https?://([^@]+)@.*|\1|p')
  PROXY_HOSTPORT=$(echo "${PROXY_URL}" | sed -E 's|https?://([^@]+@)?||; s|/.*||')

  if [[ -n "${PROXY_AUTH}" ]]; then
    LOCAL_PROXY_PORT="8888"
    python3 /usr/local/bin/proxy-auth.py "${PROXY_HOSTPORT}" "${PROXY_AUTH}" "${LOCAL_PROXY_PORT}" &
    sleep 1
    CHROME_ARGS+=("--proxy-server=http://127.0.0.1:${LOCAL_PROXY_PORT}")
    echo "Proxy: local:${LOCAL_PROXY_PORT} -> ${PROXY_HOSTPORT} (with auth)"
  else
    CHROME_ARGS+=("--proxy-server=${PROXY_URL}")
    echo "Proxy: ${PROXY_HOSTPORT} (no auth)"
  fi
fi

echo "Starting Google Chrome..."
google-chrome-stable "${CHROME_ARGS[@]}" about:blank &
CHROME_PID=$!

echo "Waiting for CDP..."
for _ in $(seq 1 50); do
  curl -sS --max-time 1 "http://127.0.0.1:${CHROME_CDP_PORT}/json/version" >/dev/null 2>&1 && break
  sleep 0.2
done
echo "CDP ready on :${CHROME_CDP_PORT}"

# VNC
VNC_ARGS=(-display :1 -rfbport "${VNC_PORT}" -shared -forever -localhost)
if [[ -n "${VNC_PASSWORD:-}" ]]; then
  mkdir -p "${HOME}/.vnc"
  x11vnc -storepasswd "${VNC_PASSWORD}" "${HOME}/.vnc/passwd"
  VNC_ARGS+=(-rfbauth "${HOME}/.vnc/passwd")
  echo "VNC password enabled"
else
  VNC_ARGS+=(-nopw)
fi
x11vnc "${VNC_ARGS[@]}" &
sleep 1

# websockify + noVNC
websockify --web /usr/share/novnc/ "${WS_PORT}" "localhost:${VNC_PORT}" &
sleep 1

# Caddy: single port routing CDP + noVNC
cat > /tmp/Caddyfile << EOF
{
  auto_https off
  admin off
}
:${COMBINED_PORT} {
  handle /json/* {
    reverse_proxy 127.0.0.1:${CHROME_CDP_PORT}
  }
  handle /devtools/* {
    reverse_proxy 127.0.0.1:${CHROME_CDP_PORT}
  }
  handle {
    reverse_proxy 127.0.0.1:${WS_PORT}
  }
}
EOF

echo "=== Sandbox Browser Ready ==="
echo "CDP: :${CHROME_CDP_PORT}, VNC: :${VNC_PORT}, WS: :${WS_PORT}, Caddy: :${COMBINED_PORT}"

exec caddy run --config /tmp/Caddyfile
