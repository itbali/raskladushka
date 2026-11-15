# Настройки dmgbuild: окно образа с фоном, значок приложения слева, папка «Программы» справа.
# Раскладка окна записывается прямо в файл образа — Finder на этом компьютере не открывается.
# Сам образ собирает Tools/build_dmg.py — он зовёт dmgbuild с этими настройками.
import os

app = defines["app"]  # noqa: F821 — имя подставляет dmgbuild
name = os.path.basename(app)

# Образ пока на запись: после сборки build_dmg.py правит в нём настройки окна и только потом сжимает.
format = "UDRW"
files = [app]
symlinks = {"Applications": "/Applications"}
background = defines["background"]  # noqa: F821
window_rect = ((200, 160), (600, 460))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
icon_size = 112
text_size = 13
icon_locations = {name: (150, 215), "Applications": (450, 215)}
