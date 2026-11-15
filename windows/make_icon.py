"""Draws icon.ico for the .exe (same icon as in the tray)."""
from main import make_icon_image

images = [make_icon_image(s) for s in (16, 24, 32, 48, 64, 128, 256)]
images[-1].save("icon.ico", sizes=[(i.width, i.height) for i in images])
print("icon.ico ready")
