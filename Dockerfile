FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive
ENV DISPLAY=:1

# Base dependencies
RUN apt-get update && apt-get install -y \
    xvfb \
    x11vnc \
    websockify \
    novnc \
    fonts-liberation \
    fonts-noto-color-emoji \
    fonts-noto-cjk \
    dbus-x11 \
    curl \
    wget \
    python3 \
    ca-certificates \
    gnupg \
    apt-transport-https \
    xdg-utils \
    unzip \
    && rm -rf /var/lib/apt/lists/*

# Install Google Chrome (not Chromium!)
RUN curl -fsSL https://dl.google.com/linux/linux_signing_key.pub | gpg --dearmor -o /usr/share/keyrings/google-chrome.gpg \
    && echo "deb [arch=amd64 signed-by=/usr/share/keyrings/google-chrome.gpg] http://dl.google.com/linux/chrome/deb/ stable main" > /etc/apt/sources.list.d/google-chrome.list \
    && apt-get update && apt-get install -y google-chrome-stable \
    && rm -rf /var/lib/apt/lists/*

# Install Caddy
RUN curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg \
    && curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | tee /etc/apt/sources.list.d/caddy-stable.list \
    && apt-get update && apt-get install -y caddy && rm -rf /var/lib/apt/lists/*

RUN mkdir -p /tmp/openclaw-home/.chrome
WORKDIR /tmp/openclaw-home

COPY entrypoint.sh /usr/local/bin/openclaw-sandbox-browser
COPY proxy-auth.py /usr/local/bin/proxy-auth.py
COPY stealth.js /usr/local/bin/stealth.js
RUN chmod +x /usr/local/bin/openclaw-sandbox-browser /usr/local/bin/proxy-auth.py

CMD ["openclaw-sandbox-browser"]
