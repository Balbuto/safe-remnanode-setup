<img width="1536" height="1024" alt="ChatGPT Image 10 авг  2026 г , 03_05_17" src="https://github.com/user-attachments/assets/faf25857-ea5b-44ac-b984-ed780ee3c632" />


# 🛡️ Safe RemnaNode Setup v1.1.0+hardening.15

**Универсальный интерактивный установщик ноды Remnawave** — один скрипт, основанный на трёх проектах:

| Проект | Что делает |
|---|---|
| [Balbuto/Setup-and-Test-Server-Ubuntu-24](https://github.com/Balbuto/Setup-and-Test-Server-Ubuntu-24) | Первоначальная настройка сервера: apt, базовый софт, Docker, BBR + Cake, sysctl SAFE/HIGHLOAD, IPv6, просмотр статуса UFW |
| [Balbuto/setup-remna-node](https://github.com/Balbuto/setup-remna-node) | Установка и управление нодой Remnawave: Xray-Core (VLESS Reality / TLS / xHTTP), SSL (Cloudflare / Gcore / Standalone), маскировка Selfsteal, UFW, логи |
| [Balbuto/RKN-Watcher](https://github.com/Balbuto/RKN-Watcher) | Защита от сканеров РКН: блок-листы TSPUBLOCK/GOVIPS (iptables+ipset), GeoIP-фильтрация по странам, allow/deny IP и порты, systemd timer |

**Один установщик — три функциональных модуля + экспресс-режим полной установки.**

Исходники теперь разложены по `lib/` и `vendor/`, но для VPS релиз по-прежнему поставляется одним самодостаточным `safe-remnanode-setup.sh`. Не скачивайте отдельно модульный загрузчик: он предназначен для разработки из полного дерева исходников.

---

## 📦 Установка

### Требования

- **Ubuntu 24.04 LTS** (рекомендуется) или Debian 11+
- Права **root**
- Архитектура amd64 или arm64

### Быстрый старт

**Установка на VPS — однофайловым релизом.** После публикации этой ревизии в `main` ссылка ниже будет отдавать сгенерированный `safe-remnanode-setup.sh`, уже содержащий модули установщика и закреплённый RKN Watcher. Для обычной установки не нужны `lib/`, `vendor/`, Python или сборщик.

```bash
wget -O safe-remnanode-setup.sh https://raw.githubusercontent.com/Balbuto/safe-remnanode-setup/main/safe-remnanode-setup.sh
```

Проверьте скачанный файл, затем запустите меню:

```bash
chmod +x safe-remnanode-setup.sh
sudo ./safe-remnanode-setup.sh
```

Чтобы сразу перейти к установке ноды, укажите `node`:

```bash
sudo ./safe-remnanode-setup.sh node
```

Если вы скачали **полный ZIP исходников репозитория**, запустите тот же однофайловый установщик из корня распакованного проекта:

```bash
sudo bash ./safe-remnanode-setup.sh
```

`safe-remnanode-setup-modular.sh` — загрузчик исходников для разработки и тестирования, не замена релизному файлу. Для изменений редактируйте `lib/`, затем собирайте `safe-remnanode-setup.sh` через `python3 tools/build_standalone.py` и проверяйте его командой `python3 tools/build_standalone.py --check`.

Для открытия главного меню уберите `node`. На существующем сервере `install-cli` обновляет только локальные команды; перед обновлением прочитайте [заметки миграции](MIGRATION.md).

**Для установки ноды** нужен Docker Compose v2 с поддержкой `up --wait`. На чистом сервере установщик проверяет UFW: при необходимости ставит пакет, добавляет разрешение на фактический TCP-порт SSH и только затем включает firewall. Порт `22` не подставляется наугад. Уже активный UFW не перенастраивается на этом этапе, политика deny/reject для входящих соединений обязательна. Держите открытыми текущую SSH-сессию и консоль VPS, пока не проверите вход второй сессией.

Перед обновлением действующего сервера прочитайте [заметки миграции](MIGRATION.md).

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
 9. 🔥 Статус UFW
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
- **Просмотр статуса UFW** (без загрузки внешнего менеджера)
- Бэкапы отдельных системных настроек в `/root/remna-universal-backups/`

## 🧩 Модуль B — Нода Remnawave

Полный интерактивный флоу установки:

1. Зависимости и Docker; профиль sysctl — по явному запросу
2. **Xray-Core**: при установке берётся текущий стабильный релиз GitHub (amd64/arm64), без замены на встроенную версию при ошибке
3. Файловые журналы Xray и nginx на хосте, **logrotate**: ежедневно, порог 50 МБ при запуске планировщика, 7 архивов
4. Ввод данных панели: IP панели, домен ноды, порт управления (по умолчанию 2222), **secret key** (вставка с двойным Enter)
5. Выбор конфигурации: **VLESS-Reality** (обязательный ввод SNI), **VLESS+TLS**, **VLESS+xHTTP+TLS** или **VLESS+TLS + VLESS+xHTTP+TLS + Hy2 одновременно**
6. В совмещённом режиме вводятся фактические порты из панели: TCP для VLESS+TLS, TCP или UDP для xHTTP (HTTP/3), UDP для Hy2. Для остальных режимов доступен ввод дополнительных портов
7. **Встроенный HTML-шаблонизатор**: три темы, ручной или случайный выбор, отдельный webroot `/opt/remnanode/www`; не скачивает и не исполняет сторонние скрипты
8. **SSL**: Cloudflare API (wildcard DNS-01) / Certbot Standalone (HTTP-01) / Gcore DNS API + автопродление с deploy-hook
9. Деплой `docker-compose`: `remnanode` + `remnawave-nginx` (`nginx:1.31`) на host-сети с Unix-сокетом `/dev/shm/nginx.sock`
10. **UFW**: добавление разрешений для IP панели и выбранных портов к уже настроенному firewall; правила администратора сохраняются.

Меню управления нодой: смена домена и перевыпуск SSL, обновление Xray-Core, смена IP панели, управление портами (включая диапазоны), смена локального шаблона без перезапуска, диагностика и удаление файлов ноды без глобального сброса.

Для трёх транспортов на одной ноде активируйте три inbound в **одном Config Profile** панели. Установщик не редактирует профиль. Для действующего деплоя используйте `node-transports` без пересоздания контейнеров; `node-check-ports` диагностирует слушатели. См. [порядок миграции](MIGRATION.md#три-транспорта-на-одной-ноде-10).

## 🧩 Модуль C — RKN Watcher 3.2.1

Встроен проверенный комплект из [`3c88c27a6518`](https://github.com/Balbuto/RKN-Watcher/tree/3c88c27a65181a93921a21b2d8a28f2292df1e03): штатный установщик, 8 shell-модулей и Python-хелперы. `protect` берёт код из текущего локального файла, не скачивая исполняемый код из `main`. Сами списки обновляются по сети, как и раньше.

В 3.2.1 доступны IPv6 для списков разрешённых и запрещённых IP/CIDR, выбор бэкенда netfilter (`auto`, `nft`, `legacy`), проверка nftables, `doctor`, `metrics` и снимки состояния. `protect-update` обновляет списки, **а не версию программы**. Перед обновлением действующего Watcher см. [миграцию](MIGRATION.md#rkn-watcher-321-14).

## 🧩 Модуль D — Мульти-тесты

Геолокация IP, sysbench CPU/Memory, загрузка тестового файла, проверка TLS, traceroute и ping. Внешние shell-скрипты убраны из меню. Мультитест `99` предлагает запустить каждый оставшийся тест по очереди.

---

## 🚀 Экспресс-установка

Один пункт меню (или `sudo safe-remnanode-setup express`) проводит полный цикл:

1. **Сервер**: проверка Compose и установка Docker при необходимости. Апгрейд ОС и сетевой профиль вынесены в отдельное меню.
2. **Нода**: полный интерактивный флоу установки
3. **Защита**: установка RKN-Watcher только при подтверждении

При ошибке обязательного шага экспресс-установка прекращается.

---

## 🖥️ CLI-команды

```bash
sudo safe-remnanode-setup menu               # главное меню (по умолчанию)
sudo safe-remnanode-setup express            # полная установка
sudo safe-remnanode-setup server             # настройка сервера
sudo safe-remnanode-setup node               # установка ноды
sudo safe-remnanode-setup node-menu          # меню управления нодой
sudo safe-remnanode-setup node-logs          # применить логи к существующей ноде
# Необязательно: sudo safe-remnanode-setup node-logs example.com — путь TLS по зоне
sudo safe-remnanode-setup protect            # установка защиты
sudo safe-remnanode-setup protect-menu       # меню защиты
sudo safe-remnanode-setup protect-update     # обновить блок-листы
sudo safe-remnanode-setup protect-apply      # переприменить правила
sudo safe-remnanode-setup protect-status     # статус защиты
safe-remnanode-setup protect-version        # версия встроенного комплекта
sudo safe-remnanode-setup protect-uninstall  # удалить защиту
sudo safe-remnanode-setup multitest          # мульти-тесты
sudo safe-remnanode-setup ipv6               # управление IPv6
```

Команды-синонимы: `remnanode` и `rkn-watcher` (симлинки) открывают соответствующие меню.

---

## 🛡️ Безопасность

- Скачанные сторонние shell-скрипты не исполняются автоматически
- `set -Eeuo pipefail` + shellcheck чистый (0 замечаний)
- Compose проверяется перед заменой конфигов; при неудачном запуске скрипт пытается вернуть предыдущие файлы и применить их
- Добавляется отдельное правило для IP панели. Уже открытые администратором или оставшиеся от предыдущих версий разрешения нужно проверить вручную.
- При удалении ноды UFW не очищается: оставшиеся правила проверьте и снимите вручную.
- RKN Watcher проверяет доступность nftables; тестируйте правила и совместимость бэкенда с UFW на отдельной ноде.
- CI (GitHub Actions): проверка свежести однофайловой сборки, bash -n, ShellCheck и smoke-тесты для standalone и модульного входов при каждом push/PR

## 🧱 Модульная архитектура

```text
safe-remnanode-setup.sh          # однофайловый релиз для wget и установки CLI
safe-remnanode-setup-modular.sh  # загрузчик исходников для разработки и проверок
lib/
  modules.list                   # порядок загрузки и сборки
  common.sh, cli.sh, server.sh
  node.sh, firewall.sh, tls.sh, compose.sh, xray.sh, web.sh, diagnostics.sh
  rkn.sh                         # наша обёртка для RKN Watcher
vendor/rkn-watcher/              # исходники закреплённого RKN 3.2.1 и его лицензия
tools/build_standalone.py         # воспроизводимая однофайловая сборка
```

Редактируйте `lib/`, а не сгенерированный файл. Чтобы собрать релиз и проверить, что файл не устарел:

```bash
python3 tools/build_standalone.py
python3 tools/build_standalone.py --check
bash tests/smoke.sh
REMNA_ENTRYPOINT=./safe-remnanode-setup-modular.sh bash tests/smoke.sh
```

Модульный запуск: `bash ./safe-remnanode-setup-modular.sh --help`. Он рассчитан на полный каталог исходников. При регистрации глобальной команды оба варианта устанавливают однофайловый скрипт: на сервер не нужно переносить `lib/` или `vendor/`. Сборка не требует сети, код RKN Watcher берётся из `vendor/rkn-watcher/`.

## ⚠️ Примечания

- Поддержка IPv6 зависит от доступности `ip6tables` и `ipset` на хосте; не все внешние источники содержат IPv6.
- GeoIP-страны качаются с ipdeny.com; TSPUBLOCK/GOVIPS — с GitHub
- RKN Watcher добавляет собственные цепочки INPUT. Проверяйте правила UFW и доступ SSH отдельной сессией после установки защиты.

## 📜 Лицензия

MIT — как и все три исходных проекта.
