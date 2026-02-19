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
NOVNC_PORT="6081"
COMBINED_PORT="${PORT:-6080}"
HEADLESS="${OPENCLAW_BROWSER_HEADLESS:-0}"

mkdir -p "${HOME}" "${HOME}/.chrome" "${XDG_CONFIG_HOME}" "${XDG_CACHE_HOME}"

rm -f /tmp/.X1-lock /tmp/.X11-unix/X1 2>/dev/null || true

echo "Starting Xvfb..."
Xvfb :1 -screen 0 1280x800x24 -ac -nolisten tcp &
sleep 1

CHROME_ARGS=(
  "--remote-debugging-address=127.0.0.1"
  "--remote-debugging-port=${CHROME_CDP_PORT}"
  "--user-data-dir=${HOME}/.chrome"
  "--no-first-run" "--no-default-browser-check"
  "--disable-dev-shm-usage" "--disable-background-networking"
  "--disable-features=TranslateUI" "--disable-breakpad"
  "--disable-crash-reporter" "--metrics-recording-only"
  "--no-sandbox"
)

[[ "${HEADLESS}" == "1" ]] && CHROME_ARGS+=("--headless=new" "--disable-gpu")
[[ -n "${PROXY_URL:-}" ]] && CHROME_ARGS+=("--proxy-server=${PROXY_URL}") && echo "Proxy enabled"

echo "Starting Chromium..."
chromium "${CHROME_ARGS[@]}" about:blank &
CHROME_PID=$!

echo "Waiting for CDP..."
for _ in $(seq 1 50); do
  curl -sS --max-time 1 "http://127.0.0.1:${CHROME_CDP_PORT}/json/version" >/dev/null 2>&1 && break
  sleep 0.2
done
echo "CDP ready!"

# VNC + noVNC on internal port
if [[ "${HEADLESS}" != "1" ]]; then
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
  websockify --web /usr/share/novnc/ "${NOVNC_PORT}" "localhost:${VNC_PORT}" &
  echo "noVNC on :${NOVNC_PORT}"
fi

# Caddy: combined port - routes CDP and noVNC+WebSocket
cat > /tmp/Caddyfile << 'CADDYEOF'
{
	auto_https off
	admin off
}
CADDYEOF

cat >> /tmp/Caddyfile << EOF
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
	reverse_proxy 127.0.0.1:${NOVNC_PORT}
}
EOF

echo "Starting Caddy on :${COMBINED_PORT}..."
caddy run --config /tmp/Caddyfile &

echo "=== Sandbox Browser Ready ==="
echo "noVNC: https://host:${COMBINED_PORT}/vnc.html"
echo "CDP:   https://host:${COMBINED_PORT}/json/version"

wait ${CHROME_PID}
