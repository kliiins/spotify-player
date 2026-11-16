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
# WIN32: фокус окон и горячая клавиша
# ==========================================

if IS_WINDOWS:
    from ctypes import wintypes

    user32 = ctypes.windll.user32
    kernel32 = ctypes.windll.kernel32

    user32.GetForegroundWindow.restype = wintypes.HWND
    user32.SetForegroundWindow.argtypes = [wintypes.HWND]
    user32.BringWindowToTop.argtypes = [wintypes.HWND]
    user32.SetFocus.argtypes = [wintypes.HWND]
    user32.IsWindow.argtypes = [wintypes.HWND]
    user32.IsWindowVisible.argtypes = [wintypes.HWND]
    user32.GetWindowThreadProcessId.argtypes = [wintypes.HWND, ctypes.POINTER(wintypes.DWORD)]
    user32.GetWindowThreadProcessId.restype = wintypes.DWORD
    user32.AttachThreadInput.argtypes = [wintypes.DWORD, wintypes.DWORD, wintypes.BOOL]
    user32.GetWindowTextW.argtypes = [wintypes.HWND, wintypes.LPWSTR, ctypes.c_int]
    user32.GetClassNameW.argtypes = [wintypes.HWND, wintypes.LPWSTR, ctypes.c_int]
    user32.RegisterHotKey.argtypes = [wintypes.HWND, ctypes.c_int, wintypes.UINT, wintypes.UINT]
    user32.GetMessageW.argtypes = [ctypes.POINTER(wintypes.MSG), wintypes.HWND, wintypes.UINT, wintypes.UINT]

    EnumWindowsProc = ctypes.WINFUNCTYPE(wintypes.BOOL, wintypes.HWND, wintypes.LPARAM)


def find_own_window():
    """HWND окна плеера: ищем окно нашего процесса с нашим заголовком."""
    found = []
    pid = os.getpid()

    def callback(hwnd, _):
        owner = wintypes.DWORD()
        user32.GetWindowThreadProcessId(hwnd, ctypes.byref(owner))
        if owner.value == pid:
            title = ctypes.create_unicode_buffer(128)
            user32.GetWindowTextW(hwnd, title, 128)
            klass = ctypes.create_unicode_buffer(128)
            user32.GetClassNameW(hwnd, klass, 128)
            # окно pywebview — это форма WinForms; скрытое окно значка в трее не подходит
            if title.value == APP_NAME and klass.value.startswith("WindowsForms"):
                found.append(hwnd)
                return False
        return True

    user32.EnumWindows(EnumWindowsProc(callback), 0)
    return found[0] if found else None


def force_foreground(hwnd):
    """Сделать окно активным и отдать ему клавиатуру — без «нажатий» Alt.

    Раньше для этого программно жали Alt, но вместе с зажатым Shift (от Shift+Пробел)
    это превращалось в Alt+Shift и переключало язык ввода. Теперь на мгновение
    подключаемся к очереди ввода текущего активного окна — так Windows разрешает
    сменить активное окно честно.
    """
    if not hwnd or not user32.IsWindow(hwnd):
        return
    current = kernel32.GetCurrentThreadId()
    foreground = user32.GetForegroundWindow()
    fg_thread = user32.GetWindowThreadProcessId(foreground, None) if foreground else 0
    target_thread = user32.GetWindowThreadProcessId(hwnd, None)

    attached = []
    for thread in {fg_thread, target_thread}:
        if thread and thread != current and user32.AttachThreadInput(current, thread, True):
            attached.append(thread)
    try:
        user32.BringWindowToTop(hwnd)
        user32.SetForegroundWindow(hwnd)
        user32.SetFocus(hwnd)
    finally:
        for thread in attached:
            user32.AttachThreadInput(current, thread, False)


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
        self.hwnd = None            # HWND окна плеера
        self.previous_hwnd = None   # окно, в котором пользователь был до Shift+Пробел

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
            self.hwnd = hwnd
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
            if IS_WINDOWS:
                self.hwnd = self.hwnd or find_own_window()
                previous = user32.GetForegroundWindow()
                if previous and previous != self.hwnd:
                    self.previous_hwnd = previous
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
                # вернуть клавиатуру туда, где пользователь печатал до Shift+Пробел
                if IS_WINDOWS and self.previous_hwnd and user32.IsWindowVisible(self.previous_hwnd):
                    force_foreground(self.previous_hwnd)
                self.previous_hwnd = None

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
            self.hwnd = self.hwnd or find_own_window()
            force_foreground(self.hwnd)
        except Exception as error:
            print("FOCUS:", error)


controller = Controller()


# ==========================================
# ГОРЯЧАЯ КЛАВИША Shift+Пробел
# ==========================================

def setup_hotkey():
    """Системная горячая клавиша Windows (RegisterHotKey).

    Раньше использовалась библиотека keyboard: она перехватывает ВСЕ нажатия
    в системе и из-за этого иногда «залипали» Shift/фокус. RegisterHotKey
    получает только само сочетание Shift+Пробел и больше ничего не трогает.
    """
    if not IS_WINDOWS:
        return

    MOD_SHIFT = 0x0004
    MOD_NOREPEAT = 0x4000
    VK_SPACE = 0x20
    WM_HOTKEY = 0x0312

    def loop():
        if not user32.RegisterHotKey(None, 1, MOD_SHIFT | MOD_NOREPEAT, VK_SPACE):
            print("HOTKEY ERROR: Shift+Space is already used by another program")
            return
        print("HOTKEY: Shift+Space")
        msg = wintypes.MSG()
        while user32.GetMessageW(ctypes.byref(msg), None, 0, 0) > 0:
            if msg.message == WM_HOTKEY:
                try:
                    controller.toggle()
                except Exception as error:
                    print("HOTKEY ACTION ERROR:", error)

    threading.Thread(target=loop, daemon=True, name="hotkey").start()


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
