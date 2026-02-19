#!/usr/bin/env bash
set -euo pipefail

echo "=== Sandbox Browser Starting ==="

export DISPLAY=:1
export HOME=/tmp/openclaw-home
export XDG_CONFIG_HOME="${HOME}/.config"
export XDG_CACHE_HOME="${HOME}/.cache"
# Timezone matching proxy location (Ashburn, Virginia)
export TZ="America/New_York"

CHROME_CDP_PORT="9223"
CDP_PROXY_PORT="9222"
VNC_PORT="5900"
COMBINED_PORT="${PORT:-6080}"
HEADLESS="${OPENCLAW_BROWSER_HEADLESS:-0}"

mkdir -p "${HOME}" "${HOME}/.chrome" "${XDG_CONFIG_HOME}" "${XDG_CACHE_HOME}"
rm -f /tmp/.X1-lock /tmp/.X11-unix/X1 2>/dev/null || true
rm -rf "${HOME}/proxy-ext" "${HOME}/.chrome/Default/Extensions" 2>/dev/null || true

echo "Starting Xvfb..."
Xvfb :1 -screen 0 1920x1080x24 -ac -nolisten tcp &
sleep 1

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
  # Stealth flags
  "--disable-blink-features=AutomationControlled"
  "--disable-infobars"
  "--exclude-switches=enable-automation"
  "--window-size=1920,1080"
  "--lang=en-US"
  "--flag-switches-begin" "--flag-switches-end"
)

[[ "${HEADLESS}" == "1" ]] && CHROME_ARGS+=("--headless=new" "--disable-gpu")

# Proxy support: PROXY_URL=http://user:pass@host:port
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

# Inject stealth script into all new pages via CDP
echo "Injecting stealth patches..."
STEALTH_JS=$(python3 -c "import json; print(json.dumps(open('/usr/local/bin/stealth.js').read()))")
curl -sS "http://127.0.0.1:${CHROME_CDP_PORT}/json/list" | python3 -c "
import json, sys, http.client
pages = json.load(sys.stdin)
stealth = open('/usr/local/bin/stealth.js').read()
for page in pages:
    ws_url = page.get('webSocketDebuggerUrl', '')
    page_id = page.get('id', '')
    if page_id:
        conn = http.client.HTTPConnection('127.0.0.1', ${CHROME_CDP_PORT})
        # Use the HTTP endpoint to send CDP command
        pass
" 2>/dev/null || true

# Use a small CDP client to inject stealth on every new page
python3 -c "
import json, socket, ssl, hashlib, base64, os, struct, threading, time, http.client

STEALTH_JS = open('/usr/local/bin/stealth.js').read()
CDP_PORT = ${CHROME_CDP_PORT}

def inject_stealth():
    '''Inject stealth JS into the browser via CDP HTTP API'''
    try:
        # Get browser websocket URL
        conn = http.client.HTTPConnection('127.0.0.1', CDP_PORT)
        conn.request('GET', '/json/version')
        resp = conn.getresponse()
        version = json.loads(resp.read())
        ws_url = version.get('webSocketDebuggerUrl', '')
        conn.close()
        
        if not ws_url:
            print('No browser WS URL found')
            return
        
        # Use CDP command via /json/protocol is not available via HTTP
        # Instead, inject via command line flag approach - the stealth.js 
        # will be loaded via a chrome extension approach
        
        # For now, inject into existing pages via /json/list
        conn = http.client.HTTPConnection('127.0.0.1', CDP_PORT)
        conn.request('GET', '/json/list')
        resp = conn.getresponse()
        pages = json.loads(resp.read())
        conn.close()
        
        print(f'Found {len(pages)} pages to inject stealth into')
    except Exception as e:
        print(f'Stealth injection note: {e}')

inject_stealth()
" &

# Create a small Chrome extension for stealth injection (runs on every page)
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

# Restart Chrome with the extension loaded
echo "Restarting Chrome with stealth extension..."
kill ${CHROME_PID} 2>/dev/null || true
sleep 2

CHROME_ARGS+=("--load-extension=${STEALTH_EXT_DIR}")

google-chrome-stable "${CHROME_ARGS[@]}" about:blank &
CHROME_PID=$!

echo "Waiting for CDP (restart)..."
for _ in $(seq 1 50); do
  curl -sS --max-time 1 "http://127.0.0.1:${CHROME_CDP_PORT}/json/version" >/dev/null 2>&1 && break
  sleep 0.2
done
echo "CDP ready on :${CHROME_CDP_PORT} (with stealth)"

# Caddy: CDP proxy
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

# VNC + noVNC
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
echo "Chrome with stealth + proxy + VNC"
wait ${CHROME_PID}
