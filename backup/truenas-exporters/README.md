# Backup экспортеров TrueNAS (bigb.home)

## Файлы

- `zfs_exporter` - бинарник zfs_exporter версии 2.3.10 (18MB)
- `smartmon.sh.original` - оригинальный скрипт из пакета prometheus-node-exporter-collectors
- `zfs-exporter.service` - systemd unit для zfs_exporter
- `prometheus-node-exporter-smartmon.service` - systemd unit для smartmon (из пакета)
- `prometheus-node-exporter-smartmon.timer` - systemd timer для smartmon (из пакета)
- `prometheus-node-exporter` - конфигурация node-exporter

## Восстановление

См. `docs/truenas-exporters.md` в репозитории.

Патченая версия smartmon.sh (с NVMe-поддержкой) хранится в:
`monitoring/kube-prometheus-stack/exporters/.smartmon.sh`

## MD5 суммы

```
b7c683f713cbfd23a9d8ce4e2cac2517  backup/truenas-exporters/prometheus-node-exporter
4b115ca2d7325eebfa62c1e6e6ef18c7  backup/truenas-exporters/prometheus-node-exporter-smartmon.service
52131bd63b88abd500648360d371699b  backup/truenas-exporters/prometheus-node-exporter-smartmon.timer
082a024628974f38ef5bb48c3d07a796  backup/truenas-exporters/smartmon.sh.original   ← ОРИГИНАЛ из пакета
f84f7d773f4c0912ef20f97497b86d97  monitoring/kube-prometheus-stack/exporters/.smartmon.sh  ← ПАТЧЕНАЯ версия (NVMe)
edc3b945b45d330bd50df7bd8b7b212e  backup/truenas-exporters/zfs-exporter.service
6ffdbbb4fadd3df6c301610f036a1ddc  backup/truenas-exporters/zfs_exporter
```
