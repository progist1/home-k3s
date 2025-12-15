# K8up Backup Operator

K8up - оператор Kubernetes для автоматического резервного копирования PVC в S3-совместимое хранилище (MinIO).

## Установка

K8up устанавливается в два этапа:

1. **CRD устанавливаются отдельно** через `clusters/home/k8up-crds.yaml` (Kustomization)
   - **Вариант 1 (активно)**: CRD загружаются через Job из GitHub release (HTTP)
     - Job автоматически скачивает и применяет CRD при каждом reconcile
     - Не требует хранения большого файла в Git
   - **Вариант 2 (альтернатива)**: CRD хранятся в Git (`infra/k8up/crds/k8up-crd.yaml`)
     - Раскомментируйте в `infra/k8up/crds/kustomization.yaml`: `resources: - k8up-crd.yaml`
     - Закомментируйте `resources: - job.yaml`
   - **Важно**: CRD должны быть установлены перед HelmRelease

2. **Оператор устанавливается через HelmRelease** в `infra/k8up/install/helm-release.yaml`
   - HelmRelease настроен на пропуск CRD (`install.crds: Skip`, `upgrade.crds: Skip`)
   - Зависит от `k8up-crds` Kustomization

### Обновление CRD

**Если используете Job (вариант 1):**
1. Обновите версию в `infra/k8up/crds/job.yaml` (строка с `k8up-4.8.6`)
2. Обновите версию в HelmRelease (`infra/k8up/install/helm-release.yaml`)
3. Flux автоматически пересоздаст Job и установит новые CRD

**Если используете Git (вариант 2):**
1. Скачайте новую версию CRD:
   ```bash
   curl -L https://github.com/k8up-io/k8up/releases/download/k8up-<VERSION>/k8up-crd.yaml \
     -o infra/k8up/crds/k8up-crd.yaml
   ```
2. Обновите версию в HelmRelease (`infra/k8up/install/helm-release.yaml`)

**Важно**: Всегда обновляйте CRD перед обновлением Helm release!

## Конфигурация

### Backend (MinIO S3)

K8up настроен на использование MinIO как S3 бэкенда:
- **Endpoint**: `http://minio.infra.svc.cluster.local:9000`
- **Bucket**: `k8up-backups`
- **Credentials**: хранятся в `k8up-secrets` (SealedSecret)

### SealedSecret для k8up

Секреты для доступа k8up к MinIO хранятся в:
- `sealed-secrets/infra/k8up/k8up-secrets-sealed.yaml`

**Содержимое секрета:**
- `access-key` - Access Key для MinIO S3
- `secret-key` - Secret Key для MinIO S3
- `repo-password` - **Пароль репозитория Restic для шифрования бэкапов** (обязательно!)

Для создания/обновления:
1. Создайте template файл `k8up-secrets-template.yaml`:
   ```yaml
   apiVersion: v1
   kind: Secret
   metadata:
     name: k8up-secrets
     namespace: infra
   type: Opaque
   stringData:
     access-key: "your-minio-access-key"
     secret-key: "your-minio-secret-key"
     repo-password: "your-strong-restic-password"  # ⚠️ КРИТИЧНО: сохраните этот пароль!
   ```
2. Примените: `kubectl apply -f k8up-secrets-template.yaml`
3. Зашифруйте: `kubeseal --cert cert.pem < k8up-secrets-template.yaml -o yaml > k8up-secrets-sealed.yaml`
4. Удалите template файл

**Важно**: 
- Пользователь k8up создается автоматически в MinIO через `infra/minio/setup-job.yaml` при первом запуске.
- **Пароль репозитория (`repo-password`) критически важен** - без него невозможно расшифровать бэкапы! Сохраните его в безопасном месте (например, в менеджере паролей).

### Шифрование бэкапов

K8up использует **Restic** для шифрования бэкапов на стороне клиента. Все данные шифруются **перед** отправкой в S3/MinIO.

**Как это работает:**
1. Restic шифрует данные локально с помощью пароля репозитория (`repo-password`)
2. Зашифрованные данные отправляются в S3/MinIO
3. Даже если кто-то получит доступ к S3, без пароля репозитория данные нельзя расшифровать

**Где хранится ключ шифрования:**
- Пароль репозитория хранится в Kubernetes Secret: `k8up-secrets` (ключ `repo-password`)
- Secret зашифрован через SealedSecrets и хранится в Git: `sealed-secrets/infra/k8up/k8up-secrets-sealed.yaml`
- Пароль передается в каждый Schedule через `repoPasswordSecretRef` в конфигурации backend

**Важно:**
- ⚠️ **Потеря пароля = потеря всех бэкапов!** Сохраните пароль в безопасном месте.
- Пароль должен быть одинаковым для всех Schedule, использующих один репозиторий (один бакет)
- Для разных бакетов можно использовать разные пароли (но обычно используют один)

## Использование

### Автоматический бэкап PVC

Для автоматического бэкапа PVC добавьте аннотацию:

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: my-pvc
  namespace: apps
  annotations:
    k8up.io/backup: "true"
```

**Важно**: K8up выбирает Schedule по namespace. Все Schedule в namespace `apps` будут применяться ко всем PVC в этом namespace (с аннотацией `k8up.io/backup: "true"`).

Если у вас несколько Schedule в одном namespace, они будут работать **параллельно** - один PVC может бэкапиться в несколько мест одновременно.

### Расписание бэкапов

#### Глобальное расписание (`generic-pvc-backup`)
- **Backup**: каждый день в 3:00 (можно изменить на 4 раза в день: `"0 */6 * * *"`)
- **Prune**: каждое воскресенье в 4:00
- Применяется ко всем PVC с аннотацией `k8up.io/backup: "true"` в namespace `apps`

**Retention настройки** (не конфликтуют, дополняют друг друга):
- `keepLast: 7` - всегда хранить последние 7 снимков
- `keepDaily: 14` - по одному снимку в день за последние 14 дней
- `keepWeekly: 8` - по одному снимку в неделю за последние 8 недель
- `keepMonthly: 6` - по одному снимку в месяц за последние 6 месяцев

**Итого сохранится**: последние 7 + ~14 ежедневных + ~8 еженедельных + ~6 ежемесячных снимков

#### Разнесение бэкапов по времени (staggering)

K8up поддерживает специальные макросы с рандомизацией для распределения нагрузки:

**K8up-специфичные макросы:**
- `@hourly-random` - каждый час, случайная минута (например: `52 * * * *`)
- `@daily-random` - каждый день, случайное время (например: `52 4 * * *`)
- `@weekly-random` - раз в неделю, случайный день и время (например: `52 4 * * 4`)
- `@monthly-random` - раз в месяц, случайный день (до 27) и время (например: `52 4 26 * *`)
- `@yearly-random` или `@annually-random` - раз в год, случайная дата и время

**Примеры:**
```yaml
backup:
  schedule: "@hourly-random"  # Каждый час, случайная минута
  # или
  schedule: "@daily-random"   # Каждый день, случайное время
```

**Альтернатива: стандартный cron с разными минутами**
```yaml
schedule: "7,23,41,59 0,6,12,18 * * *"  # В :07, :23, :41, :59 каждого 6-часового интервала
```

**Преимущества рандомизации**: бэкапы не запускаются все одновременно, нагрузка распределяется равномерно, снижается риск одновременной нагрузки на хранилище.

#### Бэкап в несколько мест одновременно

Для бэкапа одного PVC в несколько мест (например, локальный MinIO 4 раза в день + Backblaze 1 раз в день):

1. Создайте несколько Schedule в том же namespace с разными бэкендами
2. Они будут работать параллельно - один PVC будет бэкапиться в оба места
3. Пример: `backup-schedule.yaml` (MinIO, 4 раза в день) + `backup-schedule-backblaze.yaml` (Backblaze, 1 раз в день)

#### Примеры индивидуальных расписаний

В `config/example-schedules/` есть примеры для:
- **memos-backup**: бэкап в 2:00 каждый день
- **postgres-backup**: бэкап в 1:00 каждый день (критичная БД)

### Создание индивидуального Schedule

Для создания индивидуального расписания для конкретного PVC:

```yaml
apiVersion: k8up.io/v1
kind: Schedule
metadata:
  name: my-app-backup
  namespace: apps
spec:
  backend:
    s3:
      endpoint: http://minio.infra.svc.cluster.local:9000
      bucket: k8up-backups
      accessKeyIDSecretRef:
        name: k8up-secrets
        key: access-key
      secretAccessKeySecretRef:
        name: k8up-secrets
        key: secret-key
  backup:
    schedule: "0 2 * * *"  # Каждый день в 2:00
    timeZone: "Europe/Moscow"
    tags:
      - "my-app"
  prune:
    schedule: "0 3 * * 0"  # Каждое воскресенье в 3:00
    keepLast: 7
    keepDaily: 14
    keepWeekly: 8
    keepMonthly: 6
```

## Восстановление

### Просмотр доступных снимков

```bash
kubectl get snapshots -n apps
```

### Восстановление PVC

Создайте объект Restore:

```yaml
apiVersion: k8up.io/v1
kind: Restore
metadata:
  name: restore-memos
  namespace: apps
spec:
  backend:
    s3:
      endpoint: http://minio.infra.svc.cluster.local:9000
      bucket: k8up-backups
      accessKeyIDSecretRef:
        name: k8up-secrets
        key: access-key
      secretAccessKeySecretRef:
        name: k8up-secrets
        key: secret-key
  snapshot: <snapshot-id>
  restoreMethod:
    folder:
      claimName: memos-config-pvc
```

## Ручной запуск бэкапа (триггер)

Для запуска бэкапа вручную без ожидания расписания создайте ресурс `Backup`:

### Бэкап всех PVC с аннотацией `k8up.io/backup: "true"`

```bash
kubectl apply -f - <<EOF
apiVersion: k8up.io/v1
kind: Backup
metadata:
  name: manual-backup-$(date +%s)
  namespace: apps
spec:
  backend:
    s3:
      endpoint: http://minio.infra.svc.cluster.local:9000
      bucket: k8up-backups
      accessKeyIDSecretRef:
        name: k8up-secrets
        key: access-key
      secretAccessKeySecretRef:
        name: k8up-secrets
        key: secret-key
    repoPasswordSecretRef:
      name: k8up-secrets
      key: password
  tags:
    - "manual"
EOF
```

### Бэкап конкретного PVC

```bash
kubectl apply -f - <<EOF
apiVersion: k8up.io/v1
kind: Backup
metadata:
  name: manual-backup-postgres-$(date +%s)
  namespace: apps
spec:
  backend:
    s3:
      endpoint: http://minio.infra.svc.cluster.local:9000
      bucket: k8up-backups
      accessKeyIDSecretRef:
        name: k8up-secrets
        key: access-key
      secretAccessKeySecretRef:
        name: k8up-secrets
        key: secret-key
    repoPasswordSecretRef:
      name: k8up-secrets
      key: password
  labelSelectors:
    - matchExpressions:
      - key: app
        operator: In
        values:
          - postgres
  tags:
    - "manual"
    - "postgres"
EOF
```

### Быстрый способ через kubectl

```bash
# Создать Backup для всех PVC в namespace apps
kubectl create backup manual-$(date +%s) -n apps \
  --backend=s3 \
  --endpoint=http://minio.infra.svc.cluster.local:9000 \
  --bucket=k8up-backups \
  --access-key-secret=k8up-secrets:access-key \
  --secret-key-secret=k8up-secrets:secret-key \
  --repo-password-secret=k8up-secrets:password
```

**Примечание**: Команда `kubectl create backup` может быть недоступна, если k8up CLI не установлен. В этом случае используйте YAML манифест выше.

### Проверка статуса ручного бэкапа

```bash
# Список всех Backup
kubectl get backups -n apps

# Детали конкретного Backup
kubectl describe backup <backup-name> -n apps

# Логи Backup
kubectl logs -n apps -l k8up.io/backup=<backup-name> --tail=100
```

## Мониторинг

Проверка статуса бэкапов:

```bash
# Список всех Schedule
kubectl get schedules -n apps

# Список всех Backup jobs
kubectl get backups -n apps

# Логи последнего бэкапа
kubectl logs -n apps -l k8up.io/backup=generic-pvc-backup --tail=50
```

## Примеры подключенных PVC

- `memos-config-pvc` - бэкапится через `memos-backup` Schedule
- `postgres-data-pvc` - бэкапится через `postgres-backup` Schedule

Для добавления новых PVC просто добавьте аннотацию `k8up.io/backup: "true"` или создайте индивидуальный Schedule.

## Частота бэкапов: когда имеет смысл hourly?

### Restic и инкрементальные бэкапы

K8up использует Restic, который делает **инкрементальные бэкапы** - сохраняются только изменения. Это эффективно, но не безгранично.

### Рекомендации по частоте:

#### ✅ **Hourly имеет смысл для:**
- **Базы данных** (postgres, mysql) - 10-100Gi, часто меняются, критичны
  - RPO (Recovery Point Objective) может требовать < 1 часа
  - Инкрементальные изменения обычно небольшие
  - **Рекомендация**: 4-6 раз в день (каждые 4-6 часов)

- **Критичные конфиги** (vaultwarden, authentik) - 1-5Gi, важные данные
  - **Рекомендация**: 2-4 раза в день

#### ❌ **Hourly НЕ имеет смысла для:**
- **Медиа файлы** (immich, photoprism, jellyfin) - 200-500Gi
  - Файлы большие, изменения редкие
  - Даже инкрементальные бэкапы будут большими
  - **Рекомендация**: 1 раз в день (или реже)

- **Кэши** (jellyfin cache, transmission) - 200Gi+
  - Можно вообще не бэкапить или раз в неделю

- **Статичные конфиги** (homer, portainer) - 1Gi, меняются редко
  - **Рекомендация**: 1 раз в день достаточно

### Пример расчета места для hourly бэкапов:

**База данных 10Gi с изменениями 100MB/час:**
- Hourly: 24 бэкапа × ~100MB = ~2.4GB/день (приемлемо)
- Daily: 1 бэкап × ~2.4GB = ~2.4GB/день (то же самое, но меньше точек восстановления)

**Медиа хранилище 500Gi с изменениями 5GB/час:**
- Hourly: 24 бэкапа × ~5GB = ~120GB/день (много!)
- Daily: 1 бэкап × ~120GB = ~120GB/день (то же самое, но 1 точка восстановления)

### Вывод:

**Hourly бэкапы имеют смысл только для:**
1. Критичных баз данных (RPO < 1 часа)
2. Маленьких, часто меняющихся данных (< 10Gi)
3. Когда потеря данных за час критична

**Для большинства случаев достаточно:**
- Базы данных: 4-6 раз в день (каждые 4-6 часов)
- Конфиги: 1-2 раза в день
- Медиа: 1 раз в день (или реже)


