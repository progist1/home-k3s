#!/bin/sh
# Установка клиента NUT на k3s-pi. Запуск: sudo ./setup-pi.sh /путь/к/файлу-с-паролем [--live]
# По умолчанию SHUTDOWNCMD = logger (тестовый режим, pi НЕ выключается). --live включает реальное выключение.
set -eu
SRC=$(cd "$(dirname "$0")" && pwd)
[ "$(id -u)" -eq 0 ] || { echo "Запусти через sudo"; exit 1; }
PWFILE=${1:?"укажи файл с паролем пользователя pi"}
PW=$(tr -d '\n' < "$PWFILE")

apt-get install -y nut-client
install -m 0640 -o root -g nut "$SRC/nut.conf" /etc/nut/nut.conf
cp "$SRC/upsmon.conf.example" /etc/nut/upsmon.conf
sed -i "s/CHANGE_ME_3/$PW/" /etc/nut/upsmon.conf
if [ "${2:-}" != "--live" ]; then
  sed -i 's|^SHUTDOWNCMD .*|SHUTDOWNCMD "/usr/bin/logger -t nut FSD-TEST-NO-SHUTDOWN"|' /etc/nut/upsmon.conf
  echo "ТЕСТОВЫЙ режим: SHUTDOWNCMD = logger"
fi
chown root:nut /etc/nut/upsmon.conf; chmod 0640 /etc/nut/upsmon.conf
systemctl enable nut-monitor
systemctl restart nut-monitor
echo "--- проверка"
upsc apc@10.77.20.6 ups.status 2>&1 | tail -1
journalctl -u nut-monitor -n 6 --no-pager | cut -c1-200
