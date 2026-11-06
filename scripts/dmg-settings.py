# What scripts/build-dmg.sh asks dmgbuild for: the normal Mac installer window, with the app
# on the left and a link to Applications on the right. dmgbuild lays this out without
# opening Finder, so building it doesn't ask for any permissions.
format = "UDZO"
files = [defines["app"]]
symlinks = {"Applications": "/Applications"}
icon = defines["icon"]
background = defines["background"]

window_rect = ((200, 140), (600, 380))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
icon_size = 120
text_size = 14
# Don't use hide_extensions. It marks the app in a way that breaks its code signature,
# and macOS then calls a downloaded copy damaged, with no way to open it.
icon_locations = {
    "Podcast Reader.app": (150, 170),
    "Applications": (450, 170),
}
