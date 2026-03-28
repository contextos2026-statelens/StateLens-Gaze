from __future__ import annotations

import argparse
import json
import threading
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

from .state import AppState


APP_STATE = AppState()
SSE_CLIENTS: set = set()
SSE_LOCK = threading.Lock()
STATIC_DIR = Path(__file__).resolve().parent.parent / "static"


def run() -> None:
    parser = argparse.ArgumentParser(description="JINS MEME ES realtime gaze dashboard")
    parser.add_argument("--host", default="0.0.0.0")
    parser.add_argument("--port", default=8765, type=int)
    args = parser.parse_args()

    server = ThreadingHTTPServer((args.host, args.port), RequestHandler)
    print(f"Server running on http://{args.host}:{args.port}")
    print("POST sensor JSON to /api/ingest and open / on PC or iPhone.")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nStopping server...")
    finally:
        server.server_close()


class RequestHandler(BaseHTTPRequestHandler):
    server_version = "JinsMemeLocal/0.1"

    def do_OPTIONS(self) -> None:
        self.send_response(HTTPStatus.NO_CONTENT)
        self._write_common_headers()
        self.end_headers()

    def do_GET(self) -> None:
        parsed = urlparse(self.path)
        if parsed.path == "/":
            self._serve_file("index.html", "text/html; charset=utf-8")
            return
        if parsed.path == "/app.js":
            self._serve_file("app.js", "application/javascript; charset=utf-8")
            return
        if parsed.path == "/styles.css":
            self._serve_file("styles.css", "text/css; charset=utf-8")
            return
        if parsed.path == "/api/state":
            self._send_json(APP_STATE.snapshot())
            return
        if parsed.path == "/api/stream":
            self._handle_sse()
            return
        if parsed.path == "/api/mock":
            params = parse_qs(parsed.query)
            payload = build_mock_payload(params)
            state = APP_STATE.ingest(payload)
            broadcast(state)
            self._send_json(state)
            return
        self.send_error(HTTPStatus.NOT_FOUND)

    def do_POST(self) -> None:
        parsed = urlparse(self.path)
        payload = self._read_json_body()

        if parsed.path == "/api/ingest":
            state = APP_STATE.ingest(payload)
            broadcast(state)
            self._send_json(state)
            return

        if parsed.path == "/api/calibration/sample":
            target_x = float(payload["targetX"])
            target_y = float(payload["targetY"])
            response = APP_STATE.add_calibration_sample(target_x, target_y)
            self._send_json(response)
            return

        if parsed.path == "/api/calibration/solve":
            response = APP_STATE.solve_calibration()
            self._send_json(response)
            return

        if parsed.path == "/api/calibration/reset":
            response = APP_STATE.clear_calibration()
            self._send_json(response)
            return

        self.send_error(HTTPStatus.NOT_FOUND)

    def log_message(self, format: str, *args) -> None:
        return

    def _read_json_body(self) -> dict:
        length = int(self.headers.get("Content-Length", "0"))
        raw = self.rfile.read(length) if length > 0 else b"{}"
        if not raw:
            return {}
        return json.loads(raw.decode("utf-8"))

    def _send_json(self, payload: dict, status: int = 200) -> None:
        body = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self._write_common_headers(content_type="application/json; charset=utf-8", content_length=len(body))
        self.end_headers()
        self.wfile.write(body)

    def _serve_file(self, filename: str, content_type: str) -> None:
        path = STATIC_DIR / filename
        if not path.exists():
            self.send_error(HTTPStatus.NOT_FOUND)
            return
        body = path.read_bytes()
        self.send_response(HTTPStatus.OK)
        self._write_common_headers(content_type=content_type, content_length=len(body))
        self.end_headers()
        self.wfile.write(body)

    def _handle_sse(self) -> None:
        self.send_response(HTTPStatus.OK)
        self._write_common_headers(content_type="text/event-stream")
        self.send_header("Connection", "keep-alive")
        self.end_headers()

        with SSE_LOCK:
            SSE_CLIENTS.add(self)

        initial = f"data: {json.dumps(APP_STATE.snapshot())}\n\n".encode("utf-8")
        self.wfile.write(initial)
        self.wfile.flush()

        try:
            while True:
                threading.Event().wait(60)
                self.wfile.write(b": keep-alive\n\n")
                self.wfile.flush()
        except Exception:
            pass
        finally:
            with SSE_LOCK:
                SSE_CLIENTS.discard(self)

    def _write_common_headers(self, content_type: str | None = None, content_length: int | None = None) -> None:
        if content_type is not None:
            self.send_header("Content-Type", content_type)
        if content_length is not None:
            self.send_header("Content-Length", str(content_length))
        self.send_header("Cache-Control", "no-store")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")


def broadcast(payload: dict) -> None:
    message = f"data: {json.dumps(payload)}\n\n".encode("utf-8")
    stale = []
    with SSE_LOCK:
        for client in SSE_CLIENTS:
            try:
                client.wfile.write(message)
                client.wfile.flush()
            except Exception:
                stale.append(client)
        for client in stale:
            SSE_CLIENTS.discard(client)


def build_mock_payload(params: dict[str, list[str]]) -> dict:
    horizontal = float(params.get("h", ["0.0"])[0])
    vertical = float(params.get("v", ["0.0"])[0])
    blink = float(params.get("blink", ["0.0"])[0])
    return {
        "horizontal": horizontal,
        "vertical": vertical,
        "blinkStrength": blink,
    }
