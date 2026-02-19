#!/usr/bin/env bash
set -euo pipefail

export DISPLAY=:1
export HOME=/tmp/openclaw-home
export XDG_CONFIG_HOME="${HOME}/.config"
export XDG_CACHE_HOME="${HOME}/.cache"

CDP_PORT="${OPENCLAW_BROWSER_CDP_PORT:-${CLAWDBOT_BROWSER_CDP_PORT:-9222}}"
VNC_PORT="${OPENCLAW_BROWSER_VNC_PORT:-${CLAWDBOT_BROWSER_VNC_PORT:-5900}}"
NOVNC_PORT="${OPENCLAW_BROWSER_NOVNC_PORT:-${CLAWDBOT_BROWSER_NOVNC_PORT:-6080}}"
ENABLE_NOVNC="${OPENCLAW_BROWSER_ENABLE_NOVNC:-${CLAWDBOT_BROWSER_ENABLE_NOVNC:-1}}"
HEADLESS="${OPENCLAW_BROWSER_HEADLESS:-${CLAWDBOT_BROWSER_HEADLESS:-0}}"
# Combined port for Railway (serves both CDP and noVNC)
COMBINED_PORT="${PORT:-0}"

mkdir -p "${HOME}" "${HOME}/.chrome" "${XDG_CONFIG_HOME}" "${XDG_CACHE_HOME}"

Xvfb :1 -screen 0 1280x800x24 -ac -nolisten tcp &

if [[ "${HEADLESS}" == "1" ]]; then
  CHROME_ARGS=(
    "--headless=new"
    "--disable-gpu"
  )
else
  CHROME_ARGS=()
fi

CHROME_CDP_PORT="9223"

CHROME_ARGS+=(
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

# === PROXY SUPPORT ===
if [[ -n "${PROXY_URL:-}" ]]; then
  CHROME_ARGS+=("--proxy-server=${PROXY_URL}")
  echo "Proxy enabled: ${PROXY_URL%%@*}@***"
fi

# === EXTRA CHROME FLAGS ===
if [[ -n "${EXTRA_CHROME_FLAGS:-}" ]]; then
  IFS=' ' read -ra EXTRA_FLAGS <<< "${EXTRA_CHROME_FLAGS}"
  CHROME_ARGS+=("${EXTRA_FLAGS[@]}")
fi

chromium "${CHROME_ARGS[@]}" about:blank &

for _ in $(seq 1 50); do
  if curl -sS --max-time 1 "http://127.0.0.1:${CHROME_CDP_PORT}/json/version" >/dev/null; then
    break
  fi
  sleep 0.1
done

# Caddy: CDP proxy on dedicated port (rewrite Host for Chrome)
cat > /tmp/Caddyfile << EOF
{
  auto_https off
  admin off
}
:${CDP_PORT} {
  reverse_proxy 127.0.0.1:${CHROME_CDP_PORT} {
    header_up Host 127.0.0.1
  }
}
EOF

# If COMBINED_PORT is set (Railway), add a combined endpoint
if [[ "${COMBINED_PORT}" != "0" ]]; then
cat >> /tmp/Caddyfile << EOF
:${COMBINED_PORT} {
  # CDP endpoints
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
  # Everything else -> noVNC
  handle {
    reverse_proxy 127.0.0.1:${NOVNC_PORT}
  }
}
EOF
echo "Combined port ${COMBINED_PORT}: CDP (/json/*, /devtools/*) + noVNC (everything else)"
fi

caddy run --config /tmp/Caddyfile &

if [[ "${ENABLE_NOVNC}" == "1" && "${HEADLESS}" != "1" ]]; then
  x11vnc -display :1 -rfbport "${VNC_PORT}" -shared -forever -nopw -localhost &
  websockify --web /usr/share/novnc/ "${NOVNC_PORT}" "localhost:${VNC_PORT}" &
fi

wait -n
