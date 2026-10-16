# UPS APC Smart-UPS 1500 (NUT на k3s-yolki)

UPS подключён по USB к **k3s-yolki** (`051d:0003`, firmware `UPS 09.3`). Штатный `usbhid-ups` не используется:
данные отдаёт драйвер **`apc_modbus`** (NUT 2.8.1), в пакете Ubuntu 24.04 (`nut 2.8.1-3.1ubuntu2`) его нет — собран вручную.
Всё, что нужно для воспроизведения, лежит в `backup/nut-ups/`.

## Что где

| Файл в репо | Куда на yolki | Назначение |
|---|---|---|
| `backup/nut-ups/apc_modbus` | `/lib/nut/apc_modbus` (0755) | собранный драйвер (sha256 `4cc03220…256d`) |
| `backup/nut-ups/ups.conf` | `/etc/nut/ups.conf` (`root:nut`, 0640) | `driver = apc_modbus`, `user = nut` |
| `backup/nut-ups/nut-exporter.service` | `/etc/systemd/system/` | Prometheus exporter, порт `:9199` |
| `backup/nut-ups/install-exporter.sh` | — | скачивает `nut_exporter` v3.3.0 (sha256 проверяется) и ставит юнит |
| `monitoring/…/scrapeconfigs/ups.yaml` | кластер | job `ups` → `vps.yolki:9199/ups_metrics?ups=apc` |
| `monitoring/…/rules/ups.yaml` | кластер | алерты `UPS*` |
| `monitoring/…/dashboards/ups.yaml` | кластер | Grafana-дашборд «UPS APC (yolki)» (папка Infrastructure), основа — grafana.com/dashboards/23699, подогнан под 240 В и `ups.realpower` |

Дополнительно:
- Drop-in `/etc/systemd/system/nut-driver@apc.service.d/nut-driver-enumerator-generated.conf` генерируется сам
  (`nut-driver-enumerator`); в нём `NUT_CONFPATH=/etc/nut`, `NUT_STATEPATH=/run/nut`. Без этих переменных драйвер,
  собранный с префиксом `/usr/local/ups`, не видит `/etc/nut` (ошибка `Can't open /usr/local/ups/etc/ups.conf`).
- `/etc/nut/nut.conf`: `MODE=netserver` (если будут клиенты) или `standalone`; `upsd.conf`: `LISTEN 127.0.0.1 3493`
  (экспортёр ходит на localhost). Секретные `upsd.users`/`upsmon.conf` в репо не кладём.

## Сборка драйвера (если нужно пересобрать)

```sh
# libmodbus статически, пакета с nut-modbus-драйвером нет
./configure --with-drivers=apc_modbus --with-usb --with-modbus \
  --with-modbus-includes=-I$HOME/apc-build/local/include/modbus \
  '--with-modbus-libs=$HOME/apc-build/local/lib/libmodbus.a -lusb-1.0'
make -C drivers apc_modbus        # исходники NUT v2.8.1 (tag, commit 4ba352d)
sudo install -m 755 drivers/apc_modbus /lib/nut/
```
Проверка в foreground:
`sudo env NUT_STATEPATH=/tmp ./drivers/apc_modbus -u root -s apctest -x port=auto -x porttype=usb -x vendorid=051d -x productid=0003 -x slaveid=1 -d 1`
(перед этим `systemctl stop nut-driver@apc`).

## Установка экспортёра

```sh
# на k3s-yolki, из каталога backup/nut-ups
sudo ./install-exporter.sh
curl -s 'http://127.0.0.1:9199/ups_metrics?ups=apc' | grep -E 'ups_status|battery_charge'
```
Названия метрик в правилах (`network_ups_tools_ups_status{flag="OB"}`, `…_battery_charge`, `…_battery_runtime`,
`…_ups_load`) — стандартные для `nut_exporter`; сверить с реальным выводом после установки.

## Восстановление после переустановки yolki
1. `apt install nut-server nut-client`
2. Положить `apc_modbus` в `/lib/nut/`, `ups.conf` — в `/etc/nut/` (`chown root:nut`, `chmod 640`)
3. `systemctl enable --now nut-driver-enumerator.service nut-server nut-monitor` (генерирует drop-in драйвера)
4. udev: доступ пользователя `nut` к `051d:0003` (в тесте работало и без правила, т.к. `nut-driver` идёт от root → `user=nut`; при `Permission denied` добавить `SUBSYSTEM=="usb", ATTR{idVendor}=="051d", ATTR{idProduct}=="0003", GROUP="nut", MODE="0660"`)
5. `sudo ./install-exporter.sh`

## Политика выключения

Исходные данные: нагрузка ~16–18% (~170–180 Вт), автономия ~15 мин (`battery.runtime` 840–900 с). От APC питаются TrueNAS
(на нём VM `k3sprod`, `k3s_gpu`), yolki, pi. Ippon в прошлом, не используется.

Схема: **yolki — единственный master** (`upsd`, USB-кабель). Клиенты (`upsmon secondary`) по сети `10.77.20.6:3493`:
TrueNAS (UI: UPS → Slave), k3s-pi (`nut-client`). VM k3s-prod/k3s-gpu отдельных клиентов не имеют: их корректно гасит TrueNAS.

Цепочка при пропаже питания:
1. `ONBATT` → алерт `UPSOnBattery`; таймер 300 с в `upssched` (при `ONLINE` отменяется).
2. Через 5 мин таймер → `upsmon -c fsd` (скрипт `upssched-cmd`). Страховка: событие `LOWBATT` → то же сразу.
3. FSD получают TrueNAS и pi и гасятся. TrueNAS останавливает VM (shutdown_timeout: `k3sprod` 180 с, `k3s_gpu` 90 с), поэтому
   на prod/gpu обязателен **graceful node shutdown** kubelet (см. ниже), иначе поды получат SIGKILL при отключении VM.
4. Master (yolki) по `HOSTSYNC` ждёт отключения клиентов от `upsd` и запускает `SHUTDOWNCMD` =
   `nut-shutdown-last.sh`: ждёт до 8 мин, пока `bigb` (10.77.20.4) и `pi` (10.77.20.5) перестанут пинговаться
   (клиент отключается от `upsd` раньше, чем TrueNAS доостановит VM), затем `shutdown -h`.
5. Если включён `allow_killpower`, при `/etc/killpower` UPS отключает выход и **включает его заново при появлении
   сети** (`shutdown.return`). Это нужно, чтобы TrueNAS/yolki/pi поднялись сами, если питание вернулось, пока UPS не отдавал
   выход: BIOS «power on after AC loss» срабатывает только при реальной потере питания на входе сервера.

Параметры: `DEADTIME 60` (на yolki/pi; в UI TrueNAS этого поля нет), `HOSTSYNC 15`, `FINALDELAY 5`.
Reboot yolki при питании от сети безопасен: клиенты пишут `COMMBAD`, но не выключаются (выключение только если связь потеряна **во время** работы от батареи).

### Файлы (backup/nut-ups/)
| Файл | Куда |
|---|---|
| `yolki/nut.conf`, `upsd.conf` | `/etc/nut/` (master, `MODE=netserver`, LISTEN localhost + 10.77.20.6) |
| `yolki/upsd.users.example` | `/etc/nut/upsd.users`, пароли подставить |
| `yolki/upsmon.conf.example` | основа `/etc/nut/upsmon.conf`, пароль подставить |
| `yolki/upssched.conf`, `upssched-cmd` | `/etc/nut/upssched.conf`, `/usr/local/sbin/upssched-cmd` (0755) |
| `yolki/nut-shutdown-last.sh` | `/usr/local/sbin/nut-shutdown-last.sh` (0755) |
| `pi/nut.conf`, `upsmon.conf.example` | pi: `apt install nut-client`, `/etc/nut/` |

Флаги на yolki (`sudo ./setup-yolki.sh` создаёт оба):
- `/etc/nut/dry-run` — `upssched-cmd` не объявляет FSD, только пишет в `journalctl -t nut`;
- `/etc/nut/no-poweroff` — FSD настоящий, но `nut-shutdown-last.sh` не выключает саму yolki.
Сквозной тест без выключений: `rm /etc/nut/dry-run`, `SHUTDOWNCMD` у TrueNAS (UI) и pi временно `/usr/bin/logger -t nut FSD-TEST-NO-SHUTDOWN`,
затем `sudo upsmon -c fsd` на yolki. После теста: `sudo systemctl restart nut-server` (сбрасывает флаг FSD), `sudo rm -f /etc/killpower`,
вернуть реальные `SHUTDOWNCMD`, удалить `no-poweroff`.

### TrueNAS (UI → Services → UPS), SCALE
Identifier `apc`; Mode **Slave**; Remote Host `10.77.20.6`, Port `3493`; Monitor User `truenas` + пароль;
Shutdown Mode «UPS reaches low battery»; **Shutdown Command `/sbin/shutdown -P now`** (на Linux нет опции `-p`,
`/sbin/shutdown` — симлинк на `systemctl`); Power Off UPS — выкл; No Communication Warning Time 300; Host Sync 15.
Поле «Port or Hostname» (`/dev/uhid`) в Slave не используется, очистить. Aux-параметры пусты.
VM: `k3sprod` shutdown_timeout 180 с, `k3s_gpu` 90 с, оба `autostart=true`.

### Graceful node shutdown на k3s-prod/k3s-gpu (в окно обслуживания!)
```
# /etc/rancher/k3s/config.yaml, kubelet-arg
  - "shutdown-grace-period=90s"
  - "shutdown-grace-period-critical-pods=30s"
# /etc/systemd/logind.conf.d/nut.conf
  [Login]
  InhibitDelayMaxSec=90
```
Требует `systemctl restart k3s` (на prod — с последствиями: см. «после рестарта k3s» ниже), потом `systemctl restart systemd-logind`.
Проверка: `journalctl -u k3s | grep -i "shutdown manager"`.

### Запуск без UPS-питания (WoL)
Основной путь — power cycle от UPS (п. 5). WoL на TrueNAS **не работает**: на `enp3s0` (рабочий порт)
`Supports Wake-on: d` (WoL не поддерживается), WoL умеет только `enp4s0` (`pumbg`), но он без линка. Если нужен запасной вариант,
подключить `enp4s0` к коммутатору (VLAN 20), включить `ethtool -s enp4s0 wol g` (post-init в UI) и в BIOS включить WoL.

### После рестарта k3s на prod
Рестарт k3s оставляет живые поды с битым netns (CrashLoop, пробы `no route to host`) и ломает цепочки tailscale на `tailscale-router-1`:
пересоздать CrashLoop-поды (БД первой: `apps-pg-1`), затем `tailscale-router-1`, проверить `crowdsec-firewall-bouncer`.

### Что ещё решить
- `allow_killpower` (`driver.flag.allow_killpower=1`) — включать только после теста power cycle.
- BIOS yolki и TrueNAS: «Restore on AC Power Loss = Power On» (оба сказали, что включено).
