#!/usr/bin/env bash
# Установка nut_exporter на k3s-yolki. Запуск: sudo ./install-exporter.sh (из каталога backup/nut-ups)
set -euo pipefail
VER=v3.3.0
SHA=8183da720ff547b7be56cc60505a3e0b731ccbf23aa18b3e297159b261500d8a
URL=https://github.com/DRuggeri/nut_exporter/releases/download/${VER}/nut_exporter-${VER}-linux-amd64
tmp=$(mktemp)
curl -fsSL -o "$tmp" "$URL"
echo "${SHA}  ${tmp}" | sha256sum -c -
install -m 755 "$tmp" /usr/local/bin/nut_exporter
rm -f "$tmp"
install -m 644 "$(dirname "$0")/nut-exporter.service" /etc/systemd/system/nut-exporter.service
systemctl daemon-reload
systemctl enable --now nut-exporter
curl -s --retry 5 --retry-connrefused --retry-delay 1 'http://127.0.0.1:9199/ups_metrics?ups=apc' | grep -E '^network_ups_tools_(ups_status|battery_charge|ups_load)' | head
