# dmgbuild settings for the Remora DMG. mise-tasks/release/dmg passes the app path as -D app=<path>.
# Paths are relative to the repository root, where mise runs the task.
# dmgbuild pairs background.png with background@2x.png for Retina displays.
# background.svg is the source of both PNGs: rsvg-convert -w 660 background.svg -o background.png
import os.path

app = defines["app"]  # noqa: F821, dmgbuild defines it

format = "ULFO"
filesystem = "APFS"
files = [app]
symlinks = {"Applications": "/Applications"}
icon = os.path.join(app, "Contents/Resources/AppIcon.icns")
background = "assets/dmg/background.png"
# The height adds 32 points for the title bar above the 660 x 400 background.
window_rect = ((200, 120), (660, 432))
icon_size = 128
text_size = 13
icon_locations = {os.path.basename(app): (165, 190), "Applications": (495, 190)}
