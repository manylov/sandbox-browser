FROM ghcr.io/canyugs/openclaw-sandbox-browser:main

# Custom entrypoint that supports PROXY_URL env variable
COPY entrypoint.sh /usr/local/bin/openclaw-sandbox-browser
COPY proxy-auth.py /usr/local/bin/proxy-auth.py
RUN chmod +x /usr/local/bin/openclaw-sandbox-browser /usr/local/bin/proxy-auth.py

CMD ["openclaw-sandbox-browser"]
