#!/usr/bin/env python3
"""Применение денилиста/аллоулиста RKN Watcher.

Логика фильтрации разделена на две независимые стадии, чтобы allow/deny-порты
и фильтр по странам не зависели от FILTER_PORTS:

  INPUT -> HOOK_CHAIN
  HOOK_CHAIN     : loopback -> RETURN, ESTABLISHED,RELATED -> RETURN,
                   затем переход в стадии (deny -> geoip -> защищаемые порты)
  ACTION_DENY    : deny IP -> DROP, deny ports -> DROP, RETURN
  ACTION_GEOIP   : allow IP -> RETURN, allow ports -> RETURN,
                   страна в allow-списке -> RETURN, DROP

Всё применяется одним атомарным iptables-restore, а не серией вызовов
iptables -A: нет гонок с xtables lock, нет полуприменённого состояния.
"""
import ipaddress
import json
import logging
import os
import shutil
import subprocess
import sys
import time
import urllib.error
import urllib.request

CONFIG_FILE = "/etc/rkn-watcher/whitelist.json"
BLACKLIST_FILE = "/etc/rkn-watcher/blacklist.json"
SETTINGS_FILE = "/etc/rkn-watcher/settings.conf"
CACHE_DIR = "/var/lib/rkn-watcher/cache/countries"
LOG_FILE = "/var/log/rkn-watcher/geoip.log"
STATE_DIR = "/var/lib/rkn-watcher/state"

COUNTRY_CACHE_TTL = 24 * 3600
RULE_COMMENT = "rkn-watcher-geoip-hook"
HOOK_CHAIN = "RKN_GEOIP_HOOK"
DENY_CHAIN = "RKN_DENY"
ACTION_CHAIN = "GEOIP_DROP"
PROTECT_CHAIN = "RKN_PROTECT"
ALLOW_IP_SET = "GEOIP_ALLOW_IPS"
DENY_IP_SET = "GEOIP_DENY_IPS"
COUNTRY_SET = "GEOIP_COUNTRIES_ALLOW"
# IPv6-аналоги: allow/deny-списки и страновой набор живут в отдельных inet6-наборах
ALLOW_IP_SET6 = "GEOIP_ALLOW_IPS6"
DENY_IP_SET6 = "GEOIP_DENY_IPS6"
COUNTRY_SET6 = "GEOIP_COUNTRIES_ALLOW6"
# IPv6-стадии живут в отдельной цепочке ip6tables с тем же именем хука
HOOK_CHAIN6 = "RKN_GEOIP_HOOK6"
MANAGED_CHAINS = (HOOK_CHAIN, DENY_CHAIN, ACTION_CHAIN, PROTECT_CHAIN)
MANAGED_CHAINS6 = (HOOK_CHAIN6,)

IPTABLES_WAIT = "5"
MULTIPORT_CHUNK = 15
MAX_PORT_LIST = 64

# Один DROP-фильтр по странам без ограничения по портам легко превращается в
# самоблок, поэтому по умолчанию GeoIP работает только на портах из FILTER_PORTS.
# Осознанно открываем все порты значением GEOIP_SCOPE="all".


_LOGGING_READY = False


def setup_logging():
    """Идемпотентная инициализация: иначе каждый вызов дублирует handler'ы."""
    global _LOGGING_READY
    if _LOGGING_READY:
        return
    _LOGGING_READY = True
    try:
        os.makedirs(os.path.dirname(LOG_FILE), exist_ok=True)
        logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s", filename=LOG_FILE)
        if not sys.stdout.isatty():
            logging.getLogger().addHandler(logging.StreamHandler(sys.stderr))
    except OSError:
        logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s",
                            stream=sys.stderr)


class ConfigError(Exception):
    """Некорректная конфигурация: применять правила нельзя."""


def run(cmd, check=True, capture=False, input_data=None, atomic=False):
    if cmd and cmd[0] in {"iptables", "iptables-restore"} and not atomic:
        cmd = [cmd[0], "-w", IPTABLES_WAIT, *cmd[1:]]
    result = subprocess.run(
        cmd,
        input=input_data,
        text=True,
        capture_output=capture,
        check=False,
    )
    if check and result.returncode != 0:
        raise RuntimeError(f"Command failed ({result.returncode}): {' '.join(cmd)}\n{result.stderr}")
    return result


def remove_input_jump():
    while True:
        result = run(
            ["iptables", "-C", "INPUT", "-m", "comment", "--comment", RULE_COMMENT, "-j", HOOK_CHAIN],
            capture=True,
            check=False,
        )
        if result.returncode != 0:
            break
        run(["iptables", "-D", "INPUT", "-m", "comment", "--comment", RULE_COMMENT, "-j", HOOK_CHAIN], check=False)


def ensure_ipset(name: str, set_type: str = "hash:net", maxelem: int = 2000000,
                 family: str = "inet"):
    run(["ipset", "create", name, set_type, "family", family, "maxelem", str(maxelem), "-exist"],
        check=True)


def set_signature(entries, set_type="hash:net", maxelem=2000000, family="inet"):
    """Сигнатура содержимого набора: позволяет не перестраивать неизменные наборы."""
    import hashlib

    digest = hashlib.sha256()
    digest.update(f"{set_type}|{family}|{maxelem}|{len(entries)}|".encode("utf-8"))
    for entry in entries:
        digest.update(entry.encode("utf-8"))
        digest.update(b"\n")
    return digest.hexdigest()


def replace_set(name: str, entries, set_type: str = "hash:net", maxelem: int = 2000000,
                signature_file=None, force=False, family: str = "inet"):
    """Атомарная замена набора: temp set + swap.

    Если содержимое совпадает с прошлым запуском (по сигнатуре), набор не
    перестраивается: 2 млн записей не заливаются в ipset каждую ночь впустую.
    """
    entries = list(entries)
    if signature_file and not force:
        signature = set_signature(entries, set_type, maxelem, family)
        try:
            with open(signature_file, "r", encoding="utf-8") as fh:
                if fh.read().strip() == signature:
                    logging.info("set %s unchanged (%s entries), skip rebuild", name, len(entries))
                    return len(entries)
        except OSError:
            pass

    temp_name = f"{name}_TMP"
    subprocess.run(["ipset", "-exist", "destroy", temp_name], stdout=subprocess.DEVNULL,
                   stderr=subprocess.DEVNULL, check=False)
    lines = [f"create {temp_name} {set_type} family {family} maxelem {maxelem} -exist",
             f"flush {temp_name}"]
    count = 0
    for entry in entries:
        lines.append(f"add {temp_name} {entry}")
        count += 1
    run(["ipset", "restore"], input_data="\n".join(lines) + "\n")
    ensure_ipset(name, set_type=set_type, maxelem=maxelem, family=family)
    run(["ipset", "swap", temp_name, name])
    subprocess.run(["ipset", "destroy", temp_name], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)

    if signature_file:
        try:
            os.makedirs(os.path.dirname(signature_file), exist_ok=True)
            with open(signature_file, "w", encoding="utf-8") as fh:
                fh.write(set_signature(entries, set_type, maxelem, family) + "\n")
        except OSError:
            pass
    return count


def chunked(values, size=MULTIPORT_CHUNK):
    for index in range(0, len(values), size):
        yield values[index:index + size]


def read_settings(path=None):
    settings = {}
    path = path or SETTINGS_FILE
    if not os.path.exists(path):
        return settings
    with open(path, "r", encoding="utf-8") as fh:
        for raw_line in fh:
            line = raw_line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, value = line.split("=", 1)
            settings[key.strip()] = value.strip().strip('"').strip("'")
    return settings


def load_settings():
    settings = read_settings()
    settings.setdefault("FILTER_PORTS", "all")
    settings.setdefault("PORT_POLICY", "geoip_only")
    return settings


def parse_bool(value, name="value") -> bool:
    if isinstance(value, bool):
        return value
    if isinstance(value, int) and value in (0, 1):
        return bool(value)
    if isinstance(value, str):
        normalized = value.strip().lower()
        if normalized in {"1", "true", "yes", "y", "on"}:
            return True
        if normalized in {"0", "false", "no", "n", "off", ""}:
            return False
    raise ConfigError(f"{name}: ожидается boolean, получено {value!r}")


def load_json(path, default):
    if not os.path.exists(path):
        return dict(default)
    try:
        with open(path, "r", encoding="utf-8") as fh:
            data = json.load(fh)
    except json.JSONDecodeError as exc:
        raise ConfigError(f"{path}: некорректный JSON ({exc})")
    if not isinstance(data, dict):
        raise ConfigError(f"{path}: ожидался JSON-объект")
    merged = dict(default)
    merged.update(data)
    return merged


def split_ip_list(values, name="ips"):
    """Разбирает список адресов/CIDR и разделяет его по семействам.

    IPv4 и IPv6 поддерживаются одновременно; недопустимая запись — ошибка
    конфигурации, а не тихий пропуск.
    """
    v4, v6 = set(), set()
    for value in values:
        try:
            if "/" in str(value):
                parsed = ipaddress.ip_network(str(value), strict=False)
            else:
                parsed = ipaddress.ip_address(str(value))
        except ValueError:
            raise ConfigError(f"{name}: некорректный адрес или сеть {value!r}")
        (v4 if parsed.version == 4 else v6).add(str(parsed))
    return sorted(v4), sorted(v6)


def normalize_ip_list(values, name="ips"):
    """Совместимость: только IPv4-часть списка."""
    return split_ip_list(values, name)[0]


def normalize_port_list(values, name="ports"):
    result = set()
    for value in values:
        try:
            port = int(value)
        except (TypeError, ValueError):
            raise ConfigError(f"{name}: некорректный порт {value!r}")
        if not 1 <= port <= 65535:
            raise ConfigError(f"{name}: порт {port} вне диапазона 1-65535")
        result.add(port)
    if len(result) > MAX_PORT_LIST:
        raise ConfigError(f"{name}: не больше {MAX_PORT_LIST} портов")
    return sorted(result)


def parse_filter_ports(raw_value: str):
    raw_value = (raw_value or "all").strip().lower()
    if raw_value == "all":
        return "all"
    ports = []
    for part in raw_value.split(','):
        part = part.strip()
        if not part:
            continue
        try:
            port = int(part)
        except ValueError:
            raise ConfigError(
                f"FILTER_PORTS: некорректный элемент {part!r} "
                "(ожидается 'all' или список портов через запятую)"
            )
        if not 1 <= port <= 65535:
            raise ConfigError(f"FILTER_PORTS: порт {port} вне диапазона 1-65535")
        ports.append(port)
    if not ports:
        raise ConfigError("FILTER_PORTS: пустое значение")
    return sorted(set(ports))


def parse_port_policy(raw_value: str) -> str:
    """geoip_only: FILTER_PORTS = область действия GeoIP, остальные порты открыты.

    strict: открыты только порты из FILTER_PORTS, всё прочее закрывается.
    """
    policy = (raw_value or "geoip_only").strip().lower()
    aliases = {"geoip_only": "geoip_only", "geoip": "geoip_only", "default": "geoip_only",
               "strict": "strict", "whitelist": "strict", "protected": "strict"}
    if policy not in aliases:
        raise ConfigError("PORT_POLICY: допустимо 'geoip_only' или 'strict'")
    return aliases[policy]


def fetch_country_entries(country_code: str):
    os.makedirs(CACHE_DIR, exist_ok=True)
    cache_path = os.path.join(CACHE_DIR, f"{country_code.lower()}.zone")
    now = time.time()
    content = None
    if os.path.exists(cache_path) and now - os.path.getmtime(cache_path) < COUNTRY_CACHE_TTL:
        with open(cache_path, "r", encoding="utf-8") as fh:
            content = fh.read()
    else:
        url = f"https://www.ipdeny.com/ipblocks/data/aggregated/{country_code.lower()}-aggregated.zone"
        try:
            with urllib.request.urlopen(url, timeout=30) as response:
                content = response.read().decode("utf-8")
            with open(cache_path, "w", encoding="utf-8") as fh:
                fh.write(content)
        except (urllib.error.URLError, urllib.error.HTTPError, OSError, TimeoutError) as exc:
            logging.warning("country %s: download failed (%s), trying cache", country_code, exc)
            if os.path.exists(cache_path):
                with open(cache_path, "r", encoding="utf-8") as fh:
                    content = fh.read()
            else:
                raise ConfigError(f"country {country_code}: источник недоступен и кэша нет") from exc
    entries = set()
    for raw_line in content.splitlines():
        line = raw_line.strip()
        if not line or line.startswith('#'):
            continue
        try:
            network = ipaddress.ip_network(line, strict=False)
        except ValueError:
            continue
        if network.version == 4:
            entries.add(str(network))
    if not entries:
        raise ConfigError(f"country {country_code}: в источнике нет IPv4-сетей")
    return sorted(entries)


def build_country_set(country_codes):
    entries = set()
    failed = []
    for code in country_codes:
        try:
            entries.update(fetch_country_entries(code))
        except ConfigError as exc:
            failed.append(str(exc))
    if failed:
        # Отсутствие страны в наборе = её трафик будет заблокирован, поэтому
        # это ошибка, а не предупреждение, если allow-list вообще используется.
        raise ConfigError("; ".join(failed))
    return sorted(entries)


def iptables_comment(text):
    return ["-m", "comment", "--comment", text]


def chunked_jumps(ports, target, proto="tcp"):
    """Готовые правила-переходы по портам (multiport-чанками)."""
    jumps = []
    for chunk in chunked(ports):
        jumps.append(["-p", proto, "-m", "multiport", "--dports", ",".join(str(p) for p in chunk),
                      "-j", target])
    return jumps


def _port_jumps(ports, target, proto="tcp"):
    """Правила-переходы по портам (multiport-чанками), каждое — отдельный список."""
    rules = []
    for chunk in chunked(ports):
        rules.append(["-p", proto, "-m", "multiport", "--dports",
                      ",".join(str(p) for p in chunk), "-j", target])
    return rules


def build_hook_rules(geoip_enabled, deny_ips, deny_ports, whitelist_ips, whitelist_ports,
                     countries, filter_ports, port_policy,
                     deny_set=DENY_IP_SET, allow_set=ALLOW_IP_SET, country_set=COUNTRY_SET):
    """Собирает правила стадий независимо друг от друга.

    * deny (IP и порты) работает всегда и не зависит от FILTER_PORTS;
    * GeoIP применяется к портам FILTER_PORTS (geoip_only) либо ко всем (all);
    * strict дополнительно закрывает всё, что не перечислено в FILTER_PORTS.
    """
    hook = []
    deny = []
    geoip = []
    protect = []

    # Уже установленные соединения и локальный трафик не трогаем никогда.
    hook += ["-i", "lo", "-j", "RETURN"]
    hook += ["-m", "conntrack", "--ctstate", "ESTABLISHED,RELATED", "-j", "RETURN"]

    if deny_ips:
        deny.append(["-m", "set", "--match-set", deny_set, "src", "-j", "DROP"])
    for chunk in chunked(deny_ports):
        deny.append(["-p", "tcp", "-m", "multiport", "--dports",
                     ",".join(str(p) for p in chunk), "-j", "DROP"])
    if deny:
        deny.append(["-j", "RETURN"])

    if geoip_enabled:
        if whitelist_ips:
            geoip.append(["-m", "set", "--match-set", allow_set, "src", "-j", "RETURN"])
        for chunk in chunked(whitelist_ports):
            geoip.append(["-p", "tcp", "-m", "multiport", "--dports",
                          ",".join(str(p) for p in chunk), "-j", "RETURN"])
        if countries:
            geoip.append(["-m", "set", "--match-set", country_set, "src", "-j", "RETURN"])
            geoip.append(["-j", "DROP"])
        else:
            geoip.append(["-j", "RETURN"])

    # Каждый переход в стадию — отдельное правило хука: так их видно в -L,
    # и они идут после базовых условий (lo, ESTABLISHED).
    stages = []
    jumps = []
    if deny:
        jumps.append(["-m", "comment", "--comment", "rkn-watcher-deny", "-j", DENY_CHAIN])
        stages.append((DENY_CHAIN, deny))

    if geoip:
        if filter_ports == "all":
            jumps.append(["-m", "comment", "--comment", "rkn-watcher-geoip", "-j", ACTION_CHAIN])
        else:
            for jump in chunked_jumps(filter_ports, ACTION_CHAIN):
                jumps.append(["-m", "comment", "--comment", "rkn-watcher-geoip"] + jump)
        stages.append((ACTION_CHAIN, geoip))

    if port_policy == "strict" and filter_ports != "all":
        protect += _port_jumps(filter_ports, "RETURN") + _port_jumps(filter_ports, "RETURN", proto="udp")
        protect.append(["-j", "DROP"])
        for port in filter_ports:
            jumps.append(["-m", "comment", "--comment", "rkn-watcher-strict",
                          "-p", "tcp", "--dport", str(port), "-j", PROTECT_CHAIN])
        stages.append((PROTECT_CHAIN, protect))

    return hook, stages, jumps


def render_ruleset(hook_rules, stages, jumps, chains):
    """Текст для iptables-restore: очистка управляемых цепочек + новые правила."""
    lines = []
    for chain in chains:
        lines.append(f":{chain} - [0:0]")
    # все управляемые цепочки очищаются всегда: иначе правила выключенной
    # подсистемы остались бы в силе
    for chain in chains:
        lines.append(f"-F {chain}")
    hook_chain = chains[0]
    if hook_rules:
        lines.append(f"-A {hook_chain} " + " ".join(hook_rules))
    for jump in jumps:
        lines.append(f"-A {hook_chain} " + " ".join(jump))
    for chain, rules in stages:
        for rule in rules:
            lines.append(f"-A {chain} " + " ".join(rule))
    return "\n".join(lines) + "\n"


def apply_ruleset(hook_rules, stages, jumps, dry_run=False):
    """Атомарно применяет IPv4-набор правил через iptables-restore."""
    body = render_ruleset(hook_rules, stages, jumps, MANAGED_CHAINS)
    if dry_run:
        print("# iptables-restore <")
        print("# DECLARE")
        print("*filter")
        print(body, end="")
        print("COMMIT")
        return body

    backend = backend_args()
    restore_name = f"iptables-{backend[0]}-restore" if backend else "iptables-restore"
    if backend and not shutil.which(restore_name):
        logging.warning("NETFILTER_BACKEND=%s, но %s не найден: используется iptables-restore",
                        backend[0], restore_name)
        restore_name = "iptables-restore"
    restore = shutil.which(restore_name)
    if not restore:
        raise RuntimeError("не найден iptables-restore")
    result = subprocess.run([restore, "-w", IPTABLES_WAIT], input=body, text=True,
                            capture_output=True, check=False)
    if result.returncode != 0:
        raise RuntimeError(f"iptables-restore failed ({result.returncode}): {result.stderr.strip()}")
    remove_input_jump()
    # Хук нужен только если есть хотя бы одна активная стадия; иначе не мусорим в INPUT.
    if jumps:
        run(["iptables", "-I", "INPUT", "1", *iptables_comment(RULE_COMMENT), "-j", HOOK_CHAIN])
    return body


def backend_args():
    """Выбор netfilter-бэкенда из settings.conf: auto|legacy|nft.

    На Debian 11+/Ubuntu 22+ iptables по умолчанию — обёртка над nftables.
    Часть систем (docker, старые правила) требует legacy, а некоторым нужен
    именно nft-frontend; ключ NETFILTER_BACKEND позволяет выбрать явно.
    """
    mode = (read_settings().get("NETFILTER_BACKEND", "auto") or "auto").strip().lower()
    if mode not in {"auto", "legacy", "nft"}:
        raise ConfigError("NETFILTER_BACKEND: допустимо auto, legacy или nft")
    if mode == "auto":
        return []
    return [mode]


def apply_ruleset6(hook_rules, stages, jumps, dry_run=False):
    """IPv6: та же логика, но в ip6tables и в отдельной цепочке RKN_GEOIP_HOOK6."""
    if not shutil.which("ip6tables-restore"):
        logging.warning("ip6tables-restore не найден: IPv6-фильтрация пропущена")
        return ""

    body = render_ruleset(hook_rules, stages, jumps, MANAGED_CHAINS6)
    if dry_run:
        print("# ip6tables-restore <")
        print("# DECLARE")
        print("*filter")
        print(body, end="")
        print("COMMIT")
        return body

    backend = backend_args()
    restore_name = f"ip6tables-{backend[0]}-restore" if backend else "ip6tables-restore"
    if backend and not shutil.which(restore_name):
        logging.warning("NETFILTER_BACKEND=%s, но %s не найден: используется ip6tables-restore",
                        backend[0], restore_name)
        restore_name = "ip6tables-restore"
    result = subprocess.run([restore_name, "-w", IPTABLES_WAIT], input=body, text=True,
                            capture_output=True, check=False)
    if result.returncode != 0:
        raise RuntimeError(f"ip6tables-restore failed ({result.returncode}): {result.stderr.strip()}")

    # хук в INPUT пересоздаём идемпотентно: сначала снять все копии, потом добавить одну
    while True:
        check = run(["ip6tables", "-C", "INPUT", *iptables_comment(RULE_COMMENT), "-j", HOOK_CHAIN6],
                    check=False, capture=True)
        if check.returncode != 0:
            break
        run(["ip6tables", "-D", "INPUT", *iptables_comment(RULE_COMMENT), "-j", HOOK_CHAIN6], check=False)
    if jumps:
        run(["ip6tables", "-I", "INPUT", "1", *iptables_comment(RULE_COMMENT), "-j", HOOK_CHAIN6])
    return body


def apply_geoip(dry_run=False, force=False):
    setup_logging()
    settings = read_settings()
    whitelist = load_json(CONFIG_FILE, {"enabled": False, "countries": [], "ips": [], "ports": []})
    blacklist = load_json(BLACKLIST_FILE, {"ips": [], "ports": []})

    enabled = parse_bool(whitelist.get("enabled", False), "whitelist.enabled")
    whitelist_ips, whitelist_ips6 = split_ip_list(whitelist.get("ips", []), "whitelist.ips")
    blacklist_ips, blacklist_ips6 = split_ip_list(blacklist.get("ips", []), "blacklist.ips")
    whitelist_ports = normalize_port_list(whitelist.get("ports", []), "whitelist.ports")
    blacklist_ports = normalize_port_list(blacklist.get("ports", []), "blacklist.ports")
    countries = sorted({str(c).strip().upper() for c in whitelist.get("countries", [])})
    for code in countries:
        if len(code) != 2 or not code.isalpha():
            raise ConfigError(f"whitelist.countries: некорректный код страны {code!r}")

    filter_ports = parse_filter_ports(settings.get("FILTER_PORTS", "all"))
    port_policy = parse_port_policy(settings.get("PORT_POLICY", "geoip_only"))

    if enabled and port_policy == "geoip_only" and filter_ports == "all":
        warning = (
            "ВНИМАНИЕ: GeoIP включён без FILTER_PORTS, фильтр по стране применяется "
            "ко всем портам. Для доступа к серверу остаются только уже установленные "
            "соединения и GeoIP allow-список. Защитите себя: rkn-watcher allow-my-ip"
        )
        logging.warning(warning)
        print(warning, file=sys.stderr)

    country_entries = build_country_set(countries) if (enabled and countries) else []
    country_entries6 = [e for e in country_entries if ":" in e]
    country_entries4 = [e for e in country_entries if ":" not in e]

    has_ip6 = bool(shutil.which("ip6tables") and shutil.which("ip6tables-restore"))

    if not dry_run:
        replace_set(ALLOW_IP_SET, whitelist_ips, set_type="hash:net", maxelem=65536,
                    signature_file=os.path.join(STATE_DIR, "sig.allow.ips"), force=force)
        replace_set(DENY_IP_SET, blacklist_ips, set_type="hash:net", maxelem=65536,
                    signature_file=os.path.join(STATE_DIR, "sig.deny.ips"), force=force)
        if enabled:
            replace_set(COUNTRY_SET, country_entries4, set_type="hash:net", maxelem=3000000,
                        signature_file=os.path.join(STATE_DIR, "sig.countries"), force=force)
        if has_ip6:
            replace_set(ALLOW_IP_SET6, whitelist_ips6, set_type="hash:net", maxelem=65536,
                        family="inet6", signature_file=os.path.join(STATE_DIR, "sig.allow.ips6"),
                        force=force)
            replace_set(DENY_IP_SET6, blacklist_ips6, set_type="hash:net", maxelem=65536,
                        family="inet6", signature_file=os.path.join(STATE_DIR, "sig.deny.ips6"),
                        force=force)
            if enabled:
                replace_set(COUNTRY_SET6, country_entries6, set_type="hash:net", maxelem=3000000,
                            family="inet6", signature_file=os.path.join(STATE_DIR, "sig.countries6"),
                            force=force)

    hook_rules, stages, jumps = build_hook_rules(
        enabled, blacklist_ips, blacklist_ports, whitelist_ips, whitelist_ports,
        countries if enabled else [], filter_ports, port_policy,
    )
    apply_ruleset(hook_rules, stages, jumps, dry_run=dry_run)

    # IPv6-стадии нужны всегда, когда есть чем управлять: allow/deny для v6,
    # страновой фильтр для v6 или strict-политика на портах
    if has_ip6 and (whitelist_ips6 or blacklist_ips6 or (enabled and country_entries6)
                    or port_policy == "strict"):
        hook6, stages6, jumps6 = build_hook_rules(
            enabled, blacklist_ips6, blacklist_ports, whitelist_ips6, whitelist_ports,
            countries if enabled else [], filter_ports, port_policy,
            deny_set=DENY_IP_SET6, allow_set=ALLOW_IP_SET6, country_set=COUNTRY_SET6,
        )
        apply_ruleset6(hook6, stages6, jumps6, dry_run=dry_run)
    elif has_ip6 and not dry_run:
        # IPv6-хук мог остаться от предыдущих запусков — снимаем его
        apply_ruleset6([], [], [], dry_run=False)

    logging.info(
        "GeoIP applied: backend=%s enabled=%s port_policy=%s countries=%s allow_ips=%s/%s deny_ips=%s/%s "
        "allow_ports=%s deny_ports=%s filter_ports=%s ipv6=%s",
        (backend_args() or ["auto"])[0], enabled, port_policy, len(countries),
        len(whitelist_ips), len(whitelist_ips6),
        len(blacklist_ips), len(blacklist_ips6), len(whitelist_ports), len(blacklist_ports),
        "all" if filter_ports == "all" else len(filter_ports), has_ip6,
    )
    if not dry_run:
        print("GeoIP rules applied" if enabled else "GeoIP filtering disabled")
    return 0


def status():
    for chain in MANAGED_CHAINS:
        result = run(["iptables", "-L", chain, "-v", "-n"], check=False, capture=True)
        print(f"=== {chain} ===")
        print(result.stdout if result.returncode == 0 else "chain absent")
    if shutil.which("ip6tables"):
        result = subprocess.run(["ip6tables", "-w", IPTABLES_WAIT, "-L", HOOK_CHAIN6, "-v", "-n"],
                                text=True, capture_output=True, check=False)
        print(f"=== {HOOK_CHAIN6} ===")
        print(result.stdout if result.returncode == 0 else "chain absent")
    for set_name in (ALLOW_IP_SET, DENY_IP_SET, COUNTRY_SET, HOOK_CHAIN6,
                     ALLOW_IP_SET6, DENY_IP_SET6, COUNTRY_SET6):
        result = run(["ipset", "list", set_name], check=False, capture=True)
        print(f"=== {set_name} ===")
        print(result.stdout if result.returncode == 0 else "set absent")
    return 0


def main(argv):
    setup_logging()
    args = argv[1:]
    if not args:
        print("Usage: geoip_apply.py [apply [--dry-run] [--force]|status]", file=sys.stderr)
        return 1
    cmd = args[0]
    try:
        if cmd == "apply":
            return apply_geoip(dry_run="--dry-run" in args, force="--force" in args)
        if cmd == "status":
            return status()
    except ConfigError as exc:
        logging.error("config error: %s", exc)
        print(f"Ошибка конфигурации: {exc}", file=sys.stderr)
        return 2
    except RuntimeError as exc:
        logging.error("apply failed: %s", exc)
        print(f"Ошибка применения: {exc}", file=sys.stderr)
        return 1
    print(f"Unknown command: {cmd}", file=sys.stderr)
    return 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
