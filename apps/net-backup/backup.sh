#!/bin/sh
# Снимает конфиги Keenetic и HP 5130 по SSH в /backup (PVC, который K8up уносит в MinIO и Backblaze).
# Пароли приходят из env (SealedSecret net-backup-credentials), на диск не пишутся.
set -eu

DIR=${BACKUP_DIR:-/backup}
TS=$(date +%Y%m%d-%H%M%S)
KEEP_DAYS=30
mkdir -p "$DIR/keenetic" "$DIR/hp5130" "$DIR/tenda" "$DIR/monthly"

# ssh спрашивает пароль через SSH_ASKPASS, значение берётся из env ASKPASS_PW
printf '#!/bin/sh\nprintf "%%s" "$ASKPASS_PW"\n' > /tmp/askpass.sh
chmod 700 /tmp/askpass.sh
export SSH_ASKPASS=/tmp/askpass.sh SSH_ASKPASS_REQUIRE=force DISPLAY=none

SSH_COMMON="-o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/tmp/known_hosts -o PubkeyAuthentication=no \
 -o PreferredAuthentications=password,keyboard-interactive -o ConnectTimeout=15 -o NumberOfPasswordPrompts=1"

fail=0

# Keenetic: show running-config
if ASKPASS_PW="$KEENETIC_PASSWORD" ssh $SSH_COMMON "$KEENETIC_USER@$KEENETIC_HOST" 'show running-config' \
     | tr -d '\r' > "$DIR/keenetic/.new" 2>/tmp/kn.err \
   && [ "$(wc -l < "$DIR/keenetic/.new")" -gt 200 ] && grep -q '^user ' "$DIR/keenetic/.new"; then
  mv "$DIR/keenetic/.new" "$DIR/keenetic/running-config-$TS.txt"
  echo "keenetic: ok ($(wc -l < "$DIR/keenetic/running-config-$TS.txt") строк)"
else
  echo "keenetic: FAILED"; cat /tmp/kn.err; rm -f "$DIR/keenetic/.new"; fail=1
fi

# HP 5130 (Comware): пейджер выключен на vty (screen-length 0), вывод режем между первым "#" и "return"
if { echo 'display current-configuration'; sleep 5; echo quit; } \
   | ASKPASS_PW="$HP_PASSWORD" ssh -tt $SSH_COMMON -o HostKeyAlgorithms=+ssh-rsa -o KexAlgorithms=+diffie-hellman-group14-sha1 \
       "$HP_USER@$HP_HOST" 2>/tmp/hp.err | tr -d '\r' \
   | awk '/^display current-configuration/ {on=1; next} on && !seen && /^#/ {seen=1} seen {print} /^return/ && seen {exit}' \
   > "$DIR/hp5130/.new" \
   && [ "$(wc -l < "$DIR/hp5130/.new")" -gt 100 ] && grep -q '^return' "$DIR/hp5130/.new"; then
  mv "$DIR/hp5130/.new" "$DIR/hp5130/current-config-$TS.txt"
  echo "hp5130: ok ($(wc -l < "$DIR/hp5130/current-config-$TS.txt") строк)"
else
  echo "hp5130: FAILED"; cat /tmp/hp.err; rm -f "$DIR/hp5130/.new"; fail=1
fi

# Точки доступа Tenda i27: вход JSON-запросом (пароль в base64, как делает веб-интерфейс), конфиг отдаёт /cgi-bin/DownloadCfg/APCfm.cfg
ap_backup() {
  name=$1; host=$2; jar=/tmp/jar-$name; out="$DIR/tenda/$name"
  mkdir -p "$out"
  pw64=$(printf %s "$AP_PASSWORD" | base64 | tr -d '\n')
  now=$(date +"%Y;%m;%d;%H;%M;%S" | sed 's/;0/;/g')
  login=$(curl -s -m15 -c "$jar" -H 'Content-Type: application/json' \
    -d "{\"sysLogin\":{\"password\":\"$pw64\",\"logoff\":false,\"timeZone\":15,\"time\":\"$now\"}}" \
    "http://$host/goform/modules?$$") || login=
  if echo "$login" | grep -Eq '"Login" *: *true' \
     && curl -s -m30 -b "$jar" "http://$host/cgi-bin/DownloadCfg/APCfm.cfg" -o "$out/.new" \
     && [ "$(wc -l < "$out/.new")" -gt 500 ] && grep -q '^Default' "$out/.new"; then
    mv "$out/.new" "$out/APCfm-$TS.cfg"
    echo "tenda $name: ok ($(wc -l < "$out/APCfm-$TS.cfg") строк)"
  else
    echo "tenda $name: FAILED (ответ входа: $(echo "$login" | cut -c1-120))"; rm -f "$out/.new"; fail=1
  fi
  curl -s -m10 -b "$jar" -H 'Content-Type: application/json' -d '{"sysLogin":{"username":"","password":"","logoff":true}}' \
    "http://$host/goform/modules?$$" >/dev/null 2>&1 || true
}
if [ -n "${AP_PASSWORD:-}" ]; then
  ap_backup ap-11 "$AP1_HOST"
  ap_backup ap-12 "$AP2_HOST"
fi

# 1-го числа кладём копию в monthly (хранится 13 месяцев), остальные файлы старше KEEP_DAYS чистим
if [ "$(date +%d)" = "01" ]; then
  cp "$DIR"/keenetic/running-config-"$TS".txt "$DIR"/hp5130/current-config-"$TS".txt "$DIR"/tenda/*/APCfm-"$TS".cfg "$DIR/monthly/" 2>/dev/null || true
fi
find "$DIR/keenetic" "$DIR/hp5130" "$DIR/tenda" -type f \( -name '*-20*.txt' -o -name '*-20*.cfg' \) -mtime +"$KEEP_DAYS" -delete
find "$DIR/monthly" -type f -mtime +400 -delete

exit $fail
