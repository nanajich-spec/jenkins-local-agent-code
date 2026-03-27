#!/usr/bin/env python3
"""
Simple HTTP file server for distributing the security scan client script.
Serves files from /opt/scan-client-server/ on port 9090.
Also accepts source code uploads (tar.gz) via POST /upload for remote scanning.
"""

import http.server
import socketserver
import os
import sys
import json
import time
import shutil

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 9090
SERVE_DIR = "/opt/scan-client-server"
UPLOAD_DIR = "/opt/scan-uploads"

# Ensure upload directory exists
os.makedirs(UPLOAD_DIR, exist_ok=True)

class ScanClientHandler(http.server.BaseHTTPRequestHandler):
    """Custom handler that serves files and accepts source code uploads."""

    def do_GET(self):
        path = self.path.strip("/")
        client_ip = self.client_address[0] if self.client_address else "unknown"
        print(f"[GET] path=/{path} client={client_ip}")
        if path == "" or path == "index.html":
            self._serve_file("index.html", "text/html")
        elif path == "scan":
            print(f"[SCAN CLIENT DOWNLOAD] client={client_ip} — serving scan client script")
            self._serve_file("scan", "text/plain")
        else:
            self.send_error(404, "Not Found")

    def do_POST(self):
        path = self.path.strip("/")
        if path == "upload":
            self._handle_upload()
        elif path == "cleanup":
            self._handle_cleanup()
        else:
            self.send_error(404, "Not Found")

    def _handle_upload(self):
        """Receive a tar.gz of user source code, store it for Jenkins to scan."""
        try:
            content_length = int(self.headers.get("Content-Length", 0))
            client_ip = self.client_address[0] if self.client_address else "unknown"
            scan_id = self.headers.get("X-Scan-ID", f"upload-{int(time.time())}")

            print(f"[UPLOAD START] scan_id={scan_id} client={client_ip} content_length={content_length}")

            if content_length == 0:
                print(f"[UPLOAD REJECTED] scan_id={scan_id} reason=no_data")
                self._json_response(400, {"error": "No data received"})
                return
            if content_length > 1024 * 1024 * 1024:  # 1GB limit
                print(f"[UPLOAD REJECTED] scan_id={scan_id} reason=too_large size={content_length}")
                self._json_response(413, {"error": "Upload too large (max 1GB)"})
                return

            upload_path = os.path.join(UPLOAD_DIR, scan_id)
            os.makedirs(upload_path, exist_ok=True)

            tar_path = os.path.join(upload_path, "source.tar.gz")
            received = 0
            start_time = time.time()
            with open(tar_path, "wb") as f:
                while received < content_length:
                    chunk_size = min(65536, content_length - received)
                    chunk = self.rfile.read(chunk_size)
                    if not chunk:
                        break
                    f.write(chunk)
                    received += len(chunk)
                    # Log progress for large uploads (every 10MB)
                    if received % (10 * 1024 * 1024) < chunk_size:
                        elapsed = time.time() - start_time
                        pct = int(received * 100 / content_length) if content_length > 0 else 0
                        print(f"[UPLOAD PROGRESS] scan_id={scan_id} {pct}% ({received}/{content_length} bytes, {elapsed:.1f}s)")

            elapsed = time.time() - start_time
            file_size = os.path.getsize(tar_path)
            print(f"[UPLOAD COMPLETE] scan_id={scan_id} size={file_size} bytes elapsed={elapsed:.1f}s path={tar_path}")

            self._json_response(200, {
                "status": "ok",
                "scan_id": scan_id,
                "upload_path": upload_path,
                "size": file_size
            })
        except Exception as e:
            print(f"[UPLOAD ERROR] scan_id={scan_id} error={e}")
            import traceback
            traceback.print_exc()
            self._json_response(500, {"error": str(e)})

    def _handle_cleanup(self):
        """Remove uploaded source code after scan completes."""
        try:
            content_length = int(self.headers.get("Content-Length", 0))
            body = self.rfile.read(content_length).decode() if content_length > 0 else "{}"
            data = json.loads(body)
            scan_id = data.get("scan_id", "")
            if scan_id:
                path = os.path.join(UPLOAD_DIR, scan_id)
                if os.path.isdir(path):
                    shutil.rmtree(path, ignore_errors=True)
                    print(f"[CLEANUP] Removed {path}")
            self._json_response(200, {"status": "cleaned"})
        except Exception as e:
            self._json_response(500, {"error": str(e)})

    def _json_response(self, code, data):
        body = json.dumps(data).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _serve_file(self, filename, content_type):
        filepath = os.path.join(SERVE_DIR, filename)
        if not os.path.isfile(filepath):
            self.send_error(404, f"File not found: {filename}")
            return
        with open(filepath, "rb") as f:
            content = f.read()
        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(content)))
        self.send_header("Content-Disposition", f'inline; filename="{filename}"')
        self.end_headers()
        self.wfile.write(content)

    def log_message(self, format, *args):
        """Minimal logging."""
        print(f"[{self.log_date_time_string()}] {args[0]}")

class ReusableTCPServer(socketserver.TCPServer):
    allow_reuse_address = True
    allow_reuse_port = True

    def server_bind(self):
        import socket
        self.socket.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        try:
            self.socket.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEPORT, 1)
        except (AttributeError, OSError):
            pass
        super().server_bind()

class ReusableHTTPServer(ReusableTCPServer, http.server.HTTPServer):
    pass

if __name__ == "__main__":
    os.chdir(SERVE_DIR)
    server = ReusableHTTPServer(("0.0.0.0", PORT), ScanClientHandler)
    print(f"Scan client server running on port {PORT}")
    print(f"  Script:  http://0.0.0.0:{PORT}/scan")
    print(f"  Landing: http://0.0.0.0:{PORT}/")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nShutting down.")
        server.shutdown()
