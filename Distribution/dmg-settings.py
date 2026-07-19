"""Deterministic Finder layout for the public Slaptop disk image."""

app_path = defines.get("app_path")
background_path = defines.get("background_path")

if not app_path:
    raise ValueError("dmgbuild requires -D app_path=<path>")
if not background_path:
    raise ValueError("dmgbuild requires -D background_path=<path>")

files = [app_path]
symlinks = {"Applications": "/Applications"}
hide_extensions = ["Slaptop.app"]

format = "UDZO"
filesystem = "HFS+"
compression_level = 9

background = background_path
window_rect = ((160, 120), (660, 400))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False

arrange_by = None
label_pos = "bottom"
text_size = 13
icon_size = 112
show_icon_preview = False
include_icon_view_settings = True
include_list_view_settings = False
icon_locations = {
    "Slaptop.app": (170, 210),
    "Applications": (490, 210),
}
