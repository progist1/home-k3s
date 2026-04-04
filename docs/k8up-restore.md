# Восстановление Application-Aware бэкапов (БД)

Application-Aware бэкапы создают SQL дампы через команды в Pod'ах (`k8up.io/backupcommand`), а не бэкапят сырые файлы PVC.

## Как это работает

1. Schedule находит PVC через `labelSelectors` (метки `backup-level`)
2. K8up находит Pod, использующий этот PVC
3. Если у Pod есть аннотация `k8up.io/backupcommand`, выполняется команда (pg_dump/mysqldump)
4. Вывод команды (SQL дамп) сохраняется в Restic репозиторий

## Восстановление PostgreSQL

### 1. Найти snapshot

```bash
# Через k8up (если есть доступ)
kubectl get snapshots -n apps

# Или через restic напрямую
export RESTIC_REPOSITORY=s3:http://minio.infra.svc.cluster.local:9000/k8up-backups
export RESTIC_PASSWORD=$(kubectl get secret k8up-secrets -n infra -o jsonpath='{.data.password}' | base64 -d)
export AWS_ACCESS_KEY_ID=$(kubectl get secret k8up-secrets -n infra -o jsonpath='{.data.access-key}' | base64 -d)
export AWS_SECRET_ACCESS_KEY=$(kubectl get secret k8up-secrets -n infra -o jsonpath='{.data.secret-key}' | base64 -d)

restic snapshots --tag postgres
```

### 2. Извлечь SQL дамп из snapshot

```bash
SNAPSHOT_ID=$(restic snapshots --tag postgres --json | jq -r '.[0].id')
restic dump $SNAPSHOT_ID /default-postgres > postgres-restore.sql
```

### 3. Восстановить в PostgreSQL

```bash
cat postgres-restore.sql | kubectl exec -n apps -i $(kubectl get pod -n apps -l app=postgres -o jsonpath='{.items[0].metadata.name}') -- \
  sh -c 'PGPASSWORD="$POSTGRES_PASSWORD" psql -U "$POSTGRES_USER"'
```

## Восстановление MySQL/MariaDB

### 1. Найти snapshot

```bash
restic snapshots --tag mysql
```

### 2. Извлечь SQL дамп

```bash
SNAPSHOT_ID=$(restic snapshots --tag mysql --json | jq -r '.[0].id')
restic dump $SNAPSHOT_ID /default-mysql > mysql-restore.sql
```

### 3. Восстановить в MySQL

```bash
cat mysql-restore.sql | kubectl exec -n apps -i $(kubectl get pod -n apps -l app=mysql -o jsonpath='{.items[0].metadata.name}') -- \
  sh -c 'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysql -u root'
```

## Восстановление Immich PostgreSQL

```bash
SNAPSHOT_ID=$(restic snapshots --tag immich-postgres --json | jq -r '.[0].id')
restic dump $SNAPSHOT_ID /default-pgvecto > immich-restore.sql

cat immich-restore.sql | kubectl exec -n apps -i $(kubectl get pod -n apps -l app=pgvecto -o jsonpath='{.items[0].metadata.name}') -- \
  sh -c 'PGPASSWORD="$POSTGRES_PASSWORD" psql -U "$POSTGRES_USER" -d "$POSTGRES_DB"'
```

## Важные замечания

1. **Путь к файлу в snapshot**: K8up сохраняет Application-Aware бэкапы по пути `/default-<pod-name>` или `/<pvc-name>`. Проверьте правильный путь:
   ```bash
   restic ls $SNAPSHOT_ID
   ```

2. **Теги**: K8up добавляет теги из Schedule. Используйте теги для фильтрации:
   ```bash
   restic snapshots --tag important --tag postgres
   ```

3. **Восстановление в пустую БД**: Если восстанавливаете в новую БД, убедитесь что она создана:
   ```bash
   kubectl exec -n apps -it <postgres-pod> -- psql -U postgres -c "CREATE DATABASE mydb;"
   ```

4. **Частичное восстановление**: См. раздел "Частичное восстановление отдельных баз данных" ниже

## Частичное восстановление отдельных баз данных

**Важно**: При восстановлении сервера с 12+ базами данных не нужно восстанавливать все сразу. Можно восстановить только нужные базы по одной.

### PostgreSQL: Восстановление одной базы из pg_dumpall

```bash
SNAPSHOT_ID=$(restic snapshots --tag postgres --json | jq -r '.[0].id')
restic dump $SNAPSHOT_ID /default-postgres > postgres-all.sql

DB_NAME="mydb"

# Вариант 1: Если в дампе есть \c mydb
sed -n '/^\\c '"$DB_NAME"'$/,/^\\c /p' postgres-all.sql | head -n -1 > ${DB_NAME}-only.sql

# Восстановить
cat ${DB_NAME}-only.sql | kubectl exec -n apps -i $(kubectl get pod -n apps -l app=postgres -o jsonpath='{.items[0].metadata.name}') -- \
  sh -c 'PGPASSWORD="$POSTGRES_PASSWORD" psql -U "$POSTGRES_USER"'
```

### MySQL: Восстановление одной базы из mysqldump --all-databases

```bash
SNAPSHOT_ID=$(restic snapshots --tag mysql --json | jq -r '.[0].id')
DB_NAME="mydb"

restic dump $SNAPSHOT_ID /default-mysql | \
  sed -n '/^-- Current Database: `'"$DB_NAME"'`/,/^-- Dump completed on/p' | \
  kubectl exec -n apps -i $(kubectl get pod -n apps -l app=mysql -o jsonpath='{.items[0].metadata.name}') -- \
  sh -c 'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysql -u root'
```

### Список всех баз в дампе

```bash
# PostgreSQL
SNAPSHOT_ID=$(restic snapshots --tag postgres --json | jq -r '.[0].id')
restic dump $SNAPSHOT_ID /default-postgres > postgres-all.sql
grep -E "^CREATE DATABASE|^\\c " postgres-all.sql | grep -v "^--" | sort -u

# MySQL
SNAPSHOT_ID=$(restic snapshots --tag mysql --json | jq -r '.[0].id')
restic dump $SNAPSHOT_ID /default-mysql > mysql-all.sql
grep "^-- Current Database:" mysql-all.sql | sed "s/-- Current Database: \`//" | sed "s/\`//" | sort -u
```

### Скрипт восстановления MySQL

```bash
#!/bin/bash
# restore-mysql-db.sh
set -euo pipefail

DB_NAME=$1
SNAPSHOT_TAG=${2:-"mysql"}
NAMESPACE=${3:-"apps"}

[ -z "$DB_NAME" ] && { echo "Usage: $0 <db-name> [snapshot-tag] [namespace]"; exit 1; }

export RESTIC_REPOSITORY=s3:http://minio.infra.svc.cluster.local:9000/k8up-backups
export RESTIC_PASSWORD=$(kubectl get secret k8up-secrets -n infra -o jsonpath='{.data.password}' | base64 -d)
export AWS_ACCESS_KEY_ID=$(kubectl get secret k8up-secrets -n infra -o jsonpath='{.data.access-key}' | base64 -d)
export AWS_SECRET_ACCESS_KEY=$(kubectl get secret k8up-secrets -n infra -o jsonpath='{.data.secret-key}' | base64 -d)

SNAPSHOT_ID=$(restic snapshots --tag "$SNAPSHOT_TAG" --json | jq -r 'sort_by(.time) | reverse | .[0].id')
POD=$(kubectl get pod -n "$NAMESPACE" -l app=mysql -o jsonpath='{.items[0].metadata.name}')

restic dump "$SNAPSHOT_ID" /default-mysql | \
  sed -n '/^-- Current Database: `'"$DB_NAME"'`/,/^-- Dump completed on/p' | \
  kubectl exec -n "$NAMESPACE" -i "$POD" -- \
  sh -c 'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysql -u root'

echo "Restored: $DB_NAME"
```

### Скрипт восстановления PostgreSQL

```bash
#!/bin/bash
# restore-postgres-db.sh
set -euo pipefail

DB_NAME=$1
SNAPSHOT_TAG=${2:-"postgres"}
NAMESPACE=${3:-"apps"}

[ -z "$DB_NAME" ] && { echo "Usage: $0 <db-name> [snapshot-tag] [namespace]"; exit 1; }

export RESTIC_REPOSITORY=s3:http://minio.infra.svc.cluster.local:9000/k8up-backups
export RESTIC_PASSWORD=$(kubectl get secret k8up-secrets -n infra -o jsonpath='{.data.password}' | base64 -d)
export AWS_ACCESS_KEY_ID=$(kubectl get secret k8up-secrets -n infra -o jsonpath='{.data.access-key}' | base64 -d)
export AWS_SECRET_ACCESS_KEY=$(kubectl get secret k8up-secrets -n infra -o jsonpath='{.data.secret-key}' | base64 -d)

SNAPSHOT_ID=$(restic snapshots --tag "$SNAPSHOT_TAG" --json | jq -r 'sort_by(.time) | reverse | .[0].id')
POD=$(kubectl get pod -n "$NAMESPACE" -l app=postgres -o jsonpath='{.items[0].metadata.name}')

kubectl exec -n "$NAMESPACE" -i "$POD" -- \
  sh -c 'PGPASSWORD="$POSTGRES_PASSWORD" psql -U "$POSTGRES_USER" -c "CREATE DATABASE \"'"$DB_NAME"'\";"' || true

restic dump "$SNAPSHOT_ID" /default-postgres | \
  sed -n '/^\\c '"$DB_NAME"'$/,/^\\c /p' | head -n -1 | \
  kubectl exec -n "$NAMESPACE" -i "$POD" -- \
  sh -c 'PGPASSWORD="$POSTGRES_PASSWORD" psql -U "$POSTGRES_USER" -d "'"$DB_NAME"'"'

echo "Restored: $DB_NAME"
```
