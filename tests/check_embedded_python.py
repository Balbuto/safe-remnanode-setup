#!/usr/bin/env python3
"""
Проверка встроенных Python-хелперов RemnaWave Universal Installer.

Скрипт извлекает heredoc-блоки RKN_PY_CFGTOOL (config_tool.py) и RKN_PY_GEOIP
(geoip_apply.py) из safe-remnanode-setup.sh и проверяет, что каждый из них
является корректным Python-модулем (py_compile).

Используется в GitHub Actions CI (см. .github/workflows/ci.yml), а также может
запускаться локально:

    python3 tests/check_embedded_python.py
"""

import pathlib
import py_compile
import re
import sys
import tempfile

SCRIPT = pathlib.Path(__file__).resolve().parent.parent / "safe-remnanode-setup.sh"

HELPERS = {
    "RKN_PY_CFGTOOL": "config_tool.py",
    "RKN_PY_GEOIP": "geoip_apply.py",
}


def main() -> int:
    if not SCRIPT.is_file():
        print(f"FAIL: не найден скрипт: {SCRIPT}", file=sys.stderr)
        return 1

    source = SCRIPT.read_text(encoding="utf-8")
    failed = False

    with tempfile.TemporaryDirectory(prefix="rnu-check-") as tmp_dir:
        for marker, filename in HELPERS.items():
            match = re.search(r"<<'" + marker + r"'\n(.*?)\n" + marker, source, re.S)
            if not match:
                print(f"FAIL: heredoc-блок '{marker}' не найден в {SCRIPT.name}")
                failed = True
                continue

            helper_path = pathlib.Path(tmp_dir) / filename
            helper_path.write_text(match.group(1), encoding="utf-8")

            try:
                py_compile.compile(str(helper_path), doraise=True)
                print(f"OK: {filename} (heredoc '{marker}') компилируется")
            except py_compile.PyCompileError as exc:
                print(f"FAIL: {filename}: {exc}")
                failed = True

    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
