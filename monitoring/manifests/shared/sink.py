# Alertmanager webhook receiver: one JSON line per delivery on stdout, which Alloy ships to Loki
# and scripts/test-alert.sh reads back. Stdlib only, so there is no dependency to audit.
import datetime
import http.server
import json


class Handler(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        raw = self.rfile.read(int(self.headers.get("content-length", 0)))
        try:
            payload = json.loads(raw)
        except ValueError:
            payload = {"unparsed": raw.decode("utf-8", "replace")}
        print(
            json.dumps(
                {
                    "received_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
                    "path": self.path,
                    "payload": payload,
                }
            ),
            flush=True,
        )
        self.send_response(200)
        self.end_headers()

    def do_GET(self):
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b"ok")

    def log_message(self, *args):
        pass


http.server.ThreadingHTTPServer(("", 8080), Handler).serve_forever()
