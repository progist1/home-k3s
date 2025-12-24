# 🏷️ Node Labels & Taints Management

Управление лейблами и тейнтингом нод кластера через Flux + Kustomize.

## ⚠️ Важно

**Node манифесты не создают ноды, а патчат существующие!**

Нода должна быть уже зарегистрирована в кластере (например, через `k3s agent`). Flux будет применять labels и taints к существующим нодам.

## 📋 Схема лейблинга и тейнтинга

### 1️⃣ Локация / Топология (обязательные)

**Labels:**
- `topology.kubernetes.io/region: ru` - регион
- `topology.kubernetes.io/zone: <site>` - зона (datacenter | private-house | etc)
- `node.location.site: <site>` - человекочитаемое название локации
- `node.location.type: local | remote` - тип локации

**Taints:**
- `node.location.type=remote:NoSchedule` - **ТОЛЬКО для remote нод**

### 2️⃣ Роль ноды

**Labels:**
- `node.role: control-plane | worker | edge` - роль ноды
- `node.workload.class: general | storage | gpu | cctv | critical` - класс рабочей нагрузки

**Taints:**
- `node.role=control-plane:NoSchedule` - control-plane ноды
- `node.role=edge:NoSchedule` - edge ноды (изолированные)

### 3️⃣ Надёжность

**Labels:**
- `node.reliability: high | medium | low` - уровень надёжности

**Taints:**
- `node.reliability=low:NoSchedule` - удалённые / нестабильные ноды

### 4️⃣ Хранилище (hostPath / zvol / USB)

**Labels:**
- `node.storage.local: "true"` - есть hostPath
- `node.storage.backend: zvol | usb | hdd | nvme` - тип бэкенда
- `node.storage.class: fast | bulk | critical` - класс хранилища

**Под конкретные маунты (ТОЛЬКО если hostPath):**
- `node.storage.mount.mysql: "true"`
- `node.storage.mount.postgres: "true"`
- `node.storage.mount.prometheus: "true"`
- `node.storage.mount.cctv: "true"`

**Taints:**
- `node.storage.local=true:NoSchedule` - защита от случайных подов на storage ноде

### 5️⃣ Спец-железо

**Labels:**
- `node.hardware.gpu: none | intel-igpu | nvidia` - тип GPU
- `node.hardware.video-accel: qsv | vaapi | none` - видеоускорение
- `node.hardware.usb: "true"` - доступ к USB устройствам
- `node.hardware.arch: amd64 | arm64` - архитектура

**Taints:**
- `node.hardware.gpu=nvidia:NoSchedule` - выделенная GPU нода

## 📝 Примеры манифестов

### 🖥️ TrueNAS / k3s-prod (storage-heavy)

```yaml
apiVersion: v1
kind: Node
metadata:
  name: k3s-prod
  labels:
    topology.kubernetes.io/region: ru
    topology.kubernetes.io/zone: datacenter
    node.location.site: datacenter
    node.location.type: local
    node.role: worker
    node.workload.class: storage
    node.reliability: high
    node.storage.local: "true"
    node.storage.backend: zvol
    node.storage.class: fast
    node.storage.mount.mysql: "true"
    node.storage.mount.postgres: "true"
    node.storage.mount.prometheus: "true"
    node.hardware.gpu: none
    node.hardware.video-accel: none
    node.hardware.arch: amd64
spec:
  taints:
    - key: node.storage.local
      value: "true"
      effect: NoSchedule
```

### 🎥 Edge CCTV (частный дом)

```yaml
apiVersion: v1
kind: Node
metadata:
  name: k3s-yolki
  labels:
    topology.kubernetes.io/region: ru
    topology.kubernetes.io/zone: private-house
    node.location.site: private-house
    node.location.type: remote
    node.role: edge
    node.workload.class: cctv
    node.reliability: low
    node.storage.local: "true"
    node.storage.backend: usb
    node.storage.mount.cctv: "true"
    node.hardware.gpu: none
    node.hardware.video-accel: vaapi
    node.hardware.usb: "true"
    node.hardware.arch: amd64
spec:
  taints:
    - key: node.location.type
      value: remote
      effect: NoSchedule
    - key: node.role
      value: edge
      effect: NoSchedule
    - key: node.reliability
      value: low
      effect: NoSchedule
```

### 🎮 GPU нода

```yaml
apiVersion: v1
kind: Node
metadata:
  name: k3s-gpu
  labels:
    topology.kubernetes.io/region: ru
    topology.kubernetes.io/zone: datacenter
    node.location.site: datacenter
    node.location.type: local
    node.role: worker
    node.workload.class: gpu
    node.reliability: high
    node.storage.local: "false"
    node.storage.backend: nvme
    node.hardware.gpu: nvidia
    node.hardware.video-accel: none
    node.hardware.arch: amd64
spec:
  taints:
    - key: node.hardware.gpu
      value: nvidia
      effect: NoSchedule
```

## 🔧 Использование в Pod манифестах

### NodeSelector для выбора ноды

```yaml
spec:
  nodeSelector:
    node.workload.class: storage
    node.storage.mount.postgres: "true"
```

### Tolerations для работы на тейнтированных нодах

```yaml
spec:
  tolerations:
    - key: node.storage.local
      operator: Equal
      value: "true"
      effect: NoSchedule
```

### Комбинация NodeSelector + Tolerations

```yaml
spec:
  nodeSelector:
    node.role: edge
    node.workload.class: cctv
  tolerations:
    - key: node.location.type
      operator: Equal
      value: remote
      effect: NoSchedule
    - key: node.role
      operator: Equal
      value: edge
      effect: NoSchedule
    - key: node.reliability
      operator: Equal
      value: low
      effect: NoSchedule
```

## 🚀 Добавление новой ноды

1. Создайте манифест в `infra/nodes/<node-name>.yaml`
2. Добавьте его в `infra/nodes/kustomization.yaml`
3. Commit → Push → Flux применит изменения

**Важно:** Нода должна быть уже зарегистрирована в кластере!

## ⚙️ Flux Kustomization

Управление нодами вынесено в отдельный Kustomization с `prune: false`:

```yaml
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: nodes
  namespace: flux-system
spec:
  interval: 10m
  path: ./infra/nodes
  prune: false  # ⚠️ ОБЯЗАТЕЛЬНО: Flux не должен пытаться удалить Node
  sourceRef:
    kind: GitRepository
    name: flux-system
```

**Почему `prune: false`?**
- Node ресурсы создаются автоматически при регистрации ноды в кластере
- Flux не должен пытаться их удалить при синхронизации
- Мы только патчим labels и taints существующих нод

## 📚 Полезные команды

### Проверка лейблов ноды

```bash
kubectl get node <node-name> --show-labels
```

### Проверка тейнтинга

```bash
kubectl describe node <node-name> | grep Taints
```

### Ручное применение изменений

```bash
kubectl apply -f infra/nodes/<node-name>.yaml
```

### Проверка через Flux

```bash
flux get kustomization nodes
flux describe kustomization nodes
```

