#!/usr/bin/env bash
# Генерирует производные файлы для apps/cert-site/site (mobileconfig, fingerprint, subject, not-after)
# из единого источника — ConfigMap infra/home-root-ca.yaml (ключ ca.crt). Сам root-ca.crt в сайт не копируется:
# deployment монтирует ConfigMap home-root-ca (Reflector кладёт его в ns apps).
#
# Usage: scripts/build-cert-site.sh            — пересобрать файлы в apps/cert-site/site
#        scripts/build-cert-site.sh --check    — проверить, что файлы соответствуют home-root-ca.yaml (CI)
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
site="$root/apps/cert-site/site"
mode=build; [[ "${1:-}" == "--check" ]] && mode=check

out="$site"; [[ $mode == check ]] && out="$(mktemp -d)"
crt="$(mktemp)"; trap 'rm -f "$crt"; [[ $mode == check ]] && rm -rf "$out"' EXIT

# ca.crt из ConfigMap: блок после `ca.crt: |`, отступ 4 пробела
sed -n '/^  ca\.crt: |/,/END CERTIFICATE/{/^  ca\.crt: |/d;s/^    //;p;}' "$root/infra/home-root-ca.yaml" >"$crt"
[[ -s "$crt" ]] || { echo "ca.crt not found in infra/home-root-ca.yaml" >&2; exit 1; }

# sanity: это именно сертификат CA, а не ключ
openssl x509 -in "$crt" -noout -text | grep -q 'CA:TRUE' || { echo "not a CA certificate" >&2; exit 1; }
! grep -q 'PRIVATE KEY' "$crt" || { echo "private key in file!" >&2; exit 1; }

fp="$(openssl x509 -in "$crt" -noout -fingerprint -sha256 | cut -d= -f2)"
subject="$(openssl x509 -in "$crt" -noout -subject -nameopt multiline | sed -n 's/^ *commonName *= *//p')"
not_after="$(openssl x509 -in "$crt" -noout -enddate | cut -d= -f2)"
der_b64="$(openssl x509 -in "$crt" -outform DER | base64 | tr -d '\n')"

# детерминированные UUID из отпечатка, чтобы пересборка не давала лишний diff
h="$(printf '%s' "$fp" | tr -d ':' | tr 'A-F' 'a-f')"
uuid() { printf '%s-%s-%s-%s-%s' "${h:$1:8}" "${h:$(($1+8)):4}" "4${h:$(($1+12)):3}" "a${h:$(($1+15)):3}" "${h:$(($1+18)):12}"; }
u_profile="$(uuid 0)"; u_cert="$(uuid 4)"

cat >"$out/root-ca.mobileconfig" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>PayloadContent</key>
  <array>
    <dict>
      <key>PayloadCertificateFileName</key><string>root-ca.crt</string>
      <key>PayloadContent</key><data>${der_b64}</data>
      <key>PayloadDescription</key><string>Корневой сертификат домашней сети</string>
      <key>PayloadDisplayName</key><string>${subject}</string>
      <key>PayloadIdentifier</key><string>ru.progist.home.rootca.cert</string>
      <key>PayloadType</key><string>com.apple.security.root</string>
      <key>PayloadUUID</key><string>${u_cert}</string>
      <key>PayloadVersion</key><integer>1</integer>
    </dict>
  </array>
  <key>PayloadDescription</key><string>Доверие к корневому сертификату *.home</string>
  <key>PayloadDisplayName</key><string>${subject}</string>
  <key>PayloadIdentifier</key><string>ru.progist.home.rootca</string>
  <key>PayloadOrganization</key><string>Progist</string>
  <key>PayloadRemovalDisallowed</key><false/>
  <key>PayloadType</key><string>Configuration</string>
  <key>PayloadUUID</key><string>${u_profile}</string>
  <key>PayloadVersion</key><integer>1</integer>
</dict>
</plist>
PLIST

printf '%s\n' "$fp" >"$out/fingerprint.txt"
printf '%s\n' "$subject" >"$out/subject.txt"
printf '%s\n' "$not_after" >"$out/not-after.txt"
if [[ $mode == check ]]; then
  for f in root-ca.mobileconfig fingerprint.txt subject.txt not-after.txt; do
    cmp -s "$out/$f" "$site/$f" || { echo "apps/cert-site/site/$f не соответствует infra/home-root-ca.yaml: запусти scripts/build-cert-site.sh" >&2; exit 1; }
  done
  echo "OK: cert-site соответствует home-root-ca ($fp)"
else
  echo "OK: $subject  sha256=$fp  until $not_after"
fi
