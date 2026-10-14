#!/usr/bin/env bash
set -uo pipefail
DATA=/var/lib/pasarguard

# ---- find the panel and its Python, whatever layout the PasarGuard image uses today ----
PANEL_DIR=/code
for d in /code /app /opt/pasarguard /pasarguard /usr/src/app; do
  if [ -f "$d/main.py" ]; then PANEL_DIR="$d"; break; fi
done
for v in "$PANEL_DIR/.venv" /code/.venv /app/.venv /opt/venv /venv; do
  if [ -x "$v/bin/python" ]; then export PATH="$v/bin:$PATH"; export VIRTUAL_ENV="$v"; break; fi
done
export PANEL_DIR
PY="$(command -v python || command -v python3 || echo python)"; export PY
echo "[chost] panel: $PANEL_DIR, python: $PY"
mkdir -p "$DATA/node-certs" /var/lib/pg-node /run /run/nginx /var/log/nginx /var/lib/nginx/body /var/cache/nginx 2>/dev/null
# Railway may hand the service its own PORT; CHOST always answers on 8080 AND on that port,
# so the domain and the health check work in every region whatever the target port is
RW_PORT="${PORT:-8080}"
case "$RW_PORT" in ''|*[!0-9]*) RW_PORT=8080 ;; esac
case "$RW_PORT" in 8000|8100|62050|1000[1-6]) RW_PORT=8080 ;; esac   # never clash with the internal ports
export PORT=8080

# CPUs really given to this service (Railway Metal hosts show every host CPU, which would start dozens of
# nginx workers and eat the memory): read the cgroup limit, fall back to nproc, keep it between 1 and 4
CPUS=""
if [ -r /sys/fs/cgroup/cpu.max ]; then
  read -r q p < /sys/fs/cgroup/cpu.max 2>/dev/null || true
  if [ "${q:-max}" != "max" ] && [ "${p:-0}" -gt 0 ] 2>/dev/null; then CPUS=$(( (q + p - 1) / p )); fi
elif [ -r /sys/fs/cgroup/cpu/cpu.cfs_quota_us ]; then
  q=$(cat /sys/fs/cgroup/cpu/cpu.cfs_quota_us 2>/dev/null); p=$(cat /sys/fs/cgroup/cpu/cpu.cfs_period_us 2>/dev/null)
  if [ "${q:--1}" -gt 0 ] 2>/dev/null && [ "${p:-0}" -gt 0 ] 2>/dev/null; then CPUS=$(( (q + p - 1) / p )); fi
fi
case "$CPUS" in ''|*[!0-9]*) CPUS=$(nproc 2>/dev/null || echo 2) ;; esac
case "$CPUS" in ''|*[!0-9]*|0) CPUS=2 ;; esac
[ "$CPUS" -gt 4 ] && CPUS=4
export GOMAXPROCS="${GOMAXPROCS:-$CPUS}"
NGX_W=$CPUS; [ "$NGX_W" -gt 2 ] && NGX_W=2      # 2 nginx workers carry thousands of connections

# memory really given to this service; small plans (512 MB) must never be killed for running out of memory
MEM_MAX=""
if [ -r /sys/fs/cgroup/memory.max ]; then MEM_MAX=$(cat /sys/fs/cgroup/memory.max 2>/dev/null)
elif [ -r /sys/fs/cgroup/memory/memory.limit_in_bytes ]; then MEM_MAX=$(cat /sys/fs/cgroup/memory/memory.limit_in_bytes 2>/dev/null); fi
case "$MEM_MAX" in ''|max|*[!0-9]*) MEM_MAX="" ;; esac
[ -n "$MEM_MAX" ] && [ "$MEM_MAX" -gt 274877906944 ] && MEM_MAX=""   # "no limit" written as a huge number
export MALLOC_ARENA_MAX=2       # Python uses far less memory with fewer malloc arenas
if [ -n "$MEM_MAX" ]; then export GOMEMLIMIT="${GOMEMLIMIT:-$(( MEM_MAX * 35 / 100 ))B}"; fi   # core gives memory back early

# owner admin/admin is written by bootstrap.py on FIRST boot only
unset SUDO_USERNAME SUDO_PASSWORD

# ---- node secrets: generated once, kept on the volume ----
[ -f "$DATA/node_api_key" ] || "$PY" -c "import uuid;print(uuid.uuid4())" > "$DATA/node_api_key"
if [ ! -f "$DATA/node-certs/cert.pem" ]; then
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 3650 -keyout "$DATA/node-certs/key.pem" -out "$DATA/node-certs/cert.pem" -subj "/CN=localhost" -addext "subjectAltName=IP:127.0.0.1,DNS:localhost" >/dev/null 2>&1
  # fallback for an older openssl: RSA key, then without the SAN option
  [ -s "$DATA/node-certs/cert.pem" ] || openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -keyout "$DATA/node-certs/key.pem" -out "$DATA/node-certs/cert.pem" -subj "/CN=localhost" -addext "subjectAltName=IP:127.0.0.1,DNS:localhost" >/dev/null 2>&1
  [ -s "$DATA/node-certs/cert.pem" ] || openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -keyout "$DATA/node-certs/key.pem" -out "$DATA/node-certs/cert.pem" -subj "/CN=localhost" >/dev/null 2>&1
  [ -s "$DATA/node-certs/cert.pem" ] || echo "[chost] warning: node certificate could not be created"
fi

# ---- unique config paths for this install (kept on the volume) ----
if ! "$PY" /code/genpaths.py; then
  # never stop the deploy: the panel still opens, the next start writes the paths
  echo "[chost] warning: config paths could not be written now"; [ -f "$DATA/inbounds.inc" ] || : > "$DATA/inbounds.inc"
fi

# ---- nginx ----
# the calm "panel is starting" page (written here, so the build never depends on an extra file)
cat > /etc/nginx/chost-wait.html <<'CHOSTWAIT'
<!doctype html>
<html lang="fa" dir="rtl">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta http-equiv="refresh" content="6">
<meta name="robots" content="noindex">
<title>CHOST</title>
<style>
*{box-sizing:border-box}
html,body{margin:0;height:100%}
body{background:#f7f3ea;color:#2a2418;font-family:Tahoma,"Segoe UI",system-ui,-apple-system,sans-serif;display:flex;align-items:center;justify-content:center;padding:24px}
.c{width:100%;max-width:420px;text-align:center;background:#fff;border:1px solid #e7dcc3;border-radius:22px;padding:40px 28px 32px;box-shadow:0 20px 60px -30px rgba(120,90,30,.35)}
.lg{font-family:"Segoe UI",system-ui,sans-serif;font-weight:700;letter-spacing:8px;font-size:22px;color:#a87b28;direction:ltr;padding-left:8px}
.sp{width:46px;height:46px;margin:26px auto 22px;border-radius:50%;border:3px solid #efe4cc;border-top-color:#c39434;animation:r 1s linear infinite}
@keyframes r{to{transform:rotate(360deg)}}
h1{font-size:18px;margin:0 0 10px;font-weight:700}
p{font-size:14px;line-height:1.9;margin:0;color:#6d6250}
.en{direction:ltr;margin-top:18px;padding-top:16px;border-top:1px solid #f0e8d6;font-family:"Segoe UI",system-ui,sans-serif}
.en h1{font-size:15px}.en p{font-size:13px}
</style>
</head>
<body>
<div class="c">
<div class="lg">CHOST</div>
<div class="sp"></div>
<h1>پنل در حال آماده شدن است</h1>
<p>چند لحظه صبر کنید؛ این صفحه خودش تازه می‌شود و پنل را باز می‌کند.</p>
<div class="en"><h1>The panel is starting</h1><p>Please wait a moment. This page refreshes by itself and opens the panel.</p></div>
</div>
</body>
</html>
CHOSTWAIT
# CHOST edge: a built-in backup front door (written here, no extra file). It is used only if nginx
# can not start at all, so the panel, sub links and configs still open on the domain.
cat > /etc/nginx/chost-edge.py <<'CHOSTEDGE'
# CHOST edge: built-in backup front door. Runs only if nginx can not start at all, so the panel,
# the sub links and the 6 configs keep opening on the domain (same routes as nginx).
import asyncio, json, os, socket, sys

DATA = os.getenv("CHOST_DATA", "/var/lib/pasarguard")
PORTS = sorted({int(p) for p in (sys.argv[1:] or ["8080"]) if p.isdigit()})
SLOT_PORT = {"CH-V1-VLESS-WS": 10001, "CH-V2-VMESS-WS": 10002, "CH-V3-VLESS-HU": 10003,
             "CH-G1-VLESS-WS": 10004, "CH-G2-TROJAN-WS": 10005, "CH-G3-VLESS-HU": 10006}
UI = '<script src="/chost-ui.js" defer></script>'
_routes = {"t": 0, "m": {}}

def routes():
    try:
        mt = os.path.getmtime(f"{DATA}/paths.json")
        if mt != _routes["t"]:
            with open(f"{DATA}/paths.json") as f: p = json.load(f)
            _routes["m"] = {v: SLOT_PORT[k] for k, v in p.items() if k in SLOT_PORT and isinstance(v, str)}
            _routes["t"] = mt
    except Exception: pass
    return _routes["m"]

def read(path, default=b""):
    try:
        with open(path, "rb") as f: return f.read()
    except Exception: return default

def simple(status, body, ctype="text/plain; charset=utf-8", extra=""):
    if isinstance(body, str): body = body.encode()
    return (f"HTTP/1.1 {status}\r\nContent-Type: {ctype}\r\nContent-Length: {len(body)}\r\n"
            f"Cache-Control: no-store\r\n{extra}Connection: close\r\n\r\n").encode() + body

def wait_page():
    return simple("503 Service Unavailable", read("/etc/nginx/chost-wait.html", b"<h1>CHOST</h1>"), "text/html; charset=utf-8", "Retry-After: 6\r\n")

def set_headers(lines, drop, add):
    out = [l for l in lines if l.split(":", 1)[0].strip().lower() not in drop]
    return out + add

async def pipe(r, w):
    try:
        while True:
            b = await r.read(65536)
            if not b: break
            w.write(b); await w.drain()
    except Exception: pass
    finally:
        try: w.close()
        except Exception: pass

async def handle(cr, cw):
    try:
        head = await asyncio.wait_for(cr.readuntil(b"\r\n\r\n"), 60)
    except Exception:
        cw.close(); return
    try:
        text = head.decode("latin-1")
        lines = text.split("\r\n")[:-2]
        method, target, _ = (lines[0].split(" ") + ["", ""])[:3]
        path = target.split("?", 1)[0]
        hdr = {l.split(":", 1)[0].strip().lower(): l.split(":", 1)[1].strip() for l in lines[1:] if ":" in l}
        peer = (cw.get_extra_info("peername") or ["0.0.0.0"])[0]
        if path == "/healthz":
            cw.write(simple("200 OK", "ok")); await cw.drain(); cw.close(); return
        if path == "/":
            cw.write(simple("302 Found", "", extra="Location: /dashboard/\r\n")); await cw.drain(); cw.close(); return
        if path == "/chost-ui.js":
            cw.write(simple("200 OK", read("/etc/nginx/chost-ui.js"), "application/javascript; charset=utf-8")); await cw.drain(); cw.close(); return
        upgrade = "upgrade" in hdr.get("connection", "").lower() or "upgrade" in hdr
        port = routes().get(path) or (8100 if path.startswith("/chost/") else 8000)
        dash = path.startswith("/dashboard") and method == "GET" and not upgrade
        if dash and os.path.exists("/run/chost-starting"):
            cw.write(wait_page()); await cw.drain(); cw.close(); return
        add = [f"X-Real-IP: {peer}", f"X-Forwarded-For: {peer}", "X-Forwarded-Proto: https"]
        drop = {"x-real-ip", "x-forwarded-for", "x-forwarded-proto"}
        if not upgrade:
            drop |= {"connection", "keep-alive", "proxy-connection"}; add.append("Connection: close")
        if dash: drop.add("accept-encoding")
        first = lines[0].rsplit(" ", 1)[0] + (" HTTP/1.0" if dash else " " + lines[0].rsplit(" ", 1)[-1])
        req = "\r\n".join([first] + set_headers(lines[1:], drop, add)) + "\r\n\r\n"
        try:
            br, bw = await asyncio.wait_for(asyncio.open_connection("127.0.0.1", port), 5)
        except Exception:
            cw.write(wait_page() if port in (8000, 8100) else simple("502 Bad Gateway", "")); await cw.drain(); cw.close(); return
        bw.write(req.encode("latin-1")); await bw.drain()
        if dash:
            data = b""
            try:
                while True:
                    b = await asyncio.wait_for(br.read(65536), 120)
                    if not b: break
                    data += b
            except Exception: pass
            bw.close()
            h, _, body = data.partition(b"\r\n\r\n")
            hl = h.decode("latin-1").split("\r\n")
            ctype = next((l.split(":", 1)[1].lower() for l in hl[1:] if l.lower().startswith("content-type:")), "")
            if "text/html" in ctype and b"</head>" in body and UI.encode() not in body:
                body = body.replace(b"</head>", UI.encode() + b"</head>", 1)
            if hl and hl[0].startswith("HTTP/"):
                hl = [hl[0]] + set_headers(hl[1:], {"content-length", "transfer-encoding", "connection"}, [f"Content-Length: {len(body)}", "Connection: close"])
                cw.write(("\r\n".join(hl) + "\r\n\r\n").encode("latin-1") + body)
            else:
                cw.write(wait_page())
            await cw.drain(); cw.close(); return
        await asyncio.gather(pipe(cr, bw), pipe(br, cw))
    except Exception:
        try: cw.close()
        except Exception: pass

async def main():
    servers = []
    for p in PORTS:
        sock = None
        try:
            sock = socket.socket(socket.AF_INET6, socket.SOCK_STREAM)
            sock.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 0)   # IPv4 and IPv6 on one socket
            sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1); sock.bind(("::", p))
        except OSError:
            if sock: sock.close()
            sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            try: sock.bind(("0.0.0.0", p))
            except OSError as e:
                sock.close(); print(f"[chost] edge: port {p} not available ({e.strerror})", flush=True); continue
        sock.listen(1024); sock.setblocking(False)
        servers.append(await asyncio.start_server(handle, sock=sock, limit=65536))
    if not servers: sys.exit(1)
    print(f"[chost] edge: built-in front door is serving the panel on {', '.join(str(s.sockets[0].getsockname()[1]) for s in servers)}", flush=True)
    await asyncio.gather(*(s.serve_forever() for s in servers))

asyncio.run(main())
CHOSTEDGE
rm -f /run/chost-ngfail
# the panel answers on 8080, on the port Railway gives the service, and on the usual web ports,
# so whatever target port the domain uses, it reaches the panel (never "Application failed to respond")
EXTRA=""; PORTS="8080"
for pt in "$RW_PORT" 80 3000 5000 8888; do
  case " $PORTS " in *" $pt "*) continue ;; esac
  PORTS="$PORTS $pt"; EXTRA="${EXTRA}listen ${pt}; listen [::]:${pt}; "
done
sed -e "s/__PORT__/${PORT}/g" -e "s/#__EXTRA_LISTEN__/${EXTRA}/" -e "s/^worker_processes auto;/worker_processes ${NGX_W};/" /etc/nginx/nginx.conf.template > /etc/nginx/nginx.conf
# nginx worker user: www-data on Debian, nginx on Alpine
if ! id www-data >/dev/null 2>&1; then
  if id nginx >/dev/null 2>&1; then sed -i 's/^user www-data;/user nginx;/' /etc/nginx/nginx.conf; else sed -i '/^user www-data;/d' /etc/nginx/nginx.conf; fi
fi
# real test: can this container open an IPv6 listening socket at all?
if ! "$PY" -c "import socket;s=socket.socket(socket.AF_INET6,socket.SOCK_STREAM);s.setsockopt(socket.IPPROTO_IPV6,socket.IPV6_V6ONLY,1);s.bind(('::',0));s.close()" >/dev/null 2>&1; then
  # region without IPv6 inside the container: listen on IPv4 only instead of failing to start
  sed -i 's/listen \[::\]:[0-9]*[^;]*;//g' /etc/nginx/nginx.conf
  echo "[chost] IPv6 not available here, listening on IPv4 only"
fi
if ! nginx -t 2>/tmp/nginx-test.log; then
  # safe mode: drop the tuning lines an unusual nginx build may not accept (listening is never touched here)
  sed -i -e '/^worker_rlimit_nofile/d' -e 's/ multi_accept on;//' -e 's/ use epoll;//' -e '/proxy_socket_keepalive/d' -e '/proxy_buffer_size/d' -e '/proxy_busy_buffers_size/d' -e '/sub_filter_types/d' -e 's/ charset_types application\/javascript;//' /etc/nginx/nginx.conf /etc/nginx/ws.inc
  if nginx -t 2>>/tmp/nginx-test.log; then echo "[chost] nginx safe mode"; else cat /tmp/nginx-test.log; echo "[chost] nginx config error (the supervisor keeps trying)"; fi
fi
echo "[chost] listening on ports: ${PORTS} (domain port: 8080) | cpu: ${CPUS} | memory: $( [ -n "$MEM_MAX" ] && echo "$(( MEM_MAX / 1048576 )) MB" || echo "no limit" )"
echo "[chost] region: ${RAILWAY_REPLICA_REGION:-unknown}, domain: ${RAILWAY_PUBLIC_DOMAIN:-not generated yet}"

# ---- first boot: the panel opens only when admin/admin is ready (at most 4 minutes of waiting) ----
if [ ! -f "$DATA/.owner_initialized" ]; then
  touch /run/chost-starting
  ( for i in $(seq 1 120); do [ -f "$DATA/.owner_initialized" ] && break; sleep 2; done; rm -f /run/chost-starting ) &
else
  rm -f /run/chost-starting
fi

# ---- every part runs under its own supervisor: if one part stops, only that part is started again
#      (in a few seconds, inside the same container). The service itself is never restarted. ----
supervise() {   # supervise <name> <pidfile> <command...>
  local name="$1" pidf="$2"; shift 2; local n=0
  while true; do
    "$@" &
    echo $! > "$pidf"
    wait $! ; code=$?
    n=$((n+1))
    echo "[chost] $name stopped (exit $code), starting it again (#$n)"
    sleep $(( n < 5 ? 2 : 10 ))
  done
}

# ---- node (xray) ----
node_run() {
  cd /opt/pg-node || return 1
  export SERVICE_PORT=62050 NODE_HOST=127.0.0.1 SERVICE_PROTOCOL=grpc
  export API_KEY="$(cat "$DATA/node_api_key")"
  export SSL_CERT_FILE="$DATA/node-certs/cert.pem" SSL_KEY_FILE="$DATA/node-certs/key.pem"
  exec ./main
}
supervise "core" /run/chost-node.pid node_run &

# ---- database doctor: checks the database before every start, keeps 4 safe copies on the volume,
#      and puts the last good copy back by itself if the database is ever damaged ----
DBF="$(echo "${SQLALCHEMY_DATABASE_URL:-}" | sed -n 's#^sqlite[^:]*:///##p')"; [ -n "$DBF" ] || DBF="$DATA/db.sqlite3"
BKD="$DATA/chost-backups"; mkdir -p "$BKD" 2>/dev/null || true
db_doctor() {   # db_doctor check|snap
  "$PY" - "$1" "$DBF" "$BKD" <<'PYEOF' || true
import sqlite3, sys, os, glob, time, shutil
mode, db, bk = sys.argv[1:4]
if not os.path.exists(db) or os.path.getsize(db) == 0: sys.exit(0)
def state(path):   # "ok", "bad" (really damaged) or "busy" (locked / not readable now: never treated as damage)
    try:
        c = sqlite3.connect(f"file:{path}?mode=ro", uri=True, timeout=20)
        try: r = c.execute("PRAGMA quick_check").fetchone()[0]
        finally: c.close()
        return "ok" if r == "ok" else "bad"
    except sqlite3.DatabaseError as e:
        m = str(e).lower()
        return "bad" if ("malformed" in m or "not a database" in m or "corrupt" in m) else "busy"
    except Exception: return "busy"
def ok(path): return state(path) == "ok"
snaps = sorted(glob.glob(os.path.join(bk, "db-*.sqlite3")))
if mode == "snap":
    if not ok(db): sys.exit(0)
    try:
        st = os.statvfs(bk)
        if st.f_bavail * st.f_frsize < os.path.getsize(db) * 3: print("[chost] doctor: volume almost full, safe copy skipped", flush=True); sys.exit(0)
    except Exception: pass
    out = os.path.join(bk, time.strftime("db-%Y%m%d-%H%M%S.sqlite3")); tmp = out + ".tmp"
    try:
        src = sqlite3.connect(db, timeout=30); dst = sqlite3.connect(tmp); src.backup(dst); dst.close(); src.close()
        if ok(tmp): os.replace(tmp, out)
        else: os.remove(tmp)
    except Exception as e:
        print(f"[chost] doctor: safe copy not made now ({e})", flush=True)
        try: os.remove(tmp)
        except Exception: pass
    for old in sorted(glob.glob(os.path.join(bk, "db-*.sqlite3")))[:-4]:
        try: os.remove(old)
        except Exception: pass
    sys.exit(0)
# check: only a really damaged database is repaired, a busy one is left alone
if state(db) != "bad": sys.exit(0)
print("[chost] doctor: database is damaged, repairing it", flush=True)
keep = db + time.strftime(".damaged-%Y%m%d-%H%M%S")
good = [p for p in reversed(snaps) if ok(p)]
try:
    shutil.copy2(db, keep)
    if good:
        shutil.copy2(good[0], db + ".tmp"); os.replace(db + ".tmp", db)
        for ext in ("-wal", "-shm", "-journal"):
            try: os.remove(db + ext)
            except Exception: pass
        print(f"[chost] doctor: last safe copy put back ({os.path.basename(good[0])}), the damaged file is kept next to it", flush=True)
    else:
        os.remove(keep)   # no safe copy yet: nothing is replaced, so no user is ever lost
        print("[chost] doctor: no safe copy yet, the database is left as it is", flush=True)
except Exception as e:
    print(f"[chost] doctor: database repair stopped ({e}), left as it is", flush=True)
PYEOF
}

# ---- panel: database check, then the database update (retried until it works), then the panel ----
panel_run() {
  cd "$PANEL_DIR" || return 1
  touch /run/chost-migrating
  db_doctor check
  db_doctor snap   # a safe copy before every update, so an image update can never lose data
  local t=0
  until "$PY" -m alembic upgrade head; do
    t=$((t+1)); echo "[chost] database update failed, retrying in 5s"
    [ "$t" -eq 6 ] && db_doctor check   # still failing: make sure the database itself is healthy
    sleep 5
  done
  rm -f /run/chost-migrating
  exec "$PY" main.py
}
supervise "panel" /run/chost-panel.pid panel_run &

# ---- auto setup + doctor (finds and fixes problems on its own) ----
supervise "setup" /run/chost-setup.pid bash -c 'cd "$PANEL_DIR" && exec "$PY" /code/bootstrap.py' &

# ---- Telegram sales bot (sidebar page "ربات تلگرام") ----
# the bot process only starts once a token is saved and the bot is turned on (saves memory on small plans);
# it is checked every 3 s, so the bot still comes online right after "Save"
( sleep 20; supervise "sales bot" /run/chost-bot.pid bash -c '
  until grep -Eq "\"enabled\": *true" "$1" 2>/dev/null && grep -Eq "\"token\": *\"[^\"]+" "$1" 2>/dev/null; do sleep 3; done
  cd "$PANEL_DIR" && exec "$PY" /code/chostbot.py' _ "$DATA/chost-bot.json" ) &

# nginx: before every start, each listening address is really tried. Only an address this container can
# never open is dropped (IPv6 missing in a region, a port that is not allowed); "already in use" is never
# a reason to drop anything, the supervisor simply tries again. 8080 is always kept.
nginx_prep() {
  "$PY" - "$RW_PORT" <<'PYEOF' || true
import re, socket, errno, sys
keep = {"8080", sys.argv[1]}
conf = "/etc/nginx/nginx.conf"
s = open(conf).read()
out = s
for m in re.finditer(r"listen (\[::\]:)?(\d+)([^;]*);", s):
    v6, port = bool(m.group(1)), m.group(2)
    fam = socket.AF_INET6 if v6 else socket.AF_INET
    try:
        k = socket.socket(fam, socket.SOCK_STREAM)
        k.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        if v6: k.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)
        k.bind(("::" if v6 else "0.0.0.0", int(port))); k.close(); continue
    except OSError as e:
        code, why = e.errno, e.strerror
    if code == errno.EADDRINUSE: continue
    if v6 and code in (errno.EAFNOSUPPORT, errno.EADDRNOTAVAIL, errno.EPROTONOSUPPORT):
        out = out.replace(m.group(0), "", 1); print(f"[chost] nginx: IPv6 port {port} not available here, using IPv4 for it", flush=True)
    elif port not in keep:
        out = out.replace(m.group(0), "", 1); print(f"[chost] nginx: port {port} not allowed here ({why}), skipped", flush=True)
if out != s:
    open(conf, "w").write(out)
PYEOF
}
nginx_safe_conf() {   # last resort: the simplest config that always works (panel + configs + health check)
  cat > /etc/nginx/nginx.conf <<NGXSAFE
pid /run/nginx.pid;
events { worker_connections 2048; }
http {
  access_log off; error_log /dev/stderr warn; client_max_body_size 0;
  map \$http_upgrade \$conn_upgrade { default upgrade; '' ''; }
  server {
    listen 8080 default_server;
    $( [ "$RW_PORT" != 8080 ] && echo "listen ${RW_PORT};" )
    location = /healthz { return 200 "ok"; }
    absolute_redirect off;
    location = / { return 302 /dashboard/; }
    include /var/lib/pasarguard/inbounds.inc;
    location ^~ /chost/ { proxy_pass http://127.0.0.1:8100; proxy_set_header Host \$host; proxy_set_header X-Real-IP \$remote_addr; }
    location / {
      proxy_pass http://127.0.0.1:8000; proxy_http_version 1.1;
      proxy_set_header Host \$host; proxy_set_header X-Real-IP \$remote_addr;
      proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for; proxy_set_header X-Forwarded-Proto https;
      proxy_set_header Upgrade \$http_upgrade; proxy_set_header Connection \$conn_upgrade; proxy_read_timeout 300s;
    }
  }
}
NGXSAFE
  printf 'proxy_http_version 1.1;\nproxy_set_header Upgrade $http_upgrade;\nproxy_set_header Connection "upgrade";\nproxy_set_header Host $host;\nproxy_buffering off;\nproxy_read_timeout 1h; proxy_send_timeout 1h;\n' > /etc/nginx/ws.inc
}
edge_run() {
  echo "[chost] doctor: nginx can not start here, the built-in CHOST edge serves the panel instead"
  rm -f /run/nginx.pid
  exec "$PY" /etc/nginx/chost-edge.py $PORTS
}
nginx_run() {
  local fails; fails=$(cat /run/chost-ngfail 2>/dev/null || echo 0); case "$fails" in ''|*[!0-9]*) fails=0 ;; esac
  [ "$fails" -ge 6 ] && edge_run   # nginx failed 6 times in a row within seconds: never leave the domain dead
  nginx_prep
  if ! nginx -t >/tmp/nginx-run.log 2>&1; then
    # doctor: the config is not accepted, drop the optional tuning lines and test again
    sed -i -e '/^worker_rlimit_nofile/d' -e 's/ multi_accept on;//' -e 's/ use epoll;//' -e '/proxy_socket_keepalive/d' -e '/proxy_buffer_size/d' -e '/proxy_busy_buffers_size/d' -e '/sub_filter_types/d' -e 's/ charset_types application\/javascript;//' /etc/nginx/nginx.conf /etc/nginx/ws.inc
    if ! nginx -t >>/tmp/nginx-run.log 2>&1; then
      grep -m3 emerg /tmp/nginx-run.log
      echo "[chost] doctor: nginx config repaired with the safe version"
      nginx_safe_conf
      nginx -t >/dev/null 2>&1 || sed -i '/inbounds.inc/d' /etc/nginx/nginx.conf
      nginx -t >/dev/null 2>&1 || edge_run
    fi
  fi
  local t0=$SECONDS
  nginx -g 'daemon off;'; local code=$?
  if [ $(( SECONDS - t0 )) -lt 30 ]; then echo $(( fails + 1 )) > /run/chost-ngfail; else echo 0 > /run/chost-ngfail; fi
  return $code
}
supervise "nginx" /run/chost-nginx.pid nginx_run &

# ---- self test: 25 s after start, check the panel is reachable the way Railway reaches it
#      (every address of this container, IPv4 and IPv6, on the domain port and Railway's port) ----
( sleep 25; "$PY" - "$RW_PORT" <<'PYEOF' || true
import socket, sys, os
ports = sorted({8080, int(sys.argv[1])})
addrs = set()
for host in (socket.gethostname(), os.getenv("RAILWAY_PRIVATE_DOMAIN") or ""):
    if not host: continue
    try:
        for fam, _, _, _, sa in socket.getaddrinfo(host, None):
            if fam in (socket.AF_INET, socket.AF_INET6) and not sa[0].startswith(("127.", "::1", "fe80")): addrs.add((fam, sa[0]))
    except Exception: pass
addrs |= {(socket.AF_INET, "127.0.0.1")}
bad = 0
for fam, ip in sorted(addrs, key=lambda x: x[1]):
    for p in ports:
        s = socket.socket(fam, socket.SOCK_STREAM); s.settimeout(3)
        try:
            s.connect((ip, p)); s.sendall(b"GET /healthz HTTP/1.0\r\nHost: x\r\n\r\n"); ok = b" 200 " in s.recv(64)
        except Exception: ok = False
        finally: s.close()
        bad += not ok
        print(f"[chost] self test {'IPv6' if fam == socket.AF_INET6 else 'IPv4'} {ip}:{p} -> {'ok' if ok else 'NOT REACHABLE'}", flush=True)
print("[chost] self test: " + ("all good, the panel is reachable" if not bad else "some addresses are not reachable (send these lines to support)"), flush=True)
PYEOF
) &

# ---- watchdog: a part that stops answering is started again on its own; the service keeps running ----
(
  sleep 180; pf=0; nf=0; mh=0; cf=0; nsnap=$(( SECONDS + 600 ))   # slow regions start slower: give them time before watching
  while true; do
    # safe copy of the database every 6 hours (4 copies kept on the volume)
    if [ "$SECONDS" -ge "$nsnap" ] && [ ! -f /run/chost-migrating ]; then db_doctor snap; nsnap=$(( SECONDS + 21600 )); fi
    # disk guard: if the volume is almost full, old safe copies and leftover files are cleared so the panel can write
    free=$(df -Pk "$DATA" 2>/dev/null | awk 'NR==2{print $4}'); case "$free" in ''|*[!0-9]*) free=999999 ;; esac
    if [ "$free" -lt 51200 ]; then
      echo "[chost] doctor: volume almost full, clearing old files"
      ls -1t "$BKD"/db-*.sqlite3 2>/dev/null | tail -n +2 | xargs -r rm -f
      ls -1t "$DBF".damaged-* 2>/dev/null | tail -n +2 | xargs -r rm -f
      find "$DATA" /tmp -maxdepth 2 \( -name '*.log' -o -name '*.tmp' \) -size +1M -delete 2>/dev/null
    fi
    # core guard: the Xray core must answer on its port; if it hangs, only the core is started again
    if "$PY" -c "import socket;socket.create_connection(('127.0.0.1',62050),3).close()" 2>/dev/null; then cf=0; else cf=$((cf+1)); fi
    if [ "$cf" -ge 3 ]; then echo "[chost] doctor: core not answering, starting it again"; kill "$(cat /run/chost-node.pid 2>/dev/null)" 2>/dev/null; cf=0; fi
    # memory guard: before the service could run out of memory, free it by restarting the sales bot,
    # then (only if still needed) the panel process; configs keep working, the container is never killed
    if [ -n "$MEM_MAX" ] && [ "$SECONDS" -ge "${mcool:-0}" ]; then
      # real working memory = used minus the file cache the kernel can drop by itself
      cur=$(cat /sys/fs/cgroup/memory.current 2>/dev/null || cat /sys/fs/cgroup/memory/memory.usage_in_bytes 2>/dev/null || echo 0)
      ina=$(awk '$1=="inactive_file"||$1=="total_inactive_file"{print $2; exit}' /sys/fs/cgroup/memory.stat /sys/fs/cgroup/memory/memory.stat 2>/dev/null)
      case "$cur" in ''|*[!0-9]*) cur=0 ;; esac; case "$ina" in ''|*[!0-9]*) ina=0 ;; esac
      ws=$(( cur > ina ? cur - ina : 0 ))
      if [ "$ws" -gt $(( MEM_MAX * 92 / 100 )) ]; then
        mh=$((mh+1))
        if [ "$mh" -eq 1 ]; then echo "[chost] doctor: memory high ($(( ws / 1048576 )) MB), refreshing the sales bot"; kill "$(cat /run/chost-bot.pid 2>/dev/null)" 2>/dev/null
        elif [ "$mh" -ge 3 ] && [ ! -f /run/chost-migrating ]; then
          echo "[chost] doctor: memory still high ($(( ws / 1048576 )) MB), refreshing the panel"; kill "$(cat /run/chost-panel.pid 2>/dev/null)" 2>/dev/null
          mh=0; mcool=$(( SECONDS + 600 ))   # then leave it alone for 10 minutes
        fi
      else mh=0; fi
    fi
    if curl -fsS -o /dev/null --max-time 5 http://127.0.0.1:8080/healthz; then nf=0; else nf=$((nf+1)); fi
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 http://127.0.0.1:8000/api/system)
    case "$code" in ""|000|5??) pf=$((pf+1)) ;; *) pf=0 ;; esac   # any real answer = the panel is alive
    if [ "$nf" -ge 3 ]; then echo "[chost] doctor: nginx not answering, starting it again"; kill "$(cat /run/nginx.pid 2>/dev/null || cat /run/chost-nginx.pid 2>/dev/null)" 2>/dev/null; nf=0; fi
    [ -f /run/chost-migrating ] && pf=0   # never interrupt a database update
    if [ "$pf" -ge 6 ]; then echo "[chost] doctor: panel not answering, starting it again"; kill "$(cat /run/chost-panel.pid 2>/dev/null)" 2>/dev/null; pf=0; fi
    sleep 20
  done
) &

# the container stays up; parts are healed in place
while true; do sleep 3600; done
