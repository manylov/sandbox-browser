#!/usr/bin/env bash
set -euo pipefail

echo "=== Sandbox Browser Starting ==="
echo "PORT=${PORT:-not set}"

export DISPLAY=:1
export HOME=/tmp/openclaw-home
export XDG_CONFIG_HOME="${HOME}/.config"
export XDG_CACHE_HOME="${HOME}/.cache"

CHROME_CDP_PORT="9223"
VNC_PORT="5900"
NOVNC_INTERNAL_PORT="6081"
COMBINED_PORT="${PORT:-6080}"
HEADLESS="${OPENCLAW_BROWSER_HEADLESS:-0}"

mkdir -p "${HOME}" "${HOME}/.chrome" "${XDG_CONFIG_HOME}" "${XDG_CACHE_HOME}"

# Clean up stale X lock files
rm -f /tmp/.X1-lock /tmp/.X11-unix/X1 2>/dev/null || true

echo "Starting Xvfb..."
Xvfb :1 -screen 0 1280x800x24 -ac -nolisten tcp &
sleep 1

# Chrome args
CHROME_ARGS=(
  "--remote-debugging-address=127.0.0.1"
  "--remote-debugging-port=${CHROME_CDP_PORT}"
  "--user-data-dir=${HOME}/.chrome"
  "--no-first-run"
  "--no-default-browser-check"
  "--disable-dev-shm-usage"
  "--disable-background-networking"
  "--disable-features=TranslateUI"
  "--disable-breakpad"
  "--disable-crash-reporter"
  "--metrics-recording-only"
  "--no-sandbox"
)

if [[ "${HEADLESS}" == "1" ]]; then
  CHROME_ARGS+=("--headless=new" "--disable-gpu")
fi

# Proxy support
if [[ -n "${PROXY_URL:-}" ]]; then
  CHROME_ARGS+=("--proxy-server=${PROXY_URL}")
  echo "Proxy enabled: ${PROXY_URL%%@*}@***"
fi

echo "Starting Chromium..."
chromium "${CHROME_ARGS[@]}" about:blank &
CHROME_PID=$!

# Wait for CDP
echo "Waiting for CDP on port ${CHROME_CDP_PORT}..."
for _ in $(seq 1 50); do
  if curl -sS --max-time 1 "http://127.0.0.1:${CHROME_CDP_PORT}/json/version" >/dev/null 2>&1; then
    echo "CDP ready!"
    break
  fi
  sleep 0.2
done

# Caddy config: single combined port
echo "Configuring Caddy on port ${COMBINED_PORT}..."
cat > /tmp/Caddyfile << EOF
{
  auto_https off
  admin off
}
:${COMBINED_PORT} {
  handle /json/* {
    reverse_proxy 127.0.0.1:${CHROME_CDP_PORT} {
      header_up Host 127.0.0.1
    }
  }
  handle /devtools/* {
    reverse_proxy 127.0.0.1:${CHROME_CDP_PORT} {
      header_up Host 127.0.0.1
    }
  }
  handle {
    reverse_proxy 127.0.0.1:${NOVNC_INTERNAL_PORT}
  }
}
EOF

caddy run --config /tmp/Caddyfile &
CADDY_PID=$!
echo "Caddy started (pid ${CADDY_PID})"

# VNC + noVNC
if [[ "${HEADLESS}" != "1" ]]; then
  echo "Starting VNC..."
  VNC_ARGS=(-display :1 -rfbport "${VNC_PORT}" -shared -forever -localhost)
  if [[ -n "${VNC_PASSWORD:-}" ]]; then
    mkdir -p "${HOME}/.vnc"
    x11vnc -storepasswd "${VNC_PASSWORD}" "${HOME}/.vnc/passwd"
    VNC_ARGS+=(-rfbauth "${HOME}/.vnc/passwd")
    echo "VNC password protection enabled"
  else
    VNC_ARGS+=(-nopw)
  fi
  x11vnc "${VNC_ARGS[@]}" &
  sleep 1
  echo "Starting noVNC on port ${NOVNC_INTERNAL_PORT}..."
  websockify --web /usr/share/novnc/ "${NOVNC_INTERNAL_PORT}" "localhost:${VNC_PORT}" &
  echo "noVNC ready!"
fi

echo "=== Sandbox Browser Ready ==="
echo "CDP: http://localhost:${COMBINED_PORT}/json/version"
echo "noVNC: http://localhost:${COMBINED_PORT}/"

# Keep running - wait for Chrome to exit
wait ${CHROME_PID}
