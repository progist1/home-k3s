#!/usr/bin/env bash
# node-exporter + метрики tailnet на сервере (Ubuntu/Debian). Идемпотентно.
#
#   sudo ./vps-monitoring.sh                      # tailscaled установлен на хосте
#   sudo TS_CMD='docker exec edge-core-tailscale-1 tailscale' ./vps-monitoring.sh   # tailscale в контейнере (edge)
#
# Что делает:
#  - ставит prometheus-node-exporter и слушает ТОЛЬКО на tailnet-адресе сервера (порт 9100); Restart=always, чтобы
#    пережить гонку при загрузке (tailscale0 поднимается позже);
#  - раз в 30 с пишет в textfile-каталог метрики tailnet (python-коллектор ниже): состояние узла, по каждому пиру
#    online / прямое соединение или DERP / трафик / время последнего рукопожатия, плюс `tailscale metrics print`.
# Правила файрвола тут не меняются: порт 9100 приходит с интерфейса tailscale0 (разрешён скриптом tailnet-join.sh).
set -euo pipefail

TS_CMD="${TS_CMD:-tailscale}"
TEXTFILE_DIR=/var/lib/prometheus/node-exporter
[[ $EUID -eq 0 ]] || { echo "запусти от root" >&2; exit 1; }

TS_IP="$($TS_CMD ip -4 | head -1)"
[[ "$TS_IP" == 100.* ]] || { echo "не удалось получить tailnet-адрес (tailscale ip -4): '$TS_IP'" >&2; exit 1; }

echo "== node-exporter на $TS_IP:9100"
# --no-install-recommends: пакет prometheus-node-exporter-collectors (smartmon/apt/nvme-таймеры) на VPS не нужен и
# даёт дубли smartmon_device_info (/dev/sda) в правилах Prometheus
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends prometheus-node-exporter python3 >/dev/null
if dpkg -s prometheus-node-exporter-collectors >/dev/null 2>&1; then
  DEBIAN_FRONTEND=noninteractive apt-get purge -y -qq prometheus-node-exporter-collectors >/dev/null
  find "$TEXTFILE_DIR" -name '*.prom' ! -name 'tailnet.prom' -delete
fi
install -d -m 0755 "$TEXTFILE_DIR"
cat > /etc/default/prometheus-node-exporter <<EOC
ARGS="--web.listen-address=${TS_IP}:9100 --collector.textfile.directory=${TEXTFILE_DIR}"
EOC
install -d /etc/systemd/system/prometheus-node-exporter.service.d
cat > /etc/systemd/system/prometheus-node-exporter.service.d/10-tailnet.conf <<'EOC'
[Unit]
After=tailscaled.service network-online.target
[Service]
Restart=always
RestartSec=5
EOC

echo "== коллектор метрик tailnet"
cat > /usr/local/bin/tailnet-textfile.py <<'EOPY'
#!/usr/bin/env python3
import json, os, shlex, subprocess, sys, tempfile, time

TS = shlex.split(os.environ.get("TS_CMD", "tailscale"))
OUT = "/var/lib/prometheus/node-exporter/tailnet.prom"

def run(args):
    return subprocess.run(TS + args, capture_output=True, text=True, timeout=20)

def esc(v):
    return str(v).replace("\\", "\\\\").replace('"', '\\"')

lines = []
try:
    st = json.loads(run(["status", "--json"]).stdout)
except Exception:
    st = None
now = time.time()
lines += ["# TYPE tailnet_up gauge", f"tailnet_up {1 if st and st.get('BackendState') == 'Running' else 0}"]
if st:
    lines += [
        "# TYPE tailnet_peer_online gauge", "# TYPE tailnet_peer_direct gauge",
        "# TYPE tailnet_peer_rx_bytes counter", "# TYPE tailnet_peer_tx_bytes counter",
        "# TYPE tailnet_peer_last_handshake_timestamp_seconds gauge",
    ]
    for p in (st.get("Peer") or {}).values():
        # имя из Headscale (DNSName), а не hostname ОС: на части серверов ОС называет себя "Ubuntu"
        name = esc((p.get("DNSName") or "").split(".")[0] or p.get("HostName") or "?")
        lab = f'peer="{name}"'
        lines.append(f"tailnet_peer_online{{{lab}}} {1 if p.get('Online') else 0}")
        lines.append(f"tailnet_peer_direct{{{lab}}} {1 if p.get('CurAddr') else 0}")
        lines.append(f"tailnet_peer_rx_bytes{{{lab}}} {p.get('RxBytes', 0)}")
        lines.append(f"tailnet_peer_tx_bytes{{{lab}}} {p.get('TxBytes', 0)}")
        lh = p.get("LastHandshake", "")
        if lh and not lh.startswith("0001"):
            try:
                ts = time.mktime(time.strptime(lh[:19], "%Y-%m-%dT%H:%M:%S")) - time.timezone
                lines.append(f"tailnet_peer_last_handshake_timestamp_seconds{{{lab}}} {int(ts)}")
            except ValueError:
                pass
try:
    m = run(["metrics", "print"]).stdout
    lines += [l for l in m.splitlines() if l]
except Exception:
    pass
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(OUT))
with os.fdopen(fd, "w") as f:
    f.write("\n".join(lines) + "\n")
os.chmod(tmp, 0o644)
os.replace(tmp, OUT)
EOPY
chmod 0755 /usr/local/bin/tailnet-textfile.py

cat > /etc/systemd/system/tailnet-textfile.service <<EOC
[Unit]
Description=Tailnet metrics for node-exporter textfile collector
After=tailscaled.service
[Service]
Type=oneshot
Environment="TS_CMD=${TS_CMD}"
ExecStart=/usr/local/bin/tailnet-textfile.py
EOC
cat > /etc/systemd/system/tailnet-textfile.timer <<'EOC'
[Unit]
Description=Tailnet metrics every 30s
[Timer]
OnBootSec=20s
OnUnitActiveSec=30s
AccuracySec=1s
[Install]
WantedBy=timers.target
EOC

systemctl daemon-reload
systemctl enable --now tailnet-textfile.timer >/dev/null
systemctl enable prometheus-node-exporter >/dev/null
systemctl restart prometheus-node-exporter
systemctl start tailnet-textfile.service || true
sleep 2
echo "== проверка"
curl -fsS --max-time 5 "http://${TS_IP}:9100/metrics" | grep -E "^(node_uname_info|tailnet_up|tailnet_peer_online)" | head -4
