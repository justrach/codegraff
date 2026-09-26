#!/usr/bin/env python3
"""Local reference edge for `graff keys` (harness ADR 0005, contract v1.1).

Dev-mode auth like the Harness edge: the bearer is the user id. Mutating
requests must carry a valid Ed25519 signature over
`method|path|sha256hex(body)|tsMs|deviceId` from an enrolled device, within
60 s and never replayed. Items are compare-and-swap on If-Match, leases block
other writers, and PUTs must carry the current keyEpoch.

    python3 scripts/vault_edge_dev.py --port 27641
"""
import argparse, base64, hashlib, json, threading, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey

LOCK = threading.Lock()
VAULTS = {}  # userId -> {"epoch", "devices": {id: dict}, "items": {"a/s": dict}}
SEEN = set()


def b64d(s):
    return base64.urlsafe_b64decode(s + "=" * (-len(s) % 4))


def vault(user):
    return VAULTS.setdefault(user, {"epoch": 1, "devices": {}, "items": {}})


class Edge(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def reply(self, status, obj=None):
        body = b"" if obj is None else json.dumps(obj).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def handle_any(self, method):
        auth = self.headers.get("Authorization", "")
        if not auth.startswith("Bearer ") or not auth[7:].strip():
            return self.reply(401, {"error": "unauthorized"})
        user = auth[7:].strip().split("@")[0]
        body = self.rfile.read(int(self.headers.get("Content-Length") or 0))
        data = json.loads(body) if body else {}
        dev_id = self.headers.get("X-Vault-Device", "")
        path = self.path
        with LOCK:
            v = vault(user)
            registering = method == "POST" and path == "/vault/devices"
            if method != "GET" and not registering and not self.verified(v, method, path, body, dev_id):
                return self.reply(401, {"error": "bad_signature"})
            return self.route(v, user, method, path, data, dev_id)

    def verified(self, v, method, path, body, dev_id):
        d = v["devices"].get(dev_id)
        if not d or d["status"] != "enrolled":
            return False
        try:
            ts = int(self.headers.get("X-Vault-Timestamp", ""))
            sig = b64d(self.headers.get("X-Vault-Signature", ""))
        except ValueError:
            return False
        if abs(time.time() * 1000 - ts) > 60_000 or (dev_id, ts, sig) in SEEN:
            return False
        msg = f"{method}|{path}|{hashlib.sha256(body).hexdigest()}|{ts}|{dev_id}".encode()
        try:
            Ed25519PublicKey.from_public_bytes(b64d(d["signingKey"])).verify(sig, msg)
        except Exception:
            return False
        SEEN.add((dev_id, ts, sig))
        return True

    def route(self, v, user, method, path, data, dev_id):
        devs, items = v["devices"], v["items"]
        if method == "GET" and path == "/vault":
            me = devs.get(dev_id, {})
            heads = [{"agent": k.split("/")[0], "slot": k.split("/")[1], **{f: it[f] for f in ("version", "keyEpoch", "kind", "status")}, "leaseHolder": it.get("lease")} for k, it in items.items()]
            pub = [{f: d[f] for f in ("deviceId", "name", "publicKey", "signingKey", "status")} for d in devs.values()]
            return self.reply(200, {"userId": user, "keyEpoch": v["epoch"], "devices": pub, "wrappedKey": me.get("wrappedKey"), "items": heads})
        if method == "POST" and path == "/vault/devices":
            bootstrap = not any(d["status"] == "enrolled" for d in devs.values()) and data.get("wrappedKey")
            devs[data["deviceId"]] = {**{f: data[f] for f in ("deviceId", "name", "publicKey", "signingKey")}, "status": "enrolled" if bootstrap else "pending", "wrappedKey": data.get("wrappedKey") if bootstrap else None}
            return self.reply(200, {"status": devs[data["deviceId"]]["status"]})
        if path.startswith("/vault/devices/"):
            rest = path[len("/vault/devices/"):]
            if rest.endswith("/approve"):
                d = devs.get(rest[: -len("/approve")])
                if not d:
                    return self.reply(404, {})
                d.update(status="enrolled", wrappedKey=data["wrappedKey"])
                return self.reply(200, {"status": "enrolled"})
            if method == "DELETE":
                devs.pop(rest, None)
                return self.reply(204)
        if path == "/vault/rotate":
            enrolled = {i for i, d in devs.items() if d["status"] == "enrolled"}
            if data.get("keyEpoch") != v["epoch"] + 1:
                return self.reply(409, {"error": "stale_epoch"})
            if set(data["wrappedKeys"]) != enrolled:
                return self.reply(400, {"error": "wrappedKeys must cover exactly the enrolled devices"})
            for i in enrolled:
                devs[i]["wrappedKey"] = data["wrappedKeys"][i]
            v["epoch"] = data["keyEpoch"]
            return self.reply(200, {"keyEpoch": v["epoch"]})
        if path.startswith("/vault/items/"):
            parts = path[len("/vault/items/"):].split("/")
            key, action = "/".join(parts[:2]), (parts[2] if len(parts) > 2 else "")
            it = items.get(key)
            if action == "lease":
                it = items.setdefault(key, {"version": 0, "keyEpoch": v["epoch"], "kind": "rotating", "status": "ok"})
                if method == "DELETE":
                    if it.get("lease") == dev_id:
                        it["lease"] = None
                    return self.reply(204)
                if it.get("lease") not in (None, dev_id) and it.get("leaseUntil", 0) > time.time():
                    return self.reply(409, {"error": "lease_held"})
                it.update(lease=dev_id, leaseUntil=time.time() + min(int(data.get("ttlSeconds", 60)), 60))
                return self.reply(200, {"leaseHolder": dev_id, "version": it["version"]})
            if action == "status":
                if not it:
                    return self.reply(404, {})
                it["status"] = data["status"]
                return self.reply(200, {"status": it["status"]})
            if method == "GET":
                if not it or it["version"] == 0:
                    return self.reply(404, {})
                a, s = key.split("/")
                return self.reply(200, {"agent": a, "slot": s, **{f: it[f] for f in ("version", "keyEpoch", "kind", "status", "nonce", "ciphertext")}})
            if method == "PUT":
                it = items.setdefault(key, {"version": 0, "keyEpoch": v["epoch"], "kind": data["kind"], "status": "ok"})
                if it.get("lease") not in (None, dev_id) and it.get("leaseUntil", 0) > time.time():
                    return self.reply(409, {"error": "lease_held"})
                if data.get("keyEpoch") != v["epoch"]:
                    return self.reply(409, {"error": "stale_epoch"})
                if int(self.headers.get("If-Match", "-1")) != it["version"]:
                    return self.reply(412, {"currentVersion": it["version"]})
                it.update(version=it["version"] + 1, keyEpoch=v["epoch"], **{f: data[f] for f in ("kind", "status", "nonce", "ciphertext")})
                return self.reply(200, {"version": it["version"]})
        return self.reply(404, {})

    def do_GET(self):
        self.handle_any("GET")

    def do_POST(self):
        self.handle_any("POST")

    def do_PUT(self):
        self.handle_any("PUT")

    def do_DELETE(self):
        self.handle_any("DELETE")


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=27641)
    port = ap.parse_args().port
    print(f"vault dev edge on http://127.0.0.1:{port}", flush=True)
    ThreadingHTTPServer(("127.0.0.1", port), Edge).serve_forever()
