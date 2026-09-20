"""Stands in for cilex-vision to prove the enrolment chain end to end.
Logs every request line + the X-Watchtower-Station header, and the POST /client/stations body."""
import base64, http.server, json, socketserver, sys, time

LOG = open(sys.argv[1], "a", buffering=1)

def jwt(role):
    def b64(o):
        return base64.urlsafe_b64encode(json.dumps(o).encode()).rstrip(b"=").decode()
    return f'{b64({"alg":"HS256","typ":"JWT"})}.{b64({"username":"admin","role":role,"camera_scope":[],"exp":int(time.time())+36000})}.sig'

class H(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def log_message(self, *a): pass
    def _body(self):
        n = int(self.headers.get("Content-Length") or 0)
        return self.rfile.read(n) if n else b""
    def _send(self, code, obj):
        b = json.dumps(obj).encode()
        self.send_response(code); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)
    def do_POST(self):
        body = self._body()
        hdr = self.headers.get("X-Watchtower-Station")
        LOG.write(f"POST {self.path}  X-Watchtower-Station={hdr!r}\n")
        if self.path == "/auth/login":
            return self._send(200, {"access_token": jwt("admin")})
        if self.path == "/client/stations":
            LOG.write(f"  ENROL BODY: {body.decode('utf-8','replace')}\n")
            return self._send(201, {"station_id": "stn-test", "host": json.loads(body)["host"],
                                    "token": "cvst_PROVEN_BY_TEST"})
        return self._send(200, {})
    def do_GET(self):
        self._body()
        return self._send(200, {"cameras": [], "streams": []})
class S(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True; allow_reuse_address = True
S(("127.0.0.1", 8127), H).serve_forever()
