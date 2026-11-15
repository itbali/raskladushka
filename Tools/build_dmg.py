#!/usr/bin/python3
"""Собирает установочный образ с фоном: Tools/build_dmg.py <Raskladushka.app> <образ.dmg>

Нужен dmgbuild (pip3 install dmgbuild). Он записывает раскладку окна прямо в образ, Finder не открывается.

Одна поправка после dmgbuild. Ссылку на фоновую картинку он пишет двумя способами: классическим псевдонимом
и закладкой (запись pBBk). Finder в macOS 26 берёт закладку, не может по ней найти картинку и фон не рисует
вовсе (проверено на 26.6). С одним псевдонимом фон показывается. Поэтому закладку убираем.
"""
import os, subprocess, sys, tempfile

import dmgbuild
from ds_store import DSStore

root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    app, out = sys.argv[1], sys.argv[2]
    with tempfile.TemporaryDirectory() as tmp:
        raw = os.path.join(tmp, "raw.dmg")
        dmgbuild.build_dmg(raw, "Раскладушка", os.path.join(root, "Tools/dmg_settings.py"),
                           defines={"app": app, "background": os.path.join(root, "Design/dmg-background.png")})
        mount = os.path.join(tmp, "mount")
        os.mkdir(mount)
        subprocess.run(["hdiutil", "attach", "-nobrowse", "-quiet", "-mountpoint", mount, raw], check=True)
        try:
            store = os.path.join(mount, ".DS_Store")
            with DSStore.open(store, "r+") as d:
                d.delete(".", b"pBBk")
            with DSStore.open(store, "r") as d:
                codes = {e.code for e in d if e.filename == "."}
            if b"pBBk" in codes or b"icvp" not in codes:
                sys.exit("не удалось поправить настройки окна образа: %s" % sorted(codes))
        finally:
            subprocess.run(["hdiutil", "detach", "-quiet", mount], check=True)
        if os.path.exists(out):
            os.remove(out)
        subprocess.run(["hdiutil", "convert", raw, "-format", "UDZO", "-imagekey", "zlib-level=9",
                        "-o", out, "-quiet"], check=True)
    print("образ:", out)


if __name__ == "__main__":
    main()
