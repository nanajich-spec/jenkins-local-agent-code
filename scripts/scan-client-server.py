#!/usr/bin/env python3
"""
Simple HTTP file server for distributing the security scan client script.
Serves files from /opt/scan-client-server/ on port 9090.
No HTTPS redirects, no directory listing tricks.
"""

import http.server
import socketserver
import os
import sys

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 9090
SERVE_DIR = "/opt/scan-client-server"

class ScanClientHandler(http.server.BaseHTTPRequestHandler):
    """Custom handler that serves files without redirect issues."""

    def do_GET(self):
        path = self.path.strip("/")
        if path == "" or path == "index.html":
            self._serve_file("index.html", "text/html")
        elif path == "scan":
            self._serve_file("scan", "text/plain")
        else:
            self.send_error(404, "Not Found")

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
