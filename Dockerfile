FROM ghcr.io/canyugs/openclaw-sandbox-browser:main

# Custom entrypoint that supports PROXY_URL env variable
COPY entrypoint.sh /usr/local/bin/openclaw-sandbox-browser
RUN chmod +x /usr/local/bin/openclaw-sandbox-browser

CMD ["openclaw-sandbox-browser"]
