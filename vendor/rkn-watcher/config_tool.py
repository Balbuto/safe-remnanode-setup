#!/usr/bin/env python3
import fcntl
import ipaddress
import json
import os
import sys
import tempfile

WHITELIST_FILE = "/etc/rkn-watcher/whitelist.json"
BLACKLIST_FILE = "/etc/rkn-watcher/blacklist.json"

DEFAULT_WHITELIST = {
    "enabled": False,
    "countries": [],
    "ips": [],
    "ports": []
}

DEFAULT_BLACKLIST = {
    "ips": [],
    "ports": []
}


def normalize_ip(value: str) -> str:
    """IPv4 и IPv6: семейство определяется автоматически.

    IPv6-записи попадают в отдельные inet6-наборы (см. geoip_apply.py).
    """
    value = value.strip()
    if "/" in value:
        network = ipaddress.ip_network(value, strict=False)
        return str(network)
    address = ipaddress.ip_address(value)
    return str(address)


def normalize_port(value: str) -> int:
    port = int(value)
    if port < 1 or port > 65535:
        raise ValueError("port out of range")
    return port


def normalize_country(value: str) -> str:
    value = value.strip().upper()
    if len(value) != 2 or not value.isalpha():
        raise ValueError("invalid country code")
    return value


def normalize_enabled(value) -> bool:
    """Accept JSON booleans and common legacy boolean representations."""
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
    raise ValueError("enabled must be a boolean")


def load_json(path: str, default: dict) -> dict:
    if not os.path.exists(path):
        return json.loads(json.dumps(default))
    with open(path, "r", encoding="utf-8") as fh:
        data = json.load(fh)
    if not isinstance(data, dict):
        return json.loads(json.dumps(default))
    merged = json.loads(json.dumps(default))
    merged.update(data)
    if "countries" in merged:
        merged["countries"] = sorted({normalize_country(v) for v in merged.get("countries", [])})
    if "ips" in merged:
        merged["ips"] = sorted({normalize_ip(v) for v in merged.get("ips", [])})
    if "ports" in merged:
        merged["ports"] = sorted({normalize_port(str(v)) for v in merged.get("ports", [])})
    if "enabled" in merged:
        merged["enabled"] = normalize_enabled(merged.get("enabled", False))
    return merged


def save_json_atomic(path: str, data: dict) -> None:
    fd, tmp_path = tempfile.mkstemp(dir=os.path.dirname(path), prefix=os.path.basename(path) + ".", text=True)
    try:
        # секретов в файле нет, но права должны быть предсказуемыми
        os.fchmod(fd, 0o644)
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            json.dump(data, fh, indent=4, ensure_ascii=False, sort_keys=True)
            fh.write("\n")
        os.replace(tmp_path, path)
    finally:
        if os.path.exists(tmp_path):
            os.unlink(tmp_path)


def update_json_locked(path: str, default: dict, updater):
    """Run a read-modify-write update while holding one advisory file lock."""
    os.makedirs(os.path.dirname(path), exist_ok=True)
    lock_path = path + ".lock"
    with open(lock_path, "a", encoding="utf-8") as lock_handle:
        fcntl.flock(lock_handle.fileno(), fcntl.LOCK_EX)
        data = load_json(path, default)
        changed, result = updater(data)
        if changed:
            save_json_atomic(path, data)
        return result


def edit_list(path: str, default: dict, key: str, action: str, value):
    def update(data):
        current = set(data.get(key, []))
        if action == "add":
            if value in current:
                return False, "EXISTS"
            current.add(value)
            data[key] = sorted(current)
            return True, "ADDED"
        if action == "remove":
            if value not in current:
                return False, "NOT_FOUND"
            current.remove(value)
            data[key] = sorted(current)
            return True, "REMOVED"
        raise ValueError("Unsupported action")

    print(update_json_locked(path, default, update))
    return 0


def set_enabled(value: str):
    normalized = normalize_enabled(value)

    def update(data):
        data["enabled"] = normalized
        return True, None

    update_json_locked(WHITELIST_FILE, DEFAULT_WHITELIST, update)
    print("ENABLED" if normalized else "DISABLED")
    return 0


def normalize_file(path: str, default: dict, keys: tuple) -> str:
    """Перезаписывает файл нормализованными значениями (или создаёт его).

    Раньше нормализация происходила только в памяти при чтении, поэтому
    legacy-значения из старых версий оставались в файле навсегда.
    """
    def update(data):
        changed = False
        for key in keys:
            if key not in default:
                continue
            value = data.get(key, default[key])
            normalized = load_json_value(key, value)
            if data.get(key) != normalized:
                changed = True
            data[key] = normalized
        # даже без изменений перезаписываем, чтобы поправить формат/права
        return True, "NORMALIZED" if changed else "UNCHANGED"

    result = update_json_locked(path, default, update)
    os.chmod(path, 0o644)
    return result


def load_json_value(key, value):
    if key == "countries":
        return sorted({normalize_country(v) for v in value})
    if key == "ips":
        return sorted({normalize_ip(v) for v in value})
    if key == "ports":
        return sorted({normalize_port(str(v)) for v in value})
    if key == "enabled":
        return normalize_enabled(value)
    return value


def get_enabled():
    data = load_json(WHITELIST_FILE, DEFAULT_WHITELIST)
    print("true" if data.get("enabled", False) else "false")
    return 0


def show(which: str):
    if which == "whitelist":
        print(json.dumps(load_json(WHITELIST_FILE, DEFAULT_WHITELIST), indent=4, ensure_ascii=False, sort_keys=True))
        return 0
    if which == "blacklist":
        print(json.dumps(load_json(BLACKLIST_FILE, DEFAULT_BLACKLIST), indent=4, ensure_ascii=False, sort_keys=True))
        return 0
    result = {
        "whitelist": load_json(WHITELIST_FILE, DEFAULT_WHITELIST),
        "blacklist": load_json(BLACKLIST_FILE, DEFAULT_BLACKLIST)
    }
    print(json.dumps(result, indent=4, ensure_ascii=False, sort_keys=True))
    return 0


def main(argv):
    if len(argv) < 2:
        print("Usage: config_tool.py <add-country|remove-country|add-ip|remove-ip|add-port|"
              "remove-port|add-deny-ip|remove-deny-ip|add-deny-port|remove-deny-port|"
              "set-enabled|get-enabled|normalize|show> [args...]", file=sys.stderr)
        return 1
    cmd = argv[1]
    try:
        if cmd == "add-country":
            return edit_list(WHITELIST_FILE, DEFAULT_WHITELIST, "countries", "add", normalize_country(argv[2]))
        if cmd == "remove-country":
            return edit_list(WHITELIST_FILE, DEFAULT_WHITELIST, "countries", "remove", normalize_country(argv[2]))
        if cmd == "add-ip":
            return edit_list(WHITELIST_FILE, DEFAULT_WHITELIST, "ips", "add", normalize_ip(argv[2]))
        if cmd == "remove-ip":
            return edit_list(WHITELIST_FILE, DEFAULT_WHITELIST, "ips", "remove", normalize_ip(argv[2]))
        if cmd == "add-port":
            return edit_list(WHITELIST_FILE, DEFAULT_WHITELIST, "ports", "add", normalize_port(argv[2]))
        if cmd == "remove-port":
            return edit_list(WHITELIST_FILE, DEFAULT_WHITELIST, "ports", "remove", normalize_port(argv[2]))
        if cmd == "add-deny-ip":
            return edit_list(BLACKLIST_FILE, DEFAULT_BLACKLIST, "ips", "add", normalize_ip(argv[2]))
        if cmd == "remove-deny-ip":
            return edit_list(BLACKLIST_FILE, DEFAULT_BLACKLIST, "ips", "remove", normalize_ip(argv[2]))
        if cmd == "add-deny-port":
            return edit_list(BLACKLIST_FILE, DEFAULT_BLACKLIST, "ports", "add", normalize_port(argv[2]))
        if cmd == "remove-deny-port":
            return edit_list(BLACKLIST_FILE, DEFAULT_BLACKLIST, "ports", "remove", normalize_port(argv[2]))
        if cmd == "set-enabled":
            return set_enabled(argv[2])
        if cmd == "get-enabled":
            return get_enabled()
        if cmd == "normalize":
            wl = normalize_file(WHITELIST_FILE, DEFAULT_WHITELIST, ("enabled", "countries", "ips", "ports"))
            bl = normalize_file(BLACKLIST_FILE, DEFAULT_BLACKLIST, ("ips", "ports"))
            print(f"whitelist:{wl} blacklist:{bl}")
            return 0
        if cmd == "show":
            which = argv[2] if len(argv) > 2 else "all"
            return show(which)
        print(f"Unknown command: {cmd}", file=sys.stderr)
        return 1
    except IndexError:
        print("Missing argument", file=sys.stderr)
        return 1
    except Exception as exc:
        print(str(exc), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
