#!/usr/bin/env python3
"""End-to-end `graff keys` over real HTTP: two devices, one local dev edge.

Device A bootstraps the vault and pushes its xai login; device B enrolls,
waits, gets approved, and pulls it; a forged signature is rejected; removing
B rotates the key and A still reads everything.

    python3 scripts/test-graff-keys-e2e.py [path/to/graff]
    EDGE_URL=http://127.0.0.1:27650 python3 scripts/test-graff-keys-e2e.py
"""
import json, os, socket, subprocess, sys, tempfile, time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GRAFF = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, "zig-out", "bin", "graff")


def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    p = s.getsockname()[1]
    s.close()
    return p


def main():
    # EDGE_URL points the test at an already running edge (e.g. the Harness
    # VaultRoom under `wrangler dev`); otherwise a local reference edge starts.
    edge_url = os.environ.get("EDGE_URL")
    edge = None
    if not edge_url:
        port = free_port()
        edge = subprocess.Popen([sys.executable, os.path.join(ROOT, "scripts", "vault_edge_dev.py"), "--port", str(port)], stdout=subprocess.PIPE, text=True)
        edge.stdout.readline()
        edge_url = f"http://127.0.0.1:{port}"
    # Each run gets its own dev-mode user so reruns against a live edge start clean.
    user = f"e2e-{os.getpid()}-{int(time.time())}"
    tmp = tempfile.mkdtemp(prefix="graff-keys-e2e-")
    try:
        def dev(name):
            home = os.path.join(tmp, name)
            os.makedirs(os.path.join(home, ".xai", "credentials"), exist_ok=True)
            env = {**os.environ, "HOME": home, "HARNESS_BEARER": user, "HARNESS_EDGE_URL": edge_url, "GRAFF_VAULT_DEVICE_FILE": os.path.join(home, "device.key")}

            def run(*args, stdin=None, ok=True):
                r = subprocess.run([GRAFF, "keys", *args], env=env, input=stdin, capture_output=True, text=True, timeout=60)
                if ok and r.returncode != 0:
                    raise SystemExit(f"FAIL graff keys {' '.join(args)} ({name}): exit {r.returncode}\n{r.stdout}{r.stderr}")
                return r
            return home, run

        home_a, a = dev("a")
        home_b, b = dev("b")
        xai = os.path.join(home_a, ".xai", "credentials", "graff-oauth.json")
        with open(xai, "w") as f:
            json.dump({"access_token": "xai-access", "refresh_token": "xai-refresh", "expires_at": 1}, f)

        assert "enrolled" in a("enable", "--name", "laptop").stdout, "A should bootstrap"
        assert "pushed (v1)" in a("push", "xai").stdout
        out = b("enable", "--name", "vps").stdout
        assert "waiting for approval" in out, out
        b_id = out.split("(")[1].split(",")[0]
        denied = b("pull", "xai", ok=False)
        assert denied.returncode != 0, "a pending device must not read the vault"
        assert "✓ approved" in a("approve", b_id, "--yes").stdout
        assert "pulled (v1)" in b("pull", "xai").stdout
        pulled = os.path.join(home_b, ".xai", "credentials", "graff-oauth.json")
        assert json.load(open(pulled))["refresh_token"] == "xai-refresh"
        assert oct(os.stat(pulled).st_mode & 0o777) == "0o600", oct(os.stat(pulled).st_mode)
        assert oct(os.stat(os.path.join(home_a, "device.key")).st_mode & 0o777) == "0o600"

        assert "✓ stored claude/default" in a("put", "claude/default", stdin="opaque-bytes").stdout
        assert b("get", "claude/default").stdout == "opaque-bytes"

        # Forge: B's device id with a fresh key file must be refused.
        forged = os.path.join(tmp, "forged.key")
        with open(os.path.join(home_b, "device.key")) as f:
            real = f.read().strip()
        with open(os.path.join(home_a, "device.key")) as f:
            other_secret = f.read().strip().split(":", 1)[1]
        with open(forged, "w") as f:
            f.write(real.split(":")[0] + ":" + other_secret)
        env_f = {**os.environ, "HOME": home_b, "HARNESS_BEARER": user, "HARNESS_EDGE_URL": edge_url, "GRAFF_VAULT_DEVICE_FILE": forged}
        r = subprocess.run([GRAFF, "keys", "push", "xai"], env=env_f, capture_output=True, text=True, timeout=60)
        assert r.returncode != 0, "a forged signature must be rejected"

        assert "rotated the vault key" in a("remove", b_id, "--yes").stdout
        status = json.loads(a("status", "--json").stdout)
        assert status["keyEpoch"] == 2, status
        assert "pulled" in a("pull", "xai").stdout
        assert a("get", "claude/default").stdout == "opaque-bytes"
        assert b("pull", "xai", ok=False).returncode != 0, "a removed device must not read the vault"
        print("graff keys e2e: OK (bootstrap, approve, push/pull, put/get, forged signature, remove+rotate, 0600 files)")
    finally:
        if edge:
            edge.terminate()


if __name__ == "__main__":
    main()
