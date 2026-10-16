#!/bin/sh
# Установка master-части NUT на k3s-yolki. Запуск: sudo ./setup-yolki.sh (из каталога backup/nut-ups/yolki)
# По умолчанию создаётся /etc/nut/dry-run: FSD не объявляется, yolki не выключается, всё только пишется в syslog.
set -eu
SRC=$(cd "$(dirname "$0")" && pwd)
[ "$(id -u)" -eq 0 ] || { echo "Запусти через sudo"; exit 1; }

TS=$(date +%Y%m%d-%H%M%S)
cp -a /etc/nut "/etc/nut.bak-$TS"
echo "Бэкап: /etc/nut.bak-$TS"

install -m 0640 -o root -g nut "$SRC/nut.conf"       /etc/nut/nut.conf
install -m 0640 -o root -g nut "$SRC/upsd.conf"      /etc/nut/upsd.conf
install -m 0640 -o root -g nut "$SRC/upssched.conf"  /etc/nut/upssched.conf
install -m 0755 "$SRC/upssched-cmd"          /usr/local/sbin/upssched-cmd
install -m 0755 "$SRC/nut-shutdown-last.sh"  /usr/local/sbin/nut-shutdown-last.sh
touch /etc/nut/dry-run /etc/nut/no-poweroff
echo "Сухой режим включён: /etc/nut/dry-run и /etc/nut/no-poweroff"

# Пользователи upsd: [truenas] обычно уже есть; [upsmon] и [pi] создаём, если нет, иначе берём пароль из файла (не печатаем).
USERS=/etc/nut/upsd.users
get_pw() { awk -v u="[$1]" '$0==u{f=1;next} /^\[/{f=0} f&&/password/{sub(/^[^=]*= */,""); print; exit}' "$USERS"; }
ensure_user() { # имя роль
  if grep -q "^\[$1\]" "$USERS"; then
    echo "Пользователь [$1] уже есть в $USERS, использую его пароль"
  else
    printf '\n[%s]\n    password = %s\n    %s\n' "$1" "$(openssl rand -hex 16)" "$2" >> "$USERS"
    echo "Пользователь [$1] добавлен"
  fi
}
ensure_user upsmon "upsmon primary"
ensure_user pi "upsmon secondary"
chown root:nut "$USERS"; chmod 0640 "$USERS"
PW_MON=$(get_pw upsmon)
PW_PI=$(get_pw pi)
( umask 077; printf '%s\n' "$PW_PI" > /root/nut-pi.pw )
echo "Пароль для pi сохранён в /root/nut-pi.pw (0600), передай на pi и удали"

# upsmon.conf: заменяем целиком (бэкап выше)
cp "$SRC/upsmon.conf.example" /etc/nut/upsmon.conf
sed -i "s/CHANGE_ME_1/$PW_MON/" /etc/nut/upsmon.conf
chown root:nut /etc/nut/upsmon.conf; chmod 0640 /etc/nut/upsmon.conf
grep -q CHANGE_ME /etc/nut/upsmon.conf && echo "ВНИМАНИЕ: в upsmon.conf остался CHANGE_ME, впиши пароль [upsmon]"

systemctl enable nut-server nut-monitor
systemctl restart nut-server
systemctl restart nut-monitor
echo "--- проверка"
upsc apc@localhost ups.status 2>&1 | tail -1
printf 'LIST CLIENT apc\nLOGOUT\n' | nc -w 3 127.0.0.1 3493
journalctl -u nut-monitor -n 8 --no-pager | cut -c1-200
