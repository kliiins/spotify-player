"""Spotify Player for Windows.

What it does:
  • starts the local server (server/server.py) in the background;
  • shows the player window on Shift+Space (or when the tray icon is clicked);
  • tray icon: open, log in to Spotify, start with Windows, quit.
"""

import ctypes
import os
import sys
import threading
import time
import webbrowser

import requests
import webview

HERE = getattr(sys, "_MEIPASS", os.path.dirname(os.path.abspath(__file__)))
if not getattr(sys, "frozen", False):
    # общий сервер лежит в ../server (одинаковый для macOS и Windows)
    sys.path.insert(0, os.path.join(HERE, "..", "server"))

import server  # noqa: E402

server.UI_DIR = os.path.join(HERE, "ui")

APP_NAME = "Spotify Player"
URL = "http://127.0.0.1:8888"
WIDTH, HEIGHT = 640, 295
IS_WINDOWS = os.name == "nt"


# ==========================================
# ОКНО
# ==========================================

class Api:
    """Функции, которые JavaScript окна может вызвать через window.pywebview.api."""

    def hide(self):
        controller.hide()

    def open_url(self, url):
        if url.startswith(("http://127.0.0.1", "https://t.me/", "https://developer.spotify.com/")):
            webbrowser.open(url)


class Controller:
    def __init__(self):
        self.window = None
        self.visible = False
        self.lock = threading.Lock()

    def create(self):
        self.window = webview.create_window(
            APP_NAME,
            f"{URL}/ui",
            js_api=Api(),
            width=WIDTH,
            height=HEIGHT,
            resizable=False,
            frameless=True,
            easy_drag=False,
            on_top=True,
            hidden=True,
            focus=True,
            background_color="#0d0d10",
        )
        self.window.events.shown += self._style_window
        return self.window

    def _style_window(self):
        """Windows 11: rounded corners and no light system border."""
        if not IS_WINDOWS:
            return
        try:
            hwnd = int(self.window.native.Handle.ToInt64())
            DWMWA_WINDOW_CORNER_PREFERENCE = 33
            DWMWCP_ROUND = 2
            value = ctypes.c_int(DWMWCP_ROUND)
            ctypes.windll.dwmapi.DwmSetWindowAttribute(
                hwnd, DWMWA_WINDOW_CORNER_PREFERENCE, ctypes.byref(value), ctypes.sizeof(value)
            )
            # без светлой системной рамки вокруг окна
            DWMWA_BORDER_COLOR = 34
            DWMWA_COLOR_NONE = ctypes.c_uint(0xFFFFFFFE)
            ctypes.windll.dwmapi.DwmSetWindowAttribute(
                hwnd, DWMWA_BORDER_COLOR, ctypes.byref(DWMWA_COLOR_NONE), ctypes.sizeof(DWMWA_COLOR_NONE)
            )
        except Exception as error:  # на Windows 10 просто без скругления
            print("WINDOW STYLE:", error)

    def center(self):
        try:
            screen = webview.screens[0]
            x = screen.x + (screen.width - WIDTH) // 2
            y = screen.y + int((screen.height - HEIGHT) * 0.38)
            self.window.move(x, y)
        except Exception:
            pass

    def show(self):
        with self.lock:
            if not self.window:
                return
            self.center()
            self.window.show()
            self.window.restore()
            self._bring_to_front()
            self.visible = True
        self.window.evaluate_js("window.onShown && window.onShown()")

    def hide(self):
        with self.lock:
            if self.window and self.visible:
                self.window.hide()
                self.visible = False

    def toggle(self):
        if self.visible:
            self.window.evaluate_js("hide()")  # плавное исчезновение, потом api.hide()
        else:
            self.show()

    def _bring_to_front(self):
        """Окно должно получить фокус клавиатуры, чтобы сразу можно было печатать."""
        if not IS_WINDOWS:
            return
        try:
            hwnd = int(self.window.native.Handle.ToInt64())
            user32 = ctypes.windll.user32
            # трюк с Alt: Windows разрешает SetForegroundWindow после «нажатия» клавиши
            user32.keybd_event(0x12, 0, 0, 0)
            user32.keybd_event(0x12, 0, 2, 0)
            user32.SetForegroundWindow(hwnd)
        except Exception as error:
            print("FOCUS:", error)


controller = Controller()


# ==========================================
# ГОРЯЧАЯ КЛАВИША Shift+Пробел
# ==========================================

def setup_hotkey():
    try:
        import keyboard  # работает на Windows без прав администратора

        keyboard.add_hotkey("shift+space", controller.toggle, suppress=True)
        print("HOTKEY: Shift+Space")
    except Exception as error:
        print("HOTKEY ERROR:", error)


# ==========================================
# АВТОЗАПУСК С WINDOWS
# ==========================================

RUN_KEY = r"Software\Microsoft\Windows\CurrentVersion\Run"


def autostart_enabled(_item=None):
    if not IS_WINDOWS:
        return False
    import winreg
    try:
        with winreg.OpenKey(winreg.HKEY_CURRENT_USER, RUN_KEY) as key:
            winreg.QueryValueEx(key, APP_NAME)
            return True
    except OSError:
        return False


def toggle_autostart(_icon=None, _item=None):
    if not IS_WINDOWS:
        return
    import winreg
    with winreg.OpenKey(winreg.HKEY_CURRENT_USER, RUN_KEY, 0, winreg.KEY_SET_VALUE) as key:
        if autostart_enabled():
            winreg.DeleteValue(key, APP_NAME)
        else:
            if getattr(sys, "frozen", False):          # собранный .exe
                command = f'"{sys.executable}"'
            else:                                       # запуск из исходников
                command = f'"{sys.executable}" "{os.path.abspath(__file__)}"'
            winreg.SetValueEx(key, APP_NAME, 0, winreg.REG_SZ, command)


# ==========================================
# ТРЕЙ
# ==========================================

def make_icon_image(size=64):
    """Зелёный кружок со звуковой волной — рисуется кодом, файлы не нужны."""
    from PIL import Image, ImageDraw

    scale = 4
    s = size * scale
    img = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    d.ellipse((0, 0, s - 1, s - 1), fill=(31, 219, 107, 255))
    bars = [0.30, 0.55, 0.85, 0.55, 0.30]
    bar_w = s * 0.08
    gap = s * 0.05
    total = len(bars) * bar_w + (len(bars) - 1) * gap
    x = (s - total) / 2
    for h in bars:
        bh = s * 0.55 * h
        y0 = (s - bh) / 2
        d.rounded_rectangle((x, y0, x + bar_w, y0 + bh), radius=bar_w / 2, fill=(10, 10, 12, 255))
        x += bar_w + gap
    return img.resize((size, size), Image.LANCZOS)


def setup_tray():
    try:
        import pystray
    except ImportError:
        print("TRAY: pystray is not installed")
        return None

    def open_window(_icon=None, _item=None):
        controller.show()

    def login(_icon=None, _item=None):
        webbrowser.open(f"{URL}/login")

    def quit_app(icon, _item=None):
        icon.stop()
        os._exit(0)

    menu = pystray.Menu(
        pystray.MenuItem("Open  (Shift+Space)", open_window, default=True),
        pystray.MenuItem("Log in to Spotify…", login),
        pystray.MenuItem("Start with Windows", toggle_autostart, checked=autostart_enabled),
        pystray.Menu.SEPARATOR,
        pystray.MenuItem("Quit", quit_app),
    )
    icon = pystray.Icon("spotify_player", make_icon_image(), APP_NAME, menu)
    icon.run_detached()
    return icon


# ==========================================
# ЗАПУСК
# ==========================================

def server_running():
    try:
        return requests.get(f"{URL}/health", timeout=1).ok
    except requests.RequestException:
        return False


def start_server():
    if server_running():
        print("SERVER: already running")
        return
    threading.Thread(target=server.run_server, daemon=True).start()
    for _ in range(50):
        if server_running():
            return
        time.sleep(0.1)


def on_ready():
    """Вызывается pywebview, когда окно создано."""
    setup_hotkey()
    setup_tray()

    status = requests.get(f"{URL}/native-status", timeout=3).json()
    if not status.get("configured"):
        webbrowser.open(f"{URL}/setup")       # first run: enter Spotify keys
    elif not status.get("logged_in"):
        webbrowser.open(f"{URL}/login")       # keys exist, but not logged in yet

    controller.show()


def main():
    if IS_WINDOWS:
        # чёткий текст на экранах с масштабированием
        try:
            ctypes.windll.shcore.SetProcessDpiAwareness(2)
        except Exception:
            pass

    start_server()
    controller.create()
    webview.start(on_ready, gui="edgechromium" if IS_WINDOWS else None, private_mode=False)


if __name__ == "__main__":
    main()
