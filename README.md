# 📦 Home GitOps Repository

Это репозиторий декларативных манифестов для моего домашнего кластера k3s, развёрнутого на Proxmox.

Все сервисы описаны строго декларативно и поддерживаются через Flux.

---

## 🎯 Цели

✅ Максимально читаемая и поддерживаемая структура.  
✅ 100% развёртывание «из кода» на новом сервере.  
✅ Чистый и воспроизводимый GitOps-флоу.  
✅ Разделение ingress на internal/external с разными Issuer'ами.  
✅ Управляемое хранение данных через NFS.  
✅ Полная ротация и хранение секретов через SealedSecrets.

---

## 🗂️ Структура репозитория

- `apps/` — все конечные приложения и сервисы.
- `infra/` — системные компоненты (MetalLB, Traefik Middleware, StorageClasses, Xray, Proxy).
- `sealed-secrets/` — SealedSecrets, разделённые на apps, infra, cluster.
- `helm/` — HelmRepository и HelmRelease манифесты для Flux.
- `cluster-config/` — cert-manager и ClusterIssuer.
- `clusters/` — Flux bootstrap и точка входа.
- `namespaces/` — описание всех Namespace кластера.

---

## 🔐 Секреты и политика хранения

Все секреты хранятся в виде SealedSecrets:

- `sealed-secrets/apps/` → сервисные ключи, DB, SMTP, API.
- `sealed-secrets/infra/` → системные конфиги (например, xray).
- `sealed-secrets/cluster/` → Root CA и LetsEncrypt account key.

✅ Все ключи зашифрованы и могут быть развёрнуты с нуля через Flux.
✅ Все секреты разделены по scope.
✅ Для ротации:
  1. Расшифровать через kubeseal.
  2. Обновить значение.
  3. Перезапечатать.
  4. PR → Merge → Flux-sync.

---

## 🗝️ Root CA и LetsEncrypt

- **Root CA** используется для всех *.home доменов через `root-ca-issuer`.
- **LetsEncrypt** для публичных доменов через `letsencrypt-prod` ClusterIssuer.
- Оба ClusterIssuer описаны декларативно в `cluster-config/`.
- Ключи зашифрованы в SealedSecrets и могут быть восстановлены.

---

## 🌐 Ingress Policy

Ingress ресурсы строго делятся на:

- **internal**:
  - cert-manager.io/cluster-issuer: root-ca-issuer
  - Для *.home доменов.
  - TLS секреты с шаблоном: `{app}-internal-tls`.
  - Middleware → redirect-to-https.

- **external**:
  - cert-manager.io/cluster-issuer: letsencrypt-prod
  - Для публичных доменов.
  - TLS секреты с шаблоном: `{app}-external-tls`.
  - Middleware → redirect-to-https.

✅ Это правило строго соблюдается во всём репозитории.

---

## 🗂️ StorageClasses

Описание всех StorageClass в папке `infra/storageclasses/`.

- `nfs-nvme-manual` → для statically bound PVC.
- `nfs-fast-manual` → быстрый NFS (NVMe).
- `nfs-hdd-manual` → дешёвый, объёмный NFS.
- `nfs-nvme-manual` → high-performance NFS.
- `nfs-dynamic` → через nfs-subdir-external-provisioner для кэшей и ephemeral данных.

✅ Политика PVC:
- Критичные данные → manual, ReclaimPolicy: Retain.
- Кэш и временные → dynamic.

---

## 🗃️ PVC/PV Mapping

Рекомендуется поддерживать таблицу маппинга для миграции:

| Service     | PVC Name            | StorageClass         | NFS Path                   |
|-------------|---------------------|----------------------|----------------------------|
| filebrowser | filebrowser-data    | nfs-nvme-manual      | /mnt/NFS/Fast/...          |
| radarr      | radarr-media        | nfs-hdd-manual       | /mnt/NFS/Big/...           |
| ...         | ...                 | ...                  | ...                        |

✅ Это сильно упростит disaster recovery.

---

## 🗂️ Middleware Policy

- Все *generic* middleware → в `infra/traefik-middleware/`.
- Все *app-specific* middleware → внутри папки приложения.

✅ Примеры:
- redirect-to-https (global)
- guacamole-rewrite (app-specific)

---

## 🔀 MetalLB Strategy

- Установка через HelmRelease в `infra/metallb`.
- Конфигурация IPAddressPool и L2Advertisement в step2-config.
- Политика:
  - Статичные IP → для сервисов вроде AdGuard.
  - Резерв пулов наперёд для масштабирования:
    ```yaml
    addresses:
      - 10.0.0.2-10.0.0.10
    ```

---

## 🛡️ Секреты и ротация

Все SealedSecrets управляются kubeseal.

### Политика:

- **apps/**:
  - сервисные ключи, токены, DB пароли
- **infra/**:
  - конфиги системных сервисов (xray и др.)
- **cluster/**:
  - Root CA
  - LetsEncrypt аккаунт

### Процедура ротации:

1. Расшифровать старый секрет:

```sh
kubeseal --cert cert.pem --recovery-unseal ...
```

2. Обновить данные.
3. Перегенерировать SealedSecret:

```sh
kubeseal --cert cert.pem <secret.yaml> -o yaml > sealed.yaml
```

4. PR → Merge → Flux-sync.

---

## 🔄 Disaster Recovery

Рекомендуется периодически тестировать восстановление:

✅ Минимальный план восстановления:

1. Развернуть новый кластер k3s.
2. Flux bootstrap:
```sh
flux bootstrap git \
  --url=git@your-repo \
  --branch=main \
  --path=clusters/home
```
3. Подождать reconcile всех Kustomization.
4. Проверить:
* ingress
* PV/PVC (NFS mount)
* SealedSecrets
* cert-manager issuers
* MetalLB IP assignment

## 🗂️ Requests и Limits

Обязательное правило:

Все Deployment должны иметь resources.requests и resources.limits.

Пример:

```yaml
resources:
  requests:
    cpu: "100m"
    memory: "128Mi"
  limits:
    cpu: "500m"
    memory: "512Mi"
```

## 🏷️ Labels и Annotations
Рекомендуется использовать лейблы для удобства фильтрации:

```yaml
metadata:
  labels:
    managed-by: flux
    app.kubernetes.io/part-of: home-cluster
    environment: production
```
---

## ⚙️ Прокси через Headless Services

✅ Pattern:

- Для non-K8s сервисов:
  - Headless Service (clusterIP: None)
  - Статичные Endpoints
  - Traefik ingress для TCP/HTTP прокси

✅ Пример:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: my-proxy
spec:
  clusterIP: None
  ports:
    - port: 80
      targetPort: 8080
---
apiVersion: v1
kind: Endpoints
metadata:
  name: my-proxy
subsets:
  - addresses:
      - ip: 10.0.0.123
    ports:
      - port: 8080
```

## 🌐 HostPath vs PVC
✅ Правило:

* Все данные → PVC на NFS.
* HostPath → только для специальных случаев (GPU, low-level access).

## 📌 PostUp/PostDown для VPN
Для сервисов вроде wg-easy → обязательно документировать iptables правила.

Пример:

В apps/wg-easy/readme.md уже описано.

✅ Рекомендуется для всех сетевых сервисов.

## 🗂️ Примеры полезных Readme
apps/wg-easy/readme.md → документирует хостовую настройку.

Рекомендуется также для:

* Paperless
* Authentik
* Transmission
* Xray

✅ Документируй:

ingress-internal/external

PVC paths

специальные порты и capabilities

Secrets

## 🤖 Renovate

✅ Поддерживается через renovate.json.

### Политика:

* Разбить на packageRules по:
    * docker images
    * helm charts
    * helm repositories

* managerFilePatterns → включить apps/*/helm-release.yaml

✅ Поддерживать Automerge для минорных обновлений.

## 💾 Backup ключей

✅ Все SealedSecrets зашифрованы.
✅ Рекомендуется хранить отдельно:

* sealed-secrets private key
* Root CA ключ
* LetsEncrypt аккаунт ключ

✅ Можно использовать:

* офлайн-диск
* безопасный password manager

