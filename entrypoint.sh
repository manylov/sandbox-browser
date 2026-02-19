#!/usr/bin/env bash
set -euo pipefail

echo "=== Sandbox Browser Starting ==="

export DISPLAY=:1
export HOME=/tmp/openclaw-home
export XDG_CONFIG_HOME="${HOME}/.config"
export XDG_CACHE_HOME="${HOME}/.cache"

CHROME_CDP_PORT="9223"
CDP_PROXY_PORT="9222"
VNC_PORT="5900"
COMBINED_PORT="${PORT:-6080}"
HEADLESS="${OPENCLAW_BROWSER_HEADLESS:-0}"

mkdir -p "${HOME}" "${HOME}/.chrome" "${XDG_CONFIG_HOME}" "${XDG_CACHE_HOME}"
rm -f /tmp/.X1-lock /tmp/.X11-unix/X1 2>/dev/null || true

echo "Starting Xvfb..."
Xvfb :1 -screen 0 1280x800x24 -ac -nolisten tcp &
sleep 1

CHROME_ARGS=(
  "--remote-debugging-address=0.0.0.0"
  "--remote-debugging-port=${CHROME_CDP_PORT}"
  "--user-data-dir=${HOME}/.chrome"
  "--no-first-run" "--no-default-browser-check"
  "--disable-dev-shm-usage" "--disable-background-networking"
  "--disable-features=TranslateUI" "--disable-breakpad"
  "--disable-crash-reporter" "--metrics-recording-only"
  "--no-sandbox"
)

[[ "${HEADLESS}" == "1" ]] && CHROME_ARGS+=("--headless=new" "--disable-gpu")

# Proxy with auth support via Chrome extension
if [[ -n "${PROXY_URL:-}" ]]; then
  # Parse: http://user:pass@host:port
  PROXY_PROTO=$(echo "${PROXY_URL}" | sed -nE 's|(https?)://.*|\1|p')
  PROXY_AUTH=$(echo "${PROXY_URL}" | sed -nE 's|https?://([^@]+)@.*|\1|p')
  PROXY_HOSTPORT=$(echo "${PROXY_URL}" | sed -E 's|https?://([^@]+@)?||; s|/.*||')
  PROXY_HOST=$(echo "${PROXY_HOSTPORT}" | cut -d: -f1)
  PROXY_PORT=$(echo "${PROXY_HOSTPORT}" | cut -d: -f2)
  
  if [[ -n "${PROXY_AUTH}" ]]; then
    PROXY_USER=$(echo "${PROXY_AUTH}" | cut -d: -f1)
    PROXY_PASS=$(echo "${PROXY_AUTH}" | cut -d: -f2-)
    
    # Create Chrome extension for proxy auth
    PROXY_EXT_DIR="${HOME}/proxy-ext"
    mkdir -p "${PROXY_EXT_DIR}"
    
    cat > "${PROXY_EXT_DIR}/manifest.json" << 'EXTEOF'
{
  "version": "1.0.0",
  "manifest_version": 2,
  "name": "Proxy Auth",
  "permissions": ["proxy", "webRequest", "webRequestAuthProvider", "<all_urls>"],
  "background": {"scripts": ["background.js"]}
}
EXTEOF

    cat > "${PROXY_EXT_DIR}/background.js" << EXTEOF
const config = {
  mode: "fixed_servers",
  rules: {
    singleProxy: {
      scheme: "${PROXY_PROTO:-http}",
      host: "${PROXY_HOST}",
      port: parseInt("${PROXY_PORT}")
    },
    bypassList: ["localhost","127.0.0.1"]
  }
};
chrome.proxy.settings.set({value: config, scope: "regular"}, function() {});
chrome.webRequest.onAuthRequired.addListener(
  function(details) {
    return {authCredentials: {username: "${PROXY_USER}", password: "${PROXY_PASS}"}};
  },
  {urls: ["<all_urls>"]},
  ["blocking"]
);
EXTEOF

    CHROME_ARGS+=("--load-extension=${PROXY_EXT_DIR}")
    echo "Proxy enabled via extension: ${PROXY_HOST}:${PROXY_PORT}"
  else
    CHROME_ARGS+=("--proxy-server=${PROXY_URL}")
    echo "Proxy enabled (no auth): ${PROXY_HOSTPORT}"
  fi
fi

echo "Starting Chromium..."
chromium "${CHROME_ARGS[@]}" about:blank &
CHROME_PID=$!

echo "Waiting for CDP..."
for _ in $(seq 1 50); do
  curl -sS --max-time 1 "http://127.0.0.1:${CHROME_CDP_PORT}/json/version" >/dev/null 2>&1 && break
  sleep 0.2
done
echo "CDP ready on :${CHROME_CDP_PORT}"

# Caddy: CDP proxy with Host rewrite
cat > /tmp/Caddyfile << EOF
{
	auto_https off
	admin off
}
:${CDP_PROXY_PORT} {
	reverse_proxy 127.0.0.1:${CHROME_CDP_PORT} {
		header_up Host 127.0.0.1
	}
}
EOF
caddy run --config /tmp/Caddyfile &
echo "CDP proxy on :${CDP_PROXY_PORT}"

# VNC + noVNC directly on COMBINED_PORT
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
  websockify --web /usr/share/novnc/ "${COMBINED_PORT}" "localhost:${VNC_PORT}" &
fi

echo "=== Sandbox Browser Ready ==="
wait ${CHROME_PID}
