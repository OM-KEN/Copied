#!/usr/bin/env python3
# dmgbuild settings for Copied
# Usage: python3 -m dmgbuild -s dmg_settings.py "Copied" .build/Copied.dmg

import os.path

# ── Disk Image ──
volume_name = "Copied"
format = "UDZO"
filesystem = "HFS+"
size = None

# ── Files ──
files = [".build/Copied.app"]
symlinks = {"Applications": "/Applications"}

# ── Background Image (optional) ──
_bg_png = ".build/dmg_background.png"
background = _bg_png if os.path.exists(_bg_png) else None

# ── Window ──
# 背景图: 440×240
# 窗口 bounds 包含标题栏 (~28px macOS 26)
# 内容区域 = window_height - titlebar_height = 背景图高度
# window_height = 240 + 28 = 268
# window_rect = ((left, top), (width, height))
window_rect = ((200, 200), (440, 268))

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
icon_locations = {
    "Copied.app": (110, 120),
    "Applications": (330, 120),
}
