#!/usr/bin/env python3
# dmgbuild settings for Copied
# Usage: python3 -m dmgbuild -s dmg_settings.py "Copied" .build/Copied.dmg

# ── Disk Image ──
volume_name = "Copied"
format = "UDZO"
filesystem = "HFS+"
size = None

# ── Files ──
files = [".build/Copied.app"]
symlinks = {"Applications": "/Applications"}

# ── Background Image ──
background = "dmg_background.png"

# ── Window ──
# 背景图: 440×240
# 窗口 bounds 包含标题栏（32px）和 Finder 底部位置栏（27px）
# window_height = 240 + 32 + 27 = 299
# window_rect = ((left, top), (width, height))
window_rect = ((200, 200), (440, 299))

default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False

# ── Icon View ──
icon_size = 80
text_size = 12
arrange_by = None  # manual placement
grid_spacing = 54
grid_offset = (0, 0)
scroll_position = (0, 0)
label_pos = "bottom"
show_icon_preview = True
show_item_info = False

# ── Icon Positions ──
# y=120 与 240px 背景的垂直中心对齐
icon_locations = {
    "Copied.app": (110, 120),
    "Applications": (330, 120),
}
