#!/usr/bin/env python3
"""Static download host for Remote Pi Android builds (self-hosted).

Serves the app APK + its update manifest so the app can update itself
in-place. Deliberately tiny: Python stdlib only, no dependencies, no
framework — the files are static and the traffic is one user.

Layout under ROOT (default /var/lib/remote-pi-downloads):
    app/latest.json     the update manifest the app polls
    app/RemotePi.apk    the signed release APK

Routes:
    GET /healthz                 -> 200 "ok"
    GET /downloads/app/<file>    -> file from ROOT/app/

Security: only files directly under the configured product directories are
served (no traversal), a strict allow-list of names is enforced for the
manifest, and everything is read-only. Uploads are intentionally NOT
supported — the release step copies files in over SSH as the service user.
"""

from __future__ import annotations

import os
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ROOT = Path(os.environ.get("REMOTE_PI_DOWNLOADS_DIR", "/var/lib/remote-pi-downloads"))


def _env_port() -> int:
    """Port from the environment, falling back to 3210 on anything unusable.

    A typo'd env var must not take the service down at boot (systemd would
    just restart-loop it); log and use the default instead.
    """
    raw = os.environ.get("REMOTE_PI_DOWNLOADS_PORT", "3210")
    try:
        port = int(raw)
    except ValueError:
        sys.stderr.write(f"[downloads] bad port {raw!r}, using 3210\n")
        return 3210
    if not (1 <= port <= 65535):
        sys.stderr.write(f"[downloads] port {port} out of range, using 3210\n")
        return 3210
    return port


PORT = _env_port()
# Bound to all interfaces on purpose: the VPS serves this to the phone over
# its public IP, so it cannot listen on loopback. Narrow it with
# REMOTE_PI_DOWNLOADS_HOST if the host ever sits behind a local proxy.
HOST = os.environ.get("REMOTE_PI_DOWNLOADS_HOST", "0.0.0.0")  # noqa: S104

# product -> directory under ROOT. Add a row when another product ships.
PRODUCTS = {
    "app": ROOT / "app",
}

CONTENT_TYPES = {
    ".apk": "application/vnd.android.package-archive",
    ".json": "application/json; charset=utf-8",
    ".txt": "text/plain; charset=utf-8",
}

# Only these basenames are ever served, per product. A stray file dropped in
# the directory (editor backup, .swp, a previous release) stays unreachable.
ALLOWED = {
    "app": {"latest.json", "RemotePi.apk", "SHA256SUMS"},
}


class Handler(BaseHTTPRequestHandler):
    server_version = "rp-downloads/1.0"

    def do_GET(self) -> None:  # noqa: N802 (stdlib naming)
        path = self.path.split("?", 1)[0]

        if path in ("/healthz", "/"):
            self._send_bytes(200, b"ok\n", "text/plain; charset=utf-8")
            return

        parts = [p for p in path.split("/") if p]
        if len(parts) != 3 or parts[0] != "downloads":
            self._not_found()
            return

        product, filename = parts[1], parts[2]
        directory = PRODUCTS.get(product)
        if directory is None:
            self._not_found()
            return

        # Reject anything path-like before it ever touches the filesystem.
        if filename != os.path.basename(filename) or filename.startswith("."):
            self._not_found()
            return
        if filename not in ALLOWED.get(product, set()):
            self._not_found()
            return

        target = directory / filename
        # Defense in depth: resolve and confirm we stayed inside the product
        # directory (symlink escape).
        try:
            resolved = target.resolve(strict=True)
            resolved.relative_to(directory.resolve(strict=True))
        except (OSError, ValueError):
            self._not_found()
            return
        if not resolved.is_file():
            self._not_found()
            return

        try:
            data = resolved.read_bytes()
        except OSError:
            self._send_bytes(500, b"read error\n", "text/plain; charset=utf-8")
            return

        ctype = CONTENT_TYPES.get(resolved.suffix, "application/octet-stream")
        self._send_bytes(200, data, ctype, download_name=filename)

    def _send_bytes(
        self,
        status: int,
        body: bytes,
        content_type: str,
        download_name: str | None = None,
    ) -> None:
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        # The manifest must never be cached: the whole point is that a freshly
        # published version is visible on the next launch.
        if content_type.startswith("application/json"):
            self.send_header("Cache-Control", "no-store, must-revalidate")
        else:
            self.send_header("Cache-Control", "public, max-age=300")
        if download_name:
            self.send_header(
                "Content-Disposition", f'attachment; filename="{download_name}"'
            )
        self.end_headers()
        self.wfile.write(body)

    def _not_found(self) -> None:
        self._send_bytes(404, b"not found\n", "text/plain; charset=utf-8")

    def log_message(self, format: str, *args) -> None:  # noqa: A002
        # Access log to stderr (journald); timestamped by the journal.
        # Signature must match BaseHTTPRequestHandler (param named `format`).
        sys.stderr.write(f"{self.address_string()} - {format % args}\n")


def main() -> None:
    for name, directory in PRODUCTS.items():
        directory.mkdir(parents=True, exist_ok=True)
        sys.stderr.write(f"[downloads] product {name}: {directory}\n")
    sys.stderr.write(f"[downloads] listening on {HOST}:{PORT}\n")
    ThreadingHTTPServer((HOST, PORT), Handler).serve_forever()


if __name__ == "__main__":
    main()
