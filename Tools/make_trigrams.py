#!/usr/bin/env python3
"""Строит списки допустимых буквенных триграмм для запасной эвристики детектора.

Использование: make_trigrams.py <ru_words.txt> <en_words.txt> > Trigrams.swift
Из словарей берётся только статистика сочетаний букв, сами слова в приложение не попадают.
"""
import collections, sys

def trigrams(path, alphabet, threshold):
    counts = collections.Counter()
    for line in open(path, encoding="utf-8", errors="ignore"):
        w = line.strip().lower()
        if len(w) < 3 or any(c not in alphabet for c in w):
            continue
        s = "^" + w + "$"
        for i in range(len(s) - 2):
            counts[s[i:i + 3]] += 1
    return sorted(t for t, n in counts.items() if n >= threshold)

ru = trigrams(sys.argv[1], set("абвгдеёжзийклмнопрстуфхцчшщъыьэюя"), 4)
en = trigrams(sys.argv[2], set("abcdefghijklmnopqrstuvwxyz"), 12)
print("// Сгенерировано Tools/make_trigrams.py — не редактировать вручную.")
print("enum TrigramData {")
for name, data in (("ru", ru), ("en", en)):
    print(f'    static let {name} = """')
    for i in range(0, len(data), 28):
        print("        " + " ".join(data[i:i + 28]))
    print('        """')
print("}")
sys.stderr.write(f"ru {len(ru)} en {len(en)}\n")
