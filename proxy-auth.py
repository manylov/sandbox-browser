#!/usr/bin/env python3
"""Local HTTP CONNECT proxy that forwards to an upstream proxy with Basic auth."""
import socket, select, sys, base64, threading, signal

UPSTREAM_HOST = sys.argv[1]  # host:port
UPSTREAM_AUTH = sys.argv[2]  # user:pass
LOCAL_PORT = int(sys.argv[3]) if len(sys.argv) > 3 else 8888

auth_header = f"Proxy-Authorization: Basic {base64.b64encode(UPSTREAM_AUTH.encode()).decode()}\r\n"
upstream_host, upstream_port = UPSTREAM_HOST.split(":")
upstream_port = int(upstream_port)

def handle_client(client_sock):
    try:
        request = b""
        while b"\r\n\r\n" not in request:
            chunk = client_sock.recv(4096)
            if not chunk:
                client_sock.close()
                return
            request += chunk

        first_line = request.split(b"\r\n")[0].decode()
        method = first_line.split()[0]

        # Connect to upstream proxy
        upstream = socket.create_connection((upstream_host, upstream_port), timeout=10)

        if method == "CONNECT":
            # HTTPS tunnel
            target = first_line.split()[1]
            upstream_req = f"CONNECT {target} HTTP/1.1\r\nHost: {target}\r\n{auth_header}\r\n"
            upstream.sendall(upstream_req.encode())

            # Read upstream response
            resp = b""
            while b"\r\n\r\n" not in resp:
                resp += upstream.recv(4096)

            if b"200" in resp.split(b"\r\n")[0]:
                client_sock.sendall(b"HTTP/1.1 200 Connection established\r\n\r\n")
                # Tunnel bidirectionally
                tunnel(client_sock, upstream)
            else:
                client_sock.sendall(resp)
        else:
            # HTTP request - inject auth header
            lines = request.split(b"\r\n")
            new_lines = [lines[0]]
            for line in lines[1:]:
                if line.lower().startswith(b"proxy-auth"):
                    continue
                new_lines.append(line)
            # Insert auth after first line
            new_lines.insert(1, auth_header.strip().encode())
            upstream.sendall(b"\r\n".join(new_lines))

            # Forward response
            while True:
                data = upstream.recv(65536)
                if not data:
                    break
                client_sock.sendall(data)

        upstream.close()
    except Exception:
        pass
    finally:
        try:
            client_sock.close()
        except:
            pass

def tunnel(sock1, sock2):
    sockets = [sock1, sock2]
    try:
        while sockets:
            readable, _, _ = select.select(sockets, [], [], 60)
            if not readable:
                break
            for s in readable:
                data = s.recv(65536)
                if not data:
                    return
                target = sock2 if s is sock1 else sock1
                target.sendall(data)
    except:
        pass

server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
server.bind(("127.0.0.1", LOCAL_PORT))
server.listen(100)
print(f"Local proxy on 127.0.0.1:{LOCAL_PORT} -> {UPSTREAM_HOST}", flush=True)

signal.signal(signal.SIGCHLD, signal.SIG_IGN)

while True:
    client, _ = server.accept()
    threading.Thread(target=handle_client, args=(client,), daemon=True).start()
