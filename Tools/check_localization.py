#!/usr/bin/env python3
"""Проверка перевода интерфейса: каждая русская строка из App/Sources должна быть в en.lproj/Localizable.strings.

    python3 Tools/check_localization.py          # список непереведённых строк, код возврата 1 если есть
    python3 Tools/check_localization.py --keys   # все строки интерфейса по одной на строку

Строки с подстановкой `\\(…)` перевести нельзя — их нужно переписать через L("… %@", значение).
Отладочные файлы (SelfTest.swift) и комментарии не учитываются.
"""
import pathlib, re, sys

root = pathlib.Path(__file__).resolve().parent.parent
sources = sorted((root / "App/Sources").glob("*.swift"))
skip = {"SelfTest.swift"}
literal = re.compile(r'"((?:[^"\\]|\\.)*)"')
cyrillic = re.compile(r"[А-Яа-яЁё]")
# Слова-примеры, которые набирает человек: это данные, а не интерфейс.
examples = {"руддщ", "привет"}


def keys():
    found = {}
    for path in sources:
        if path.name in skip:
            continue
        for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
            code = line.split("//")[0] if line.strip().startswith("//") or " // " in line else line
            if "NSLog(" in code or "note(" in code:
                continue
            for text in literal.findall(code):
                if cyrillic.search(text) and text not in examples:
                    found.setdefault(text.replace('\\"', '"'), f"{path.name}:{number}")
    return found


def translated():
    text = (root / "App/Resources/en.lproj/Localizable.strings").read_text(encoding="utf-8")
    return {key.replace('\\"', '"') for key in re.findall(r'^"((?:[^"\\]|\\.)*)"\s*=', text, re.M)}


def main():
    found = keys()
    if "--keys" in sys.argv:
        print("\n".join(found))
        return 0
    have = translated()
    bad = 0
    for key, where in found.items():
        if "\\(" in key:
            print(f"подстановка в строке, перевести нельзя — {where}: {key}")
            bad += 1
        elif key not in have:
            print(f"нет перевода — {where}: {key}")
            bad += 1
    unused = sorted(have - set(found))
    for key in unused:
        print(f"перевод больше не нужен: {key}")
    print(f"строк интерфейса: {len(found)}, без перевода: {bad}, лишних переводов: {len(unused)}")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
