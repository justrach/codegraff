"""Check and bootstrap user-level default LSP servers into ~/.graff/lsp/."""
import gzip
import hashlib
import io
import json
import os
from pathlib import Path
import platform
import shlex
import shutil
import subprocess
import sys
import tarfile
import urllib.error
import urllib.parse
import urllib.request

MANAGED_IDS = {"rust", "zig", "python", "typescript", "cpp"}


def runnable(cmd, timeout=5):
    try:
        proc = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=timeout)
        return proc.returncode == 0, (proc.stdout or proc.stderr or "").strip().splitlines()[:1]
    except (OSError, subprocess.SubprocessError):
        return False, []


def stdio_probe(cmd, timeout=6):
    import select
    import time
    body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": "initialize",
                       "params": {"processId": os.getpid(), "rootUri": None, "capabilities": {}}}).encode("utf-8")
    frame = f"Content-Length: {len(body)}\r\n\r\n".encode("ascii") + body
    proc = None
    try:
        proc = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        proc.stdin.write(frame)
        proc.stdin.flush()
        buf, fd, deadline = bytearray(), proc.stdout.fileno(), time.monotonic() + timeout
        while time.monotonic() < deadline and len(buf) < 65536:
            wait = max(0.05, deadline - time.monotonic())
            ready, _, _ = select.select([proc.stdout], [], [], wait)
            if not ready:
                break
            chunk = os.read(fd, 4096)
            if not chunk:
                break
            buf.extend(chunk)
            if b'"capabilities"' in buf:
                return True
        return b'"capabilities"' in buf
    except (OSError, subprocess.SubprocessError):
        return False
    finally:
        if proc is not None and proc.poll() is None:
            proc.terminate()
            try:
                proc.wait(timeout=1)
            except subprocess.SubprocessError:
                proc.kill()


def find_exe(names, extra_dirs=(), version_arg="--version", probe_stdio=False):
    seen = set()
    candidates = [Path(d) for d in extra_dirs if d]
    candidates.extend(Path(p) for p in os.environ.get("PATH", "").split(os.pathsep) if p)

    def check(key):
        if probe_stdio:
            return stdio_probe([key, "--stdio"]), ""
        ok, ver = runnable([key, version_arg])
        return ok, (ver[0] if ver else "")

    for name in names:
        hit = shutil.which(name)
        if hit and hit not in seen:
            seen.add(hit)
            ok, ver = check(hit)
            if ok:
                return hit, ver
        for d in candidates:
            p = d / name
            key = str(p)
            if key in seen or not (p.is_file() and os.access(p, os.X_OK)):
                continue
            seen.add(key)
            ok, ver = check(key)
            if ok:
                return key, ver
    return None, ""


def find_node():
    nvm = sorted((Path.home() / ".nvm" / "versions" / "node").glob("*/bin"), reverse=True)
    extra = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", *(str(p) for p in nvm)]
    exe, _ = find_exe(["node"], extra)
    return exe


def node_entry(node_pkg_dir, pkg_name, bin_name):
    pkg_dir = node_pkg_dir / "node_modules" / pkg_name
    pkg_json = pkg_dir / "package.json"
    if not pkg_json.is_file():
        return None
    try:
        meta = json.loads(pkg_json.read_text(encoding="utf-8"))
        bins = meta.get("bin")
        rel = bins if isinstance(bins, str) else (bins.get(bin_name) if isinstance(bins, dict) else None)
        if not isinstance(rel, str) or not rel:
            return None
        target = (pkg_dir / rel).resolve()
        target.relative_to(pkg_dir.resolve())
        return target if target.is_file() else None
    except (OSError, ValueError, RuntimeError):
        return None


def fetch_bytes(url, timeout=60):
    parsed = urllib.parse.urlsplit(url)
    if parsed.scheme != "https":
        raise ValueError(f"refusing non-https url: {url}")
    req = urllib.request.Request(url, headers={"User-Agent": "graff-lsp-setup/1"})
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return resp.read()


def atomic_write(path, data, mode):
    tmp = path.with_name(f".{path.name}.tmp-{os.getpid()}")
    tmp.write_bytes(data)
    os.chmod(tmp, mode)
    os.replace(tmp, path)


def zig_platform():
    sys_name, mach = platform.system(), platform.machine().lower()
    if mach in ("arm64", "aarch64"):
        arch = "aarch64"
    elif mach in ("x86_64", "amd64"):
        arch = "x86_64"
    else:
        return None, None
    if sys_name == "Darwin":
        return f"{arch}-macos", f"{arch}-apple-darwin"
    if sys_name == "Linux":
        return f"{arch}-linux", f"{arch}-unknown-linux-gnu"
    return None, None


def install_zls(bin_dir):
    zig_exe, zig_ver = find_exe(["zig"], ("/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"), version_arg="version")
    zig_arch, _ = zig_platform()
    if not zig_exe or not zig_ver or not zig_arch:
        return None, "", "zig binary or supported host platform unavailable"
    qver = urllib.parse.quote(zig_ver.strip())
    meta = None
    for compat in ("only-runtime", "full"):
        url = f"https://releases.zigtools.org/v1/zls/select-version?zig_version={qver}&compatibility={compat}"
        raw = json.loads(fetch_bytes(url, timeout=20).decode("utf-8"))
        if isinstance(raw, dict) and isinstance(raw.get(zig_arch), dict):
            meta = raw
            break
    if not meta or zig_arch not in meta:
        return None, "", f"no prebuilt zls binary listed for zig {zig_ver} ({zig_arch})"
    asset = meta[zig_arch]
    data = fetch_bytes(asset["tarball"], timeout=90)
    expected = asset.get("shasum", "").lower()
    actual = hashlib.sha256(data).hexdigest().lower()
    if not expected or actual != expected:
        raise ValueError(f"zls sha256 mismatch: expected {expected}, got {actual}")
    zls_bytes = None
    with tarfile.open(fileobj=io.BytesIO(data), mode="r:*") as tf:
        for member in tf.getmembers():
            if member.isfile() and os.path.basename(member.name) == "zls":
                f = tf.extractfile(member)
                if f is not None:
                    zls_bytes = f.read()
                    break
    if not zls_bytes:
        raise ValueError("zls binary missing from archive")
    dest = bin_dir / "zls"
    atomic_write(dest, zls_bytes, 0o755)
    ok, ver = runnable([str(dest), "--version"])
    return (str(dest), (ver[0] if ver else ""), None) if ok else (None, "", "installed zls failed --version")


def install_rust_analyzer(bin_dir):
    _, rust_triple = zig_platform()
    if not rust_triple:
        return None, "", "unsupported host platform for rust-analyzer"
    url = f"https://github.com/rust-lang/rust-analyzer/releases/latest/download/rust-analyzer-{rust_triple}.gz"
    raw = gzip.decompress(fetch_bytes(url, timeout=90))
    dest = bin_dir / "rust-analyzer"
    atomic_write(dest, raw, 0o755)
    ok, ver = runnable([str(dest), "--version"])
    return (str(dest), (ver[0] if ver else ""), None) if ok else (None, "", "installed rust-analyzer failed --version")


def install_node_packages(node_pkg_dir, node_exe, pkgs):
    node_pkg_dir.mkdir(parents=True, exist_ok=True)
    os.chmod(node_pkg_dir, 0o700)
    pkg_json = node_pkg_dir / "package.json"
    if not pkg_json.exists():
        atomic_write(pkg_json, b'{"name":"graff-lsp-packages","private":true}\n', 0o600)
    bun, _ = find_exe(["bun"], (str(Path.home() / ".bun" / "bin"), "/opt/homebrew/bin", "/usr/local/bin"))
    if bun:
        cmd = [bun, "add", "--cwd", str(node_pkg_dir), *pkgs]
    else:
        npm_sib = Path(node_exe).parent / "npm"
        npm = str(npm_sib) if npm_sib.is_file() else find_exe(["npm"], ("/opt/homebrew/bin", "/usr/local/bin"))[0]
        if not npm:
            raise ValueError("neither bun nor npm found to install node LSP packages")
        cmd = [npm, "install", "--prefix", str(node_pkg_dir), "--no-audit", "--no-fund", *pkgs]
    env = os.environ.copy()
    env["PATH"] = f"{Path(node_exe).parent}{os.pathsep}{env.get('PATH', '')}"
    proc = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=env, timeout=120)
    if proc.returncode != 0:
        detail = (proc.stderr or proc.stdout or "").strip().splitlines()[-3:]
        raise ValueError("package install failed: " + " | ".join(detail))


def find_ts_native(node_pkg_dir, node_exe):
    ts_dir = node_pkg_dir / "node_modules" / "typescript"
    get_exe = ts_dir / "lib" / "getExePath.js"
    if not (get_exe.is_file() and node_exe):
        return None, ""
    try:
        proc = subprocess.run(
            [node_exe, "-e", f"import({json.dumps(get_exe.as_uri())}).then(m=>console.log(m.default()))"],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=5,
        )
        exe = proc.stdout.strip().splitlines()[-1] if proc.returncode == 0 and proc.stdout.strip() else ""
        if exe and Path(exe).is_file() and stdio_probe([exe, "--lsp", "--stdio"]):
            ver = json.loads((ts_dir / "package.json").read_text(encoding="utf-8")).get("version", "")
            return exe, f"typescript-go {ver}".strip()
    except (OSError, ValueError, subprocess.SubprocessError):
        pass
    return None, ""


def write_wrapper(bin_dir, name, node_exe, entry_js):
    script = f"#!/bin/sh\nexec {shlex.quote(node_exe)} {shlex.quote(str(entry_js))} \"$@\"\n".encode("utf-8")
    atomic_write(bin_dir / name, script, 0o755)


def write_bin_wrapper(bin_dir, name, cmd):
    quoted = " ".join(shlex.quote(str(c)) for c in cmd)
    atomic_write(bin_dir / name, f"#!/bin/sh\nexec {quoted} \"$@\"\n".encode("utf-8"), 0o755)


def make_entry(id_name, command, extensions, language_id, timeout_ms):
    return {"id": id_name, "command": command, "extensions": extensions,
            "language_id": language_id, "timeout_ms": timeout_ms, "warm_ttl_ms": 30000}


def resolve_settings_path():
    override = os.environ.get("GRAFF_LSP_CONFIG", "").strip()
    if override:
        return Path(override).expanduser()
    return Path.home() / ".graff" / "lsp" / "settings.json"


def main():
    req = json.loads(sys.argv[1]) if len(sys.argv) > 1 else {}
    check_only = bool(req.get("check_only", False))
    settings_path = resolve_settings_path()
    lsp_home = settings_path.parent
    bin_dir = lsp_home / "bin"
    node_pkg_dir = lsp_home / "packages" / "node"
    if not check_only:
        lsp_home.mkdir(mode=0o700, parents=True, exist_ok=True)
        bin_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
        os.chmod(lsp_home, 0o700)
        os.chmod(bin_dir, 0o700)
    node_exe = find_node()
    servers, summary, errors = [], [], []

    def record(id_name, status, source, cmd, version, err=None):
        item = {"id": id_name, "status": status, "source": source, "command": cmd, "version": version}
        if err:
            item["error"] = err
            errors.append(f"{id_name}: {err}")
        summary.append(item)

    # 1. Rust
    ra, ver = find_exe(["rust-analyzer"], (str(bin_dir), str(Path.home() / ".cargo" / "bin")))
    if ra:
        servers.append(make_entry("rust", [ra], [".rs"], "rust", 15000))
        record("rust", "found", "graff" if ra.startswith(str(bin_dir)) else "path", [ra], ver)
    elif check_only:
        record("rust", "missing", "none", None, "")
    else:
        try:
            ra, ver, err = install_rust_analyzer(bin_dir)
            if ra:
                servers.append(make_entry("rust", [ra], [".rs"], "rust", 15000))
                record("rust", "installed", "graff", [ra], ver)
            else:
                record("rust", "failed", "none", None, "", err)
        except Exception as exc:
            record("rust", "failed", "none", None, "", str(exc))

    # 2. Zig
    zls, ver = find_exe(["zls"], (str(bin_dir), "/opt/homebrew/bin", "/usr/local/bin"))
    if zls:
        servers.append(make_entry("zig", [zls], [".zig"], "zig", 10000))
        record("zig", "found", "graff" if zls.startswith(str(bin_dir)) else "path", [zls], ver)
    elif check_only:
        record("zig", "missing", "none", None, "")
    else:
        try:
            zls, ver, err = install_zls(bin_dir)
            if zls:
                servers.append(make_entry("zig", [zls], [".zig"], "zig", 10000))
                record("zig", "installed", "graff", [zls], ver)
            else:
                record("zig", "failed", "none", None, "", err)
        except Exception as exc:
            record("zig", "failed", "none", None, "", str(exc))

    # 3 & 4. Python & TypeScript/JS/JSX/TSX
    py_path, py_ver = find_exe(["pyright-langserver", "basedpyright-langserver"], probe_stdio=True)
    tsgo_path, tsgo_ver = find_exe(["tsgo"], extra_dirs=(str(bin_dir),), version_arg="--version")
    ts_native, ts_native_ver = find_ts_native(node_pkg_dir, node_exe) if not tsgo_path else (None, "")
    ts_path, ts_ver = find_exe(["typescript-language-server"])
    py_entry = node_entry(node_pkg_dir, "pyright", "pyright-langserver") if not py_path else None
    ts_dep = (node_pkg_dir / "node_modules" / "typescript" / "package.json").is_file()
    missing_pkgs = []
    if not py_path and not py_entry:
        missing_pkgs.append("pyright")
    if not tsgo_path and not ts_native and not ts_path and not ts_dep:
        missing_pkgs.append("typescript")
    installed_pkgs = False
    install_err = None
    if missing_pkgs and not check_only:
        if not node_exe:
            install_err = "node runtime not found on PATH or ~/.nvm"
        else:
            try:
                install_node_packages(node_pkg_dir, node_exe, missing_pkgs)
                installed_pkgs = True
                if not py_path:
                    py_entry = node_entry(node_pkg_dir, "pyright", "pyright-langserver")
                if not tsgo_path and not ts_native:
                    ts_native, ts_native_ver = find_ts_native(node_pkg_dir, node_exe)
            except Exception as exc:
                install_err = str(exc)

    if py_path:
        cmd = [py_path, "--stdio"]
        servers.append(make_entry("python", cmd, [".py", ".pyi"], "python", 15000))
        record("python", "found", "path", cmd, py_ver)
    elif py_entry and node_exe:
        if not check_only:
            write_wrapper(bin_dir, "pyright-langserver", node_exe, py_entry)
        cmd = [node_exe, str(py_entry), "--stdio"]
        if stdio_probe(cmd):
            ver = json.loads((node_pkg_dir / "node_modules" / "pyright" / "package.json").read_text(encoding="utf-8")).get("version", "")
            servers.append(make_entry("python", cmd, [".py", ".pyi"], "python", 15000))
            st = "installed" if (installed_pkgs and "pyright" in missing_pkgs) else "found"
            record("python", st, "graff", cmd, str(ver))
        else:
            record("python", "failed", "graff", cmd, "", "pyright-langserver failed stdio initialize probe")
    else:
        record("python", "missing" if check_only else "failed", "none", None, "", install_err)

    ts_exts = [".ts", ".tsx", ".mts", ".cts", ".js", ".jsx", ".mjs", ".cjs"]
    if ts_native:
        cmd = [ts_native, "--lsp", "--stdio"]
        if not check_only:
            write_bin_wrapper(bin_dir, "ts-lsp", cmd)
        servers.append(make_entry("typescript", cmd, ts_exts, "typescript", 15000))
        st = "installed" if (installed_pkgs and "typescript" in missing_pkgs) else "found"
        record("typescript", st, "graff", cmd, ts_native_ver)
    elif tsgo_path:
        cmd = [tsgo_path, "--lsp", "--stdio"]
        servers.append(make_entry("typescript", cmd, ts_exts, "typescript", 15000))
        record("typescript", "found", "path", cmd, tsgo_ver)
    elif ts_path:
        cmd = [ts_path, "--stdio"]
        servers.append(make_entry("typescript", cmd, ts_exts, "typescript", 15000))
        record("typescript", "found", "path", cmd, ts_ver)
    else:
        ts_entry = node_entry(node_pkg_dir, "typescript-language-server", "typescript-language-server")
        tsserver_ok = (node_pkg_dir / "node_modules" / "typescript" / "lib" / "tsserver.js").is_file()
        if ts_entry and node_exe and tsserver_ok:
            if not check_only:
                write_wrapper(bin_dir, "typescript-language-server", node_exe, ts_entry)
            cmd = [node_exe, str(ts_entry), "--stdio"]
            ok, ver = runnable([node_exe, str(ts_entry), "--version"])
            if ok:
                servers.append(make_entry("typescript", cmd, ts_exts, "typescript", 15000))
                record("typescript", "found", "graff", cmd, ver[0] if ver else "")
            else:
                record("typescript", "failed", "graff", cmd, "", "typescript-language-server failed --version")
        else:
            record("typescript", "missing" if check_only else "failed", "none", None, "", install_err or "no compatible typescript LSP found")

    # 5. C / C++
    clangd, ver = find_exe(["clangd"], (str(bin_dir), "/opt/homebrew/opt/llvm/bin", "/usr/bin"))
    if clangd:
        cmd = [clangd, "--background-index=false"]
        servers.append(make_entry("cpp", cmd, [".c", ".h", ".cpp", ".hpp", ".cc", ".cxx"], "cpp", 10000))
        record("cpp", "found", "path", cmd, ver)
    else:
        record("cpp", "missing", "none", None, "")

    if not check_only:
        custom = []
        if settings_path.is_file():
            try:
                old = json.loads(settings_path.read_text(encoding="utf-8")).get("lsp", {}).get("servers", [])
                custom = [s for s in old if isinstance(s, dict) and s.get("id") not in MANAGED_IDS]
            except (OSError, ValueError, TypeError):
                custom = []
        merged = (servers + custom)[:16]
        body = json.dumps({"lsp": {"servers": merged}}, indent=2) + "\n"
        atomic_write(settings_path, body.encode("utf-8"), 0o600)

    out = {"version": 1, "check_only": check_only, "settings_path": str(settings_path),
           "servers": summary, "errors": errors}
    print(json.dumps(out, ensure_ascii=True, separators=(",", ":")))
    return 1 if (not check_only and errors) else 0


if __name__ == "__main__":
    raise SystemExit(main())
