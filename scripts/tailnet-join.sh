#!/usr/bin/env bash
# Подключить Ubuntu-сервер к tailnet (Headscale hs.progist.ru) с тегом tag:server.
#
#   sudo ./tailnet-join.sh <имя-узла>
#
# Ключ (preauth, тег tag:server) читается из $TS_AUTHKEY или запрашивается скрытым вводом. В аргументах и истории его нет.
# Что делает: ставит tailscale (официальный install.sh), подключает к Headscale (--accept-dns=false: не трогаем resolv.conf;
# маршруты домашней сети 10.0.0.0/24 НЕ принимаются: на узлах с WG до дома они перебьют wg0 и отрежут трафик в дом;
# включить позже: ACCEPT_ROUTES=1 или `tailscale set --accept-routes`), разрешает входящий трафик с интерфейса tailscale0
# (ufw или iptables). Публичный SSH и остальные правила файрвола НЕ меняются.
set -euo pipefail

LOGIN_SERVER="${LOGIN_SERVER:-https://hs.progist.ru}"
NAME="${1:-}"

[[ $EUID -eq 0 ]] || { echo "запусти от root: sudo $0 <имя-узла>" >&2; exit 1; }
[[ "$NAME" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]] || { echo "нужно имя узла (a-z, 0-9, дефис), например: spb-beget-1" >&2; exit 1; }

if [[ -z "${TS_AUTHKEY:-}" ]]; then
  read -rsp "preauth-ключ (ввод скрыт): " TS_AUTHKEY </dev/tty; echo
fi
[[ "$TS_AUTHKEY" == hskey-* ]] || { echo "ключ должен начинаться с hskey-" >&2; exit 1; }

if ! command -v tailscale >/dev/null; then
  echo "== ставлю tailscale (apt-репозиторий pkgs.tailscale.com)"
  # tailscale.com/install.sh не используем: сам tailscale.com (Vercel) из российских дата-центров часто не открывается,
  # а pkgs.tailscale.com (CloudFront) работает.
  . /etc/os-release
  [[ "$ID" == ubuntu || "$ID" == debian ]] || { echo "поддерживаются только Ubuntu/Debian, а тут $ID" >&2; exit 1; }
  install -d -m 0755 /usr/share/keyrings
  curl -fsS --connect-timeout 10 --max-time 60 "https://pkgs.tailscale.com/stable/$ID/$VERSION_CODENAME.noarmor.gpg" \
    -o /usr/share/keyrings/tailscale-archive-keyring.gpg
  curl -fsS --connect-timeout 10 --max-time 60 "https://pkgs.tailscale.com/stable/$ID/$VERSION_CODENAME.tailscale-keyring.list" \
    -o /etc/apt/sources.list.d/tailscale.list
  apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y tailscale
fi
systemctl enable --now tailscaled

echo "== подключаюсь как $NAME"
tailscale up --login-server="$LOGIN_SERVER" --authkey="$TS_AUTHKEY" --hostname="$NAME" \
  --accept-routes="$([[ "${ACCEPT_ROUTES:-0}" == 1 ]] && echo true || echo false)" --accept-dns=false --timeout=60s
unset TS_AUTHKEY

echo "== файрвол: разрешаю вход с tailscale0"
if command -v ufw >/dev/null && ufw status | grep -q "Status: active"; then
  ufw allow in on tailscale0 comment 'tailnet' >/dev/null && echo "ufw: правило добавлено"
elif command -v iptables >/dev/null; then
  if ! iptables -C INPUT -i tailscale0 -j ACCEPT 2>/dev/null; then
    iptables -I INPUT 1 -i tailscale0 -j ACCEPT
    echo "iptables: правило добавлено в работающую цепочку. ДОБАВЬ его в свой startup-скрипт, иначе пропадёт после перезагрузки:"
    echo "  iptables -I INPUT 1 -i tailscale0 -j ACCEPT"
  else
    echo "iptables: правило уже есть"
  fi
fi

echo "== итог"
tailscale ip -4
tailscale status | head -8
