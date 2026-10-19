# mDNS-reflector на k3s-pi (AirPlay между Home и Media)

Не Flux: ставится вручную на `k3s-pi`, примеры конфигов лежат здесь (как `infra/nodes/crowdsec/`).

## Зачем

AirPlay-приёмники (Apple TV `Гостиная`, саундбар Samsung) стоят в Media (VLAN 60), iPhone/Mac в Home (VLAN 30).
mDNS мультикаст не выходит за VLAN, а повторитель mDNS на Keenetic работает только если сегмент получает «доступ к приложениям
роутера» (фактически `private`), то есть открывает роутер (веб, telnet) устройствам Media. Поэтому reflector вынесен на Pi.

## Как устроено

- Порт Pi на HP (`GE1/0/20`): hybrid, PVID 20 без тега + теги 30, 60, 90.
  ```
  interface GigabitEthernet1/0/20
   description k3s-pi
   port link-type hybrid
   undo port hybrid vlan 1
   port hybrid vlan 30 60 90 tagged
   port hybrid vlan 20 untagged
   port hybrid pvid vlan 20
  ```
- VLAN-интерфейсы `vlan30`, `vlan60` и `vlan90` создаются на `eth0`, но живут **внутри сетевого пространства имён `mdns`** (`10.77.30.199`, `10.77.60.199`, `10.77.90.199`).
  В основном netns Pi адресов в Home/Media нет: иначе ответы Pi на трафик из Home пошли бы мимо Keenetic (асимметрия) и сломали бы Blocky/Traefik/tailscale.
  В netns нет форвардинга, Pi между VLAN ничего не маршрутизирует.
- Отдельный `avahi-daemon` в этом netns (`enable-reflector=yes`, `disable-publishing`), юнит `avahi-mdns.service`.
  Штатный `avahi-daemon` хоста отключён (`systemctl disable --now avahi-daemon.service avahi-daemon.socket`).
- На Keenetic повторитель mDNS выключен (иначе два повторителя гоняют пакеты по кругу), Media остаётся `protected`.

## Установка

```
sudo modprobe 8021q && echo 8021q | sudo tee /etc/modules-load.d/8021q.conf
sudo install -m 755 mdns-netns.sh /usr/local/sbin/mdns-netns.sh
sudo install -m 644 avahi-mdns.conf /etc/avahi/avahi-mdns.conf
sudo install -m 644 avahi-mdns.service /etc/systemd/system/avahi-mdns.service
sudo systemctl disable --now avahi-daemon.service avahi-daemon.socket
sudo systemctl daemon-reload && sudo systemctl enable --now avahi-mdns
```

Проверка: `sudo ip netns exec mdns ip -br addr`, `journalctl -u avahi-mdns`, с Mac из Home `dns-sd -B _raop._tcp local`.

## Особенности

- Ключи `disable-publishing`/`disable-user-service-publishing` относятся к секции `[publish]`, не `[server]` (иначе Avahi падает с `Invalid configuration key`).
- Саундбар Samsung (Q-Series) объявляет хост как `localhost.local` и динамический порт AirPlay, это нормально для iPhone.
- **NAT между сегментами ломает AirPlay 2.** Keenetic подменяет источник у пакетов, выходящих из сегмента с `ip nat`
  (в т.ч. между сегментами): колонка видела iPhone как `10.77.60.1`, iPhone колонку как `10.77.30.1`, PTP (юникаст UDP 319/320)
  не сходился, звука не было (диагностика: зеркалирование `GE1/0/23` на Mac + `show ip nat`). Лечится на Keenetic CLI:
  ```
  ip static Bridge5 ISP
  no ip nat Bridge5
  system configuration save
  ```
  (NAT остаётся только при выходе через ISP; Bridge5 = Media). Home (`Bridge2`) оставлен с NAT, звук идёт и так.
  Для Home (`Bridge2`) и Guest (`Bridge6`) применена та же схема (`ip static BridgeN ISP` + `no ip nat BridgeN`). Сервера (`Bridge1`) не трогать без проверки: выход всего кластера и VPN до VPS.
- Правило Media -> Home должно пускать минимум UDP 319/320; колонка сама инициирует только PTP.
- Гости (VLAN 90) отражаются тем же экземпляром; в Keenetic Guest разрешён только к адресам приёмников `10.77.60.11-13`.

## TODO / планы

- Рассмотреть перенос reflector на `k3s-yolki` (N100, ближе к HA, больше памяти, чем у Pi): trunk (теги 30, 60) на порт yolki на HP, те же файлы,
  потом выключить `avahi-mdns` на Pi и вернуть порт Pi в access 20. Пока живёт на Pi.
- Правило `mdns` (UDP 5353 любой) на Media в Keenetic больше не нужно, удалить.

## Откат

```
sudo systemctl disable --now avahi-mdns
sudo ip netns del mdns
sudo systemctl enable --now avahi-daemon.service avahi-daemon.socket
```
На HP порт вернуть в access: `port link-type access`, `port access vlan 20`.
