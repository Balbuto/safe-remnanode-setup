# 🛡️ Safe RemnaNode Setup v1.1.0

**Универсальный интерактивный установщик ноды Remnawave** — один скрипт, который объединяет все возможности трёх проектов:

| Проект | Что делает |
|---|---|
| [Balbuto/Setup-and-Test-Server-Ubuntu-24](https://github.com/Balbuto/Setup-and-Test-Server-Ubuntu-24) | Первоначальная настройка сервера: apt, базовый софт, Docker, BBR + Cake, sysctl SAFE/HIGHLOAD, IPv6, UFW-менеджер |
| [Balbuto/setup-remna-node](https://github.com/Balbuto/setup-remna-node) | Установка и управление нодой Remnawave: Xray-Core (VLESS Reality / TLS / xHTTP), SSL (Cloudflare / Gcore / Standalone), маскировка Selfsteal, UFW, логи |
| [Balbuto/RKN-Watcher](https://github.com/Balbuto/RKN-Watcher) | Защита от сканеров РКН: блок-листы TSPUBLOCK/GOVIPS (iptables+ipset), GeoIP-фильтрация по странам, allow/deny IP и порты, systemd timer |

**Один скрипт — три модуля + экспресс-режим полной установки.**

---

## 📦 Установка

### Требования

- **Ubuntu 24.04 LTS** (рекомендуется) или Debian 11+
- Права **root**
- Архитектура amd64 или arm64

### Быстрый старт

```bash
# Скачать и запустить
wget https://raw.githubusercontent.com/Balbuto/safe-remnanode-setup/main/safe-remnanode-setup.sh
chmod +x safe-remnanode-setup.sh
sudo ./safe-remnanode-setup.sh

# Или одной строкой (скрипт сам сохранит себя в /usr/local/bin)
sudo bash -c "$(wget -qO- https://raw.githubusercontent.com/Balbuto/safe-remnanode-setup/main/safe-remnanode-setup.sh)"
```

### Репозиторий

```bash
git clone https://github.com/Balbuto/safe-remnanode-setup.git
cd safe-remnanode-setup
chmod +x safe-remnanode-setup.sh
sudo ./safe-remnanode-setup.sh
```

После первого запуска регистрируются глобальные команды:

- `safe-remnanode-setup` — главное меню
- `remnanode` — меню управления нодой (совместимость с setup-remna-node)
- `rkn-watcher` — меню управления защитой (совместимость с RKN-Watcher)

---

## 🎛️ Главное меню

```
 1. 🚀 Экспресс: полная установка (сервер + нода + защита)
 2. 🖥️  Настройка сервера (обновление, Docker, BBR, sysctl)
 3. 📦 Установка ноды Remnawave
 4. 🛡️  Установка защиты RKN-Watcher
 5. 🔧 Управление нодой (домен, SSL, Xray, порты, логи...)
 6. 🛡️  Управление защитой (блок-листы, GeoIP, настройки)
 7. 🧪 Диагностика и мульти-тесты сервера
 8. 🌐 Управление IPv6 (вкл/выкл + откат)
 9. 🔥 UFW-менеджер (Balbuto/ufw-manager)
 0. Выйти
```

В шапке меню показывается статус каждого модуля (установлен / не установлен).

---

## 🧩 Модуль A — Настройка сервера

- Обновление системы (`apt update && upgrade && dist-upgrade`) с ожиданием apt-lock
- Установка базового софта: `mc, net-tools, ncdu, iftop, curl, wget, git`
- Установка **Docker** через официальный apt-репозиторий (Ubuntu и Debian, с починкой битого GPG-ключа)
- Включение **BBR + Cake qdisc** (`enable_bbr_cake`, файл `/etc/sysctl.d/99-bbr-cake.conf`)
- Профили ядра: **SAFE** / **HIGHLOAD** / **AUTO** (автовыбор по RAM) + лимиты `nofile`
- `irqbalance`
- Управление **IPv6** (отключение с restore-скриптом `/root/restore-ipv6.sh`)
- **UFW-менеджер** (клон `Balbuto/ufw-manager` с проверкой diff)
- Бэкапы всех изменяемых файлов в `/root/remna-universal-backups/`

## 🧩 Модуль B — Нода Remnawave

Полный интерактивный флоу установки:

1. Сетевая оптимизация (BBR + sysctl-профиль по RAM) + зависимости + Docker
2. **Выбор версии Xray-Core** через GitHub API (встроенная / stable / pre-release, amd64 и arm64)
3. Настройка логов на хост + **logrotate** (авторотация 50MB × 7)
4. Ввод данных панели: IP панели, домен ноды, порт управления (по умолчанию 2222), **secret key** (вставка с двойным Enter)
5. Дополнительные входящие порты Xray (автооткрытие в UFW)
6. Выбор протокола: **VLESS Reality (Selfsteal)** / **VLESS+TLS** / **VLESS+TLS+xHTTP**
7. **Маскировочный сайт**: шаблоны Mrvibecodic + мутатор `uniquify-theme` (случайный или конкретный из 8)
8. **SSL**: Cloudflare API (wildcard DNS-01) / Certbot Standalone (HTTP-01) / Gcore DNS API + автопродление с deploy-hook
9. Деплой `docker-compose`: `remnanode` + `remnawave-nginx` на host-сети с Unix-сокетом `/dev/shm/nginx.sock`
10. **UFW**: default deny, автоопределение SSH-порта, 80/443, кастомные порты, порт управления открыт **только для IP панели**

Меню управления нодой: смена домена и перевыпуск SSL, обновление Xray-Core, смена IP панели, управление портами (включая диапазоны), смена маскировочного шаблона, диагностика и логи в реальном времени, полное удаление с откатом.

## 🧩 Модуль C — Защита RKN-Watcher

- **TSPUBLOCK** — список CIDR ТСПУ (`CyberOK_Skipa_ips`)
- **GOVIPS** — список сетей госструктур (`C24Be/AS_Network_List`)
- Блокировка `iptables` + `ipset` (hash:net до 2 млн записей), **атомарное обновление** через временный set + swap
- **GeoIP**: allow-страны (ipdeny с кэшем 24ч), allow/deny IP/CIDR, allow/deny порты, фильтрация по `FILTER_PORTS`
- Логирование RST-пакетов (опционально)
- **systemd timer** — ежедневное обновление в 03:00 + boot-сервис восстановления после перезагрузки
- file-lock на JSON-конфигурацию (fcntl)
- Манифест установленных пакетов — при удалении предлагается снять и их

Python-хелперы `config_tool.py` и `geoip_apply.py` **встроены в скрипт** и распаковываются в `/opt/rkn-watcher/` — единый файл, ничего дополнительно качать не нужно.

## 🧩 Модуль D — Мульти-тесты

Состав актуализирован по оригиналу [saveksme/multitest](https://github.com/saveksme/multitest) v1.1:

IP Region, Censorcheck (геоблок/DPI), iPerf3 RU, **iPerf3 bench.tlab.pw (РФ)**, YABS, IP Check Place, IPQuality (`-l ru -I`), sysbench CPU/Memory, Network Bench, SSL/TLS check, traceroute/ping.

- **Мультитест (99)**: `Enter` — запустить, `s` — пропустить, `q` — выйти, **Ctrl+C во время теста пропускает текущий**
- Внешние скрипты запускаются **только по HTTPS** (верификация SHA256 отключена по требованию)

---

## 🚀 Экспресс-установка

Один пункт меню (или `sudo safe-remnanode-setup express`) проводит полный цикл:

1. **Сервер**: обновление → базовый софт → Docker → BBR+Cake → авто-hardening → irqbalance
2. **Нода**: полный интерактивный флоу установки
3. **Защита**: интерактивная установка RKN-Watcher

Если шаг не удался — экспресс не прерывается: скрипт предупредит и предложит повторить шаг позже.

---

## 🖥️ CLI-команды

```bash
sudo safe-remnanode-setup menu               # главное меню (по умолчанию)
sudo safe-remnanode-setup express            # полная установка
sudo safe-remnanode-setup server             # настройка сервера
sudo safe-remnanode-setup node               # установка ноды
sudo safe-remnanode-setup node-menu          # меню управления нодой
sudo safe-remnanode-setup protect            # установка защиты
sudo safe-remnanode-setup protect-menu       # меню защиты
sudo safe-remnanode-setup protect-update     # обновить блок-листы
sudo safe-remnanode-setup protect-apply      # переприменить правила
sudo safe-remnanode-setup protect-status     # статус защиты
sudo safe-remnanode-setup protect-uninstall  # удалить защиту
sudo safe-remnanode-setup multitest          # мульти-тесты
sudo safe-remnanode-setup ipv6               # управление IPv6
```

Команды-синонимы: `remnanode` и `rkn-watcher` (симлинки) открывают соответствующие меню.

---

## 🛡️ Безопасность

- Только HTTPS при скачивании внешних скриптов
- `set -Eeuo pipefail` + shellcheck чистый (0 замечаний)
- Бэкапы изменяемых файлов перед правкой
- Порт управления нодой открывается только для IP панели
- UFW-правила добавляются недеструктивно
- Проверка поддержки ipset ядром перед установкой защиты
- CI (GitHub Actions): shellcheck + bash -n + py_compile встроенных хелперов при каждом push/PR

## 📁 Структура репозитория

```
safe-remnanode-setup/
├── safe-remnanode-setup.sh      # универсальный скрипт (всё в одном файле)
├── README.md                    # документация
├── USER_GUIDE.md                # подробное руководство пользователя
├── PRODUCTION_READINESS_REPORT.md  # отчёт о готовности к production
├── .github/workflows/ci.yml     # CI: shellcheck + bash -n + py_compile
└── tests/check_embedded_python.py  # проверка встроенных Python-хелперов
```

## ⚠️ Примечания

- Защита RKN-Watcher работает только с **IPv4** (ipset family inet)
- GeoIP-страны качаются с ipdeny.com; TSPUBLOCK/GOVIPS — с GitHub
- При отсутствии поддержки ipset в ядре (нет модуля `xt_set`) установщик предупредит и предложит остановиться
- Модуль защиты совместим с UFW (цепочки вставляются в INPUT поверх правил UFW)

## 📜 Лицензия

MIT — как и все три исходных проекта.
