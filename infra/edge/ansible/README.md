# Edge VPS: Ansible

Настройка хоста `edge.progist.ru` (beget, СПб). Ansible безагентный: запускается на твоей машине, ходит на VPS
по SSH, на самом сервере ничего не ставится (нужен только Python, он в Ubuntu есть).
Контекст и роли двух IP: `docs/home-move-cgnat-plan.md`.

## Что делает

| Роль | Что |
|---|---|
| `ssh` | админ `progist`, sudo, hardening sshd (root/пароли off, `AllowUsers`), проверка `sshd -t` |
| `base` | пакеты, hostname, unattended-upgrades, swap, sysctl, journald, маскировка лишних сервисов, fail2ban |
| `firewall` | ufw: deny incoming, SSH только на аварийном IP, остальные порты из `ufw_rules` |
| `docker` | официальный docker-ce + compose plugin, `daemon.json` (ротация логов, `ip: 127.0.0.1`) |

## Требования

```sh
brew install ansible
cd infra/edge/ansible
ansible-galaxy collection install -r requirements.yml
```

Предварительно вручную (один раз): на VPS должен существовать админ с ключом и доступ по SSH.
Дальше всё делает плейбук. Публичный ключ можно положить в `admin_pubkey`
(`inventory/group_vars/edge.yml`), тогда роль сама его проставит.

## Запуск

```sh
ansible-playbook site.yml --syntax-check
ansible-playbook site.yml --check --diff     # сухой прогон: что изменилось бы
ansible-playbook site.yml                    # применить
ansible-playbook site.yml --tags docker      # только одна роль
```

Плейбук идемпотентен: повторный запуск ничего не меняет, если состояние уже соответствует.

## Важно

- **Docker обходит ufw** (пишет свои правила iptables). Поэтому `daemon.json` ставит `ip: 127.0.0.1`:
  порт контейнера наружу попадает, только если в compose указан IP явно (`ports: "159.194.251.11:443:443"`).
- Порты в `ufw_rules` открывать вместе с появлением сервиса (закомментированные примеры лежат в `group_vars`).
- Перед изменениями sshd или ufw держи открытую SSH-сессию и проверь вход во второй.
- Секретов здесь нет и быть не должно (ключи, токены, пароли хранить вне git).
