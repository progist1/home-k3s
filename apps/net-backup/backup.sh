#!/bin/sh
# Снимает конфиги Keenetic и HP 5130 по SSH в /backup (PVC, который K8up уносит в MinIO и Backblaze).
# Пароли приходят из env (SealedSecret net-backup-credentials), на диск не пишутся.
set -eu

DIR=${BACKUP_DIR:-/backup}
TS=$(date +%Y%m%d-%H%M%S)
KEEP_DAYS=30
mkdir -p "$DIR/keenetic" "$DIR/hp5130" "$DIR/monthly"

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

# 1-го числа кладём копию в monthly (хранится 13 месяцев), остальные файлы старше KEEP_DAYS чистим
if [ "$(date +%d)" = "01" ]; then
  cp "$DIR"/keenetic/running-config-"$TS".txt "$DIR"/hp5130/current-config-"$TS".txt "$DIR/monthly/" 2>/dev/null || true
fi
find "$DIR/keenetic" "$DIR/hp5130" -type f -name '*-20*.txt' -mtime +"$KEEP_DAYS" -delete
find "$DIR/monthly" -type f -mtime +400 -delete

exit $fail
