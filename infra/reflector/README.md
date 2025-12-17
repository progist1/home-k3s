# Reflector - Синхронизация ресурсов между namespace'ами

Reflector - это Kubernetes оператор для автоматической синхронизации Secrets, ConfigMaps и других ресурсов между namespace'ами.

## Установка

Reflector устанавливается через HelmRelease в `infra/reflector/helm-release.yaml`.

## Использование

### Синхронизация Secrets

Для синхронизации Secret из одного namespace в другие, добавьте аннотации к исходному Secret:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: k8up-secrets
  namespace: infra
  annotations:
    # Разрешить синхронизацию
    reflector.v1.k8s.emberstack.com/reflection-allowed: "true"
    # Указать целевые namespace'ы (через запятую)
    reflector.v1.k8s.emberstack.com/reflection-allowed-namespaces: "apps,monitoring"
    # Автоматически синхронизировать в новые namespace'ы (опционально)
    reflector.v1.k8s.emberstack.com/reflection-auto-enabled: "true"
    # Автоматически синхронизировать в namespace'ы с определёнными labels (опционально)
    # reflector.v1.k8s.emberstack.com/reflection-auto-namespaces: "backup=enabled"
```

**Важно**: Reflector создаст копию Secret в целевых namespace'ах. При изменении исходного Secret, все копии будут автоматически обновлены.

### Синхронизация ConfigMaps

Аналогично для ConfigMap:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: my-config
  namespace: infra
  annotations:
    reflector.v1.k8s.emberstack.com/reflection-allowed: "true"
    reflector.v1.k8s.emberstack.com/reflection-allowed-namespaces: "apps"
```

### Синхронизация Schedule (k8up)

Для синхронизации кастомных ресурсов, таких как Schedule из k8up:

```yaml
apiVersion: k8up.io/v1
kind: Schedule
metadata:
  name: generic-pvc-backup
  namespace: infra
  annotations:
    reflector.v1.k8s.emberstack.com/reflection-allowed: "true"
    reflector.v1.k8s.emberstack.com/reflection-allowed-namespaces: "apps,monitoring"
spec:
  # ... ваш spec
```

**Примечание**: При синхронизации Schedule, убедитесь, что в целевых namespace'ах есть необходимые Secrets (например, `k8up-secrets`), на которые ссылается Schedule.

### Автоматическая синхронизация в новые namespace'ы

Для автоматической синхронизации в namespace'ы, которые будут созданы в будущем:

```yaml
metadata:
  annotations:
    reflector.v1.k8s.emberstack.com/reflection-allowed: "true"
    reflector.v1.k8s.emberstack.com/reflection-auto-enabled: "true"
    # Синхронизировать только в namespace'ы с определёнными labels
    reflector.v1.k8s.emberstack.com/reflection-auto-namespaces: "backup=enabled"
```

Затем при создании нового namespace добавьте соответствующий label:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: my-new-namespace
  labels:
    backup: "enabled"
```

## Примеры использования

### Пример 1: Синхронизация k8up-secrets

Синхронизация секретов k8up из `infra` в `apps` и `monitoring`:

```yaml
apiVersion: bitnami.com/v1alpha1
kind: SealedSecret
metadata:
  name: k8up-secrets
  namespace: infra
  annotations:
    reflector.v1.k8s.emberstack.com/reflection-allowed: "true"
    reflector.v1.k8s.emberstack.com/reflection-allowed-namespaces: "apps,monitoring"
spec:
  # ... ваш SealedSecret spec
```

После расшифровки SealedSecret, Reflector автоматически синхронизирует Secret в указанные namespace'ы.

### Пример 2: Синхронизация Schedule для всех namespace'ов с бэкапами

Создайте Schedule в namespace `infra` и синхронизируйте его во все namespace'ы, где нужны бэкапы:

```yaml
apiVersion: k8up.io/v1
kind: Schedule
metadata:
  name: generic-pvc-backup
  namespace: infra
  annotations:
    reflector.v1.k8s.emberstack.com/reflection-allowed: "true"
    reflector.v1.k8s.emberstack.com/reflection-auto-enabled: "true"
    reflector.v1.k8s.emberstack.com/reflection-auto-namespaces: "backup=enabled"
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
  # ... остальной spec
```

Затем добавьте label `backup: "enabled"` к namespace'ам, где нужны бэкапы.

### Пример 3: Синхронизация ConfigMap с общими настройками

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: common-config
  namespace: infra
  annotations:
    reflector.v1.k8s.emberstack.com/reflection-allowed: "true"
    reflector.v1.k8s.emberstack.com/reflection-allowed-namespaces: "apps,monitoring,gitlab"
data:
  timezone: "Europe/Moscow"
  log-level: "info"
```

## Проверка синхронизации

Проверьте, что ресурсы синхронизированы:

```bash
# Проверить синхронизированные Secrets
kubectl get secrets -n apps | grep k8up-secrets

# Проверить синхронизированные ConfigMaps
kubectl get configmaps -n apps | grep common-config

# Проверить синхронизированные Schedule
kubectl get schedules -n apps

# Проверить логи Reflector
kubectl logs -n infra -l app.kubernetes.io/name=reflector --tail=50
```

## Важные замечания

1. **SealedSecrets**: Reflector работает с обычными Secrets и ConfigMaps. Для SealedSecrets синхронизация произойдёт после того, как Sealed Secrets Controller расшифрует их в обычные Secrets.

2. **Обновления**: При изменении исходного ресурса, все синхронизированные копии автоматически обновляются.

3. **Удаление**: При удалении исходного ресурса, все синхронизированные копии также удаляются.

4. **Конфликты**: Если в целевом namespace уже существует ресурс с таким же именем, Reflector не будет его перезаписывать. Удалите существующий ресурс вручную или переименуйте синхронизируемый.

5. **RBAC**: Reflector требует соответствующих RBAC прав для создания ресурсов в целевых namespace'ах. Это настроено автоматически при установке.

## Дополнительные аннотации

- `reflector.v1.k8s.emberstack.com/reflection-allowed`: `"true"` - разрешить синхронизацию
- `reflector.v1.k8s.emberstack.com/reflection-allowed-namespaces`: список namespace'ов через запятую
- `reflector.v1.k8s.emberstack.com/reflection-auto-enabled`: `"true"` - автоматическая синхронизация в новые namespace'ы
- `reflector.v1.k8s.emberstack.com/reflection-auto-namespaces`: label selector для автоматической синхронизации (например, `backup=enabled`)

## Документация

Официальная документация: https://github.com/emberstack/kubernetes-reflector



