# MinIO S3 Storage

MinIO развернут в namespace `infra` и используется как S3-совместимое хранилище для:
- **k8up** - резервное копирование PVC
- **Loki** - хранение логов
- другие сервисы, требующие S3-совместимого storage

## Доступ

- **Админка (консоль)**: https://minio.home
- **S3 API**: 
  - Внутри кластера: `http://minio.infra.svc.cluster.local:9000`
  - Снаружи через NodePort: `http://<node-ip>:30900`
- **Консоль снаружи**: `http://<node-ip>:30901`

## Управление бакетами и аккаунтами

### Декларативный подход (рекомендуется)

Бакеты и базовые настройки управляются через `setup-job.yaml`. Для добавления нового бакета:

1. Отредактируйте `setup-job.yaml`
2. Добавьте команду создания бакета:
   ```yaml
   mc mb minio/my-new-bucket --ignore-existing || true
   ```
3. Примените изменения - Job автоматически пересоздастся и выполнит настройку

**Важно**: Job идемпотентен - можно запускать многократно без ошибок.

Для повторного запуска вручную:
```bash
kubectl delete job minio-setup -n infra
kubectl apply -f infra/minio/setup-job.yaml
```

### Через админку (для разовых операций)

1. Откройте https://minio.home
2. Войдите с учетными данными из `minio-secrets`
3. Создавайте бакеты, пользователей, политики через веб-интерфейс

### Через MinIO Client (mc)

Для интерактивного управления можно использовать mc в поде:

```bash
# Подключиться к поду MinIO
kubectl exec -it deployment/minio -n infra -- sh

# Или использовать отдельный под с mc
kubectl run -it --rm mc --image=minio/mc:latest --restart=Never -- sh

# Настроить alias
mc alias set minio http://minio.infra.svc.cluster.local:9000 \
  "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD"

# Создать бакет
mc mb minio/my-bucket

# Список бакетов
mc ls minio

# Создать пользователя
mc admin user add minio myuser mypassword

# Прикрепить политику
mc admin policy attach minio readwrite --user myuser
```

## Интеграция с сервисами

### k8up (резервное копирование)

Для использования MinIO как бэкенда для k8up нужно настроить S3 бэкенд в конфигурации k8up:

```yaml
backend:
  s3:
    endpoint: http://minio.infra.svc.cluster.local:9000
    bucket: k8up-backups
    accessKeyID: <access-key>
    secretAccessKey: <secret-key>
```

### Loki (логи)

Централизованный `setup-job.yaml` автоматически создает:
- Bucket `loki`
- Пользователя `loki-user` с ограниченными правами
- Политику доступа только к bucket `loki`

Для этого требуется secret `loki-secrets` в namespace `infra` с ключом `minio-password`.

Loki подключается к MinIO через:
```yaml
storage_config:
  aws:
    s3: http://loki-user:PASSWORD@minio.infra.svc.cluster.local:9000/loki
    s3forcepathstyle: true
    insecure: true
```

## Хранилище

- **Путь на NFS**: `/mnt/Main/k3s-data/minio/storage`
- **StorageClass**: `nfs-hdd-manual`
- **Размер**: 500Gi (можно увеличить в `storage.yaml`)

## Секреты

Секреты хранятся в `sealed-secrets/infra/minio/`:
- `minio-secrets` - root пользователь и пароль для MinIO

Для создания/обновления секретов используйте `minio-secrets-template.yaml` и kubeseal.

