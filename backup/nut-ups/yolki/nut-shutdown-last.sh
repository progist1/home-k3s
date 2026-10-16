#!/bin/sh
# /usr/local/sbin/nut-shutdown-last.sh (0755, root). SHUTDOWNCMD master'а (yolki).
# Ждём, пока TrueNAS (bigb) и pi перестанут отвечать (они гасятся по FSD, TrueNAS ещё останавливает VM k3s),
# но не дольше WAIT секунд. Потом выключаем yolki; при /etc/killpower пакетный nutshutdown вызовет
# `upsdrvctl shutdown` (UPS срежет выход и вернёт его при появлении сети — только если allow_killpower=1).
HOSTS="10.77.20.4 10.77.20.5"
WAIT=480
# Флаги: dry-run (всё сухое) или no-poweroff (FSD настоящий, но сама yolki не выключается)
DRY=""; { [ -e /etc/nut/dry-run ] || [ -e /etc/nut/no-poweroff ]; } && DRY=1

logger -t nut "shutdown-last: жду $HOSTS (до ${WAIT}s)"
t=0
while [ "$t" -lt "$WAIT" ]; do
  alive=0
  for h in $HOSTS; do
    ping -c1 -W1 "$h" >/dev/null 2>&1 && alive=1
  done
  [ "$alive" -eq 0 ] && break
  if [ -n "$DRY" ] && [ "$t" -ge 10 ]; then logger -t nut "shutdown-last: сухой режим, прекращаю ожидание (хосты ещё живы)"; break; fi
  sleep 5
  t=$((t+5))
done
logger -t nut "shutdown-last: хосты замолчали (или таймаут, t=${t}s), выключаюсь"
if [ -n "$DRY" ]; then logger -t nut "DRY-RUN: здесь был бы /sbin/shutdown -h +0"; exit 0; fi
/sbin/shutdown -h +0
