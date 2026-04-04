# Восстановление экспортеров на TrueNAS (bigb.home) после переустановки

## Что выживет после обновления TrueNAS

| Файл / компонент | Выживет? | Примечание |
|---|---|---|
| `/mnt/Fast/system/scripts/backup_monitoring2.py` | **да** | на пуле, вне OS |
| Кронджоба `backups.prom` в TrueNAS UI | **да** | хранится в middlewared |
| `/usr/local/bin/zfs_exporter` | **нет** | ручная установка, вне пакетов |
| `/etc/systemd/system/zfs-exporter.service` | **нет** | ручная установка |
| `/etc/default/prometheus-node-exporter` | **нет** | конфиг пакета, сбрасывается |
| `/usr/share/.../smartmon.sh` (патченый) | **нет** | пакет перезапишет оригиналом |
| `/var/lib/prometheus/node-exporter/*.prom` | **нет** | временная директория OS |
| `/usr/local/bin/promtail` | **нет** | ручная установка, вне пакетов |
| `/etc/promtail/config.yaml` | **нет** | ручная установка |
| `/etc/systemd/system/promtail.service` | **нет** | ручная установка |
| `/var/lib/promtail/positions.yaml` | **нет** | сбрасывается, пересоздаётся автоматически |
| `/etc/hosts` (запись `loki.home`) | **нет** | нужно добавить вручную |

---

## Быстрое восстановление после обновления

```bash
# 1. Установить пакеты
apt-get update
apt-get install -y prometheus-node-exporter prometheus-node-exporter-collectors smartmontools moreutils

# ЕСЛИ ошибка "The user `prometheus' already exists, but is not a system user":
#   userdel prometheus && apt-get install prometheus-node-exporter prometheus-node-exporter-collectors

# 2. Настроить node-exporter
cat > /etc/default/prometheus-node-exporter << 'EOF'
ARGS="--collector.textfile.directory=/var/lib/prometheus/node-exporter --collector.systemd"
EOF

# 3. Создать сервис zfs-exporter
cp /mnt/Fast/system/backup/zfs_exporter /usr/local/bin/zfs_exporter
chmod +x /usr/local/bin/zfs_exporter
chown node_exporter:node_exporter /usr/local/bin/zfs_exporter

cat > /etc/systemd/system/zfs-exporter.service << 'EOF'
[Unit]
Description=ZFS Exporter
After=network.target

[Service]
User=node_exporter
Group=node_exporter
Type=simple
ExecStart=/usr/local/bin/zfs_exporter
Restart=on-failure
RestartSec=10s
TimeoutStopSec=30s

[Install]
WantedBy=multi-user.target
EOF

# 4. Заменить smartmon.sh на NVMe-патченую версию из репозитория gitops
#    (файл: monitoring/kube-prometheus-stack/exporters/.smartmon.sh)
#    Скопировать на сервер и поместить:
cp smartmon.sh /usr/share/prometheus-node-exporter-collectors/smartmon.sh
chmod +x /usr/share/prometheus-node-exporter-collectors/smartmon.sh

# 5. Включить все сервисы
systemctl daemon-reload
systemctl enable --now prometheus-node-exporter
systemctl enable --now zfs-exporter
systemctl enable --now prometheus-node-exporter-smartmon.timer
# apt и nvme таймеры включаются автоматически с пакетом

# 6. Установить Promtail (версию взять из кластера: kubectl get pod -n monitoring -l app.kubernetes.io/name=promtail -o jsonpath='{.items[0].spec.containers[0].image}')
PROMTAIL_VERSION="3.5.1"
cd /tmp
curl -LO "https://github.com/grafana/loki/releases/download/v${PROMTAIL_VERSION}/promtail-linux-amd64.zip"
unzip promtail-linux-amd64.zip
chmod +x promtail-linux-amd64
mv promtail-linux-amd64 /usr/local/bin/promtail
mkdir -p /etc/promtail /var/lib/promtail

cat > /etc/promtail/config.yaml << 'EOF'
server:
  http_listen_port: 9080
  grpc_listen_port: 0
  log_level: warn

positions:
  filename: /var/lib/promtail/positions.yaml

clients:
  - url: http://loki.home/loki/api/v1/push

scrape_configs:
  - job_name: host-journal
    journal:
      max_age: 12h
      path: /var/log/journal
      labels:
        job: host-journal
        hostname: bigb.home
    relabel_configs:
      # Оставляем только WARNING и выше (0=emerg, 1=alert, 2=crit, 3=err, 4=warning)
      - source_labels: ['__journal__priority']
        regex: '[0-4]'
        action: keep
      - source_labels: ['__journal__transport']
        target_label: transport
      - source_labels: ['__journal__systemd_unit']
        target_label: unit
EOF

cat > /etc/systemd/system/promtail.service << 'EOF'
[Unit]
Description=Promtail (kernel log forwarder to Loki)
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/promtail -config.file=/etc/promtail/config.yaml
Restart=on-failure
RestartSec=10s

[Install]
WantedBy=multi-user.target
EOF

# DNS для loki.home (Traefik LoadBalancer)
grep -q "loki.home" /etc/hosts || echo "10.0.0.2 loki.home" >> /etc/hosts

systemctl daemon-reload
systemctl enable --now promtail

# 7. Проверить
systemctl status prometheus-node-exporter zfs-exporter prometheus-node-exporter-smartmon.timer promtail
ss -tlnp | grep -E "9100|9134"
curl -s http://localhost:9100/metrics | grep "node_textfile_scrape_error"
```

> **Источник zfs_exporter бинарника:** хранится в `backup/truenas-exporters/zfs_exporter` в gitops-репозитории (MD5: `6ffdbbb4fadd3df6c301610f036a1ddc`). Также можно скачать с https://github.com/pdf/zfs_exporter/releases (версия 2.3.10).

---

## Установленные экспортеры

### 1. Prometheus Node Exporter

- **Порт:** 9100
- **Сервис:** `prometheus-node-exporter.service`
- **Бинарник:** `/usr/bin/prometheus-node-exporter`
- **Конфигурация:** `/etc/default/prometheus-node-exporter`
- **Аргументы:** `--collector.textfile.directory=/var/lib/prometheus/node-exporter --collector.systemd`
- **MD5 конфига:** `b7c683f713cbfd23a9d8ce4e2cac2517`

**Установка:**
```bash
apt-get install prometheus-node-exporter prometheus-node-exporter-collectors

cat > /etc/default/prometheus-node-exporter << 'EOF'
ARGS="--collector.textfile.directory=/var/lib/prometheus/node-exporter --collector.systemd"
EOF

systemctl enable --now prometheus-node-exporter
```

### 2. ZFS Exporter

- **Порт:** 9134
- **Сервис:** `zfs-exporter.service`
- **Бинарник:** `/usr/local/bin/zfs_exporter`
- **Пользователь:** `node_exporter:node_exporter`
- **Версия:** 2.3.10
- **MD5 бинарника:** `6ffdbbb4fadd3df6c301610f036a1ddc`
- **Бэкап:** `backup/truenas-exporters/zfs_exporter` в gitops

**Установка:**
```bash
# Бинарник из бэкапа репозитория или с GitHub releases
cp zfs_exporter /usr/local/bin/zfs_exporter
chmod +x /usr/local/bin/zfs_exporter
chown node_exporter:node_exporter /usr/local/bin/zfs_exporter

# Сервис — см. backup/truenas-exporters/zfs-exporter.service
cp zfs-exporter.service /etc/systemd/system/zfs-exporter.service
systemctl daemon-reload
systemctl enable --now zfs-exporter
```

### 3. SMART Monitor (smartmon.sh)

- **Скрипт:** `/usr/share/prometheus-node-exporter-collectors/smartmon.sh`
- **Таймер:** `prometheus-node-exporter-smartmon.timer` (из пакета `prometheus-node-exporter-collectors`)
- **Интервал:** каждые 15 минут
- **Выходной файл:** `/var/lib/prometheus/node-exporter/smartmon.prom`
- **MD5 патченой версии (в репозитории):** `f84f7d773f4c0912ef20f97497b86d97`
- **MD5 оригинала из пакета:** `082a024628974f38ef5bb48c3d07a796`

Скрипт из пакета не поддерживает NVMe-диски. После установки пакета нужно заменить его патченой версией из репозитория:

```bash
# Файл в репозитории: monitoring/kube-prometheus-stack/exporters/.smartmon.sh
cp .smartmon.sh /usr/share/prometheus-node-exporter-collectors/smartmon.sh
chmod +x /usr/share/prometheus-node-exporter-collectors/smartmon.sh

systemctl enable --now prometheus-node-exporter-smartmon.timer
```

**Что делает патч:** добавлена функция `parse_smartctl_nvme_attributes` и обнаружение секции `START OF SMART DATA SECTION` для NVMe-дисков.

> **Известный баг в скрипте:** в функции `parse_smartctl_scsi_attributes` строка записи `total_lbas_written_raw_value` содержит обрыв переменной `${labels}` с вставленным URL. Это значит метрика `lbas_written` не выводится для SCSI-дисков. Баг присутствует и в репозитории, и на сервере.

### 4. Promtail (Kernel Log Forwarder)

- **Порт:** 9080 (внутренний, не скрапится Prometheus)
- **Сервис:** `promtail.service`
- **Бинарник:** `/usr/local/bin/promtail`
- **Конфиг:** `/etc/promtail/config.yaml`
- **Positions:** `/var/lib/promtail/positions.yaml`
- **Назначение:** отправка host-журнала journald в Loki (`loki.home`) для алертинга на soft lockup, OOM kill, hung task, call trace, ZFS errors, SMART errors
- **Фильтр:** `PRIORITY<=4` (warning+) по всем транспортам — kernel, ZFS, nfsd, smartd, сетевые демоны
- **Версия:** должна совпадать с Promtail в k3s-кластере (`kubectl get pod -n monitoring -l app.kubernetes.io/name=promtail -o jsonpath='{.items[0].spec.containers[0].image}'`)

**Предпосылки:**
- В `/etc/hosts` должна быть запись `10.0.0.2 loki.home` (Traefik LoadBalancer)
- В кластере должен быть Ingress `loki-internal` в namespace `monitoring` (файл `monitoring/loki/ingress-internal.yaml` в gitops)

**Установка:** см. шаг 6 в разделе "Быстрое восстановление".

**Проверка:**
```bash
# Сервис запущен
systemctl status promtail

# Связь с Loki работает
curl -s -o /dev/null -w "%{http_code}" http://loki.home/loki/api/v1/push \
  -H 'Content-Type: application/json' \
  -d "{\"streams\":[{\"stream\":{\"test\":\"1\"},\"values\":[[\"$(date +%s%N)\",\"test\"]]}]}"
# Ожидается: 204

# Логи Promtail (ошибки или успех)
journalctl -u promtail -n 20 --no-pager

# Генерация тестового kernel-события и проверка в Grafana
modprobe -r dummy 2>/dev/null; modprobe dummy numbs=1 && sleep 15 && modprobe -r dummy
# Затем в Grafana Explore → Loki: {hostname="bigb.home", job="kernel"}
```

---

### 5. Textfile-коллекторы из пакета (автоматические)

Устанавливаются с `prometheus-node-exporter-collectors` и запускаются таймерами автоматически:

| Файл | Таймер | Интервал |
|---|---|---|
| `smartmon.prom` | `prometheus-node-exporter-smartmon.timer` | 15 мин |
| `apt.prom` | `prometheus-node-exporter-apt.timer` | 15 мин |
| `nvme.prom` | `prometheus-node-exporter-nvme.timer` | 15 мин |

### 6. Мониторинг бэкапов (backups.prom)

- **Файл:** `/var/lib/prometheus/node-exporter/backups.prom`
- **Источник:** кронджоба в TrueNAS UI — **выживает после обновления**
- **Расписание:** `0 * * * *` (каждый час)
- **Скрипт:** `/mnt/Fast/system/scripts/backup_monitoring2.py /mnt/Main/Backup`

Этот коллектор не требует восстановления после обновления TrueNAS.

---

## Порты и доступность

- **9100** — prometheus-node-exporter
- **9134** — zfs_exporter
- **9080** — promtail (внутренний, не скрапится Prometheus)

9100 и 9134 слушают на `0.0.0.0` (все интерфейсы). 9080 используется только локально.

---

## Проверка после восстановления

```bash
# Статус сервисов
systemctl status prometheus-node-exporter zfs-exporter prometheus-node-exporter-smartmon.timer promtail

# Порты
ss -tlnp | grep -E "9100|9134"

# Метрики node-exporter (должен быть 0 ошибок textfile)
curl -s http://localhost:9100/metrics | grep node_textfile_scrape_error

# Метрики ZFS
curl -s http://localhost:9134/metrics | grep zfs_pool_health

# Smartmon
cat /var/lib/prometheus/node-exporter/smartmon.prom | head -5

# Promtail — связь с Loki
curl -s -o /dev/null -w "%{http_code}\n" http://loki.home/loki/api/v1/push \
  -H 'Content-Type: application/json' \
  -d "{\"streams\":[{\"stream\":{\"test\":\"1\"},\"values\":[[\"$(date +%s%N)\",\"test\"]]}]}"
# Ожидается: 204
```

---

## Решение проблем при установке

### Ошибка: "prometheus user already exists, but is not a system user"

```bash
# Проверить
getent passwd prometheus
ps aux | grep prometheus | grep -v grep  # убедиться что нет запущенных процессов

# Удалить и переустановить
userdel prometheus
apt-get install prometheus-node-exporter prometheus-node-exporter-collectors

# Проверить что пользователь системный
getent passwd prometheus
# Должно: prometheus:x:NNN:NNN:...:/var/lib/prometheus:/usr/sbin/nologin
```

### Проверить MD5 установленных файлов

```bash
md5sum /usr/local/bin/zfs_exporter
# Ожидается: 6ffdbbb4fadd3df6c301610f036a1ddc

md5sum /usr/share/prometheus-node-exporter-collectors/smartmon.sh
# Ожидается (патченая версия): f84f7d773f4c0912ef20f97497b86d97
# Если оригинал из пакета: 082a024628974f38ef5bb48c3d07a796 — нужно заменить!

md5sum /etc/default/prometheus-node-exporter
# Ожидается: b7c683f713cbfd23a9d8ce4e2cac2517
```
