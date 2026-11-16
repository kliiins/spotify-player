"""Spotify Player — local server for the mini player (shared by macOS and Windows).

Endpoints used by the native apps:
    POST /native-play     {"prompt": "..."}          — find and play a track or artist
    GET  /native-state                               — what's playing now
    POST /native-control  {"action": "...", ...}     — play/pause/toggle/next/previous/seek
    POST /native-like     {"id": "...", "liked": b}  — add/remove from Liked Songs
    GET  /native-status                              — keys configured? logged in?
    GET  /health                                     — server is alive
"""

import json
import os
import secrets
import subprocess
import sys
import time
from urllib.parse import urlencode

import requests
from dotenv import load_dotenv
from flask import Flask, redirect, render_template_string, request, send_from_directory, session
from markupsafe import escape

# Консоль Windows по умолчанию не умеет печатать кириллицу и эмодзи из названий треков —
# без этого print() может уронить программу. В окне без консоли stdout = None.
for _stream in (sys.stdout, sys.stderr):
    try:
        if _stream is not None:
            _stream.reconfigure(encoding="utf-8", errors="replace")
    except (AttributeError, ValueError):
        pass

# ==========================================
# CONFIG
# ==========================================

IS_WINDOWS = os.name == "nt"

if IS_WINDOWS:
    APP_SUPPORT_DIR = os.path.join(
        os.getenv("APPDATA") or os.path.expanduser("~"), "SpotifyPlayer"
    )
else:
    # имя папки оставлено от первой версии (Spotify DJ), чтобы не терять вход
    APP_SUPPORT_DIR = os.path.expanduser("~/Library/Application Support/SpotifyDJ")

# папка с HTML-интерфейсом окна (нужна только Windows-версии, main.py задаёт её сам)
BASE_DIR = getattr(sys, "_MEIPASS", os.path.dirname(os.path.abspath(__file__)))
UI_DIR = os.path.join(BASE_DIR, "ui")
os.makedirs(APP_SUPPORT_DIR, exist_ok=True)

ENV_FILE = os.path.join(APP_SUPPORT_DIR, ".env")
TOKEN_FILE = os.path.join(APP_SUPPORT_DIR, "spotify_token.json")

load_dotenv(ENV_FILE, override=True)

CLIENT_ID = os.getenv("SPOTIFY_CLIENT_ID")
CLIENT_SECRET = os.getenv("SPOTIFY_CLIENT_SECRET")
REDIRECT_URI = os.getenv("SPOTIFY_REDIRECT_URI", "http://127.0.0.1:8888/callback")

SPOTIFY_AUTH = "https://accounts.spotify.com/authorize"
SPOTIFY_TOKEN = "https://accounts.spotify.com/api/token"
SPOTIFY_API = "https://api.spotify.com/v1"

SCOPES = " ".join([
    "user-read-private",
    "user-read-email",
    "playlist-read-private",
    "playlist-read-collaborative",
    "user-library-read",
    "user-library-modify",
    "user-read-recently-played",
    "user-read-playback-state",
    "user-modify-playback-state",
])

HTTP_TIMEOUT = 10          # секунд на любой запрос к Spotify
TOKEN_MARGIN = 60          # обновляем токен за минуту до истечения
DEVICE_WAIT_SECONDS = 15   # сколько ждать, пока только что запущенный Spotify появится как устройство

NOT_LOGGED_IN = "Log in to Spotify first: choose “Log in to Spotify…” in the app menu."

app = Flask(__name__)
app.secret_key = os.getenv("FLASK_SECRET_KEY") or secrets.token_hex(32)

print("========================================")
print("Spotify Player")
print("ENV FILE:", ENV_FILE, "| exists:", os.path.exists(ENV_FILE))
print("CLIENT ID LOADED:", bool(CLIENT_ID), "| SECRET LOADED:", bool(CLIENT_SECRET))
print("========================================")


class SpotifyError(Exception):
    """Ошибка, текст которой можно показать пользователю."""

    def __init__(self, message, status=400):
        super().__init__(message)
        self.message = message
        self.status = status


# ==========================================
# TOKEN STORAGE
# ==========================================

def load_token():
    try:
        with open(TOKEN_FILE, "r", encoding="utf-8") as file:
            return json.load(file)
    except FileNotFoundError:
        return None
    except (OSError, ValueError) as error:
        print("TOKEN FILE ERROR:", error)
        return None


def save_token(data, previous=None):
    previous = previous or {}
    expires_in = data.get("expires_in") or 3600
    token_data = {
        "access_token": data.get("access_token"),
        # Spotify не всегда присылает новый refresh_token — тогда оставляем старый
        "refresh_token": data.get("refresh_token") or previous.get("refresh_token"),
        "expires_in": expires_in,
        "expires_at": int(time.time()) + int(expires_in),
    }
    try:
        with open(TOKEN_FILE, "w", encoding="utf-8") as file:
            json.dump(token_data, file, indent=2)
        os.chmod(TOKEN_FILE, 0o600)
    except OSError as error:
        print("TOKEN SAVE ERROR:", error)
    return token_data


def refresh_access_token():
    token_data = load_token()
    if not token_data or not token_data.get("refresh_token"):
        return None
    if not CLIENT_ID or not CLIENT_SECRET:
        print("TOKEN REFRESH FAILED: нет SPOTIFY_CLIENT_ID / SPOTIFY_CLIENT_SECRET")
        return None

    try:
        response = requests.post(
            SPOTIFY_TOKEN,
            data={
                "grant_type": "refresh_token",
                "refresh_token": token_data["refresh_token"],
                "client_id": CLIENT_ID,
                "client_secret": CLIENT_SECRET,
            },
            timeout=HTTP_TIMEOUT,
        )
    except requests.RequestException as error:
        print("TOKEN REFRESH NETWORK ERROR:", error)
        return None

    if response.status_code != 200:
        print("TOKEN REFRESH FAILED:", response.status_code, response.text[:200])
        return None

    new_data = save_token(response.json(), previous=token_data)
    print("SPOTIFY TOKEN REFRESHED")
    return new_data.get("access_token")


def get_spotify_token():
    """Действующий access token: обновляет заранее, а не после ошибки 401."""
    token_data = load_token()
    if not token_data:
        return None

    access_token = token_data.get("access_token")
    expires_at = token_data.get("expires_at")
    if access_token and expires_at and time.time() < expires_at - TOKEN_MARGIN:
        return access_token

    # токен истёк или файл старого формата без expires_at
    return refresh_access_token() or access_token


# ==========================================
# SPOTIFY API
# ==========================================

def spotify_error_text(response):
    try:
        message = response.json().get("error", {}).get("message")
    except ValueError:
        message = None

    if response.status_code == 404:
        return "No active Spotify device. Open Spotify and try again."
    if response.status_code == 403:
        return "Spotify refused this action (Premium required or the device is restricted)."
    if response.status_code == 429:
        return "Too many requests to Spotify, wait a couple of seconds."
    return message or f"Spotify error ({response.status_code})"


def spotify_api(method, endpoint, **kwargs):
    """Запрос к Spotify API с токеном, таймаутом и одной повторной попыткой после 401."""
    token = get_spotify_token()
    if not token:
        raise SpotifyError(NOT_LOGGED_IN, 401)

    def send(access_token):
        headers = {**kwargs.pop("headers", {}), "Authorization": f"Bearer {access_token}"}
        try:
            return requests.request(
                method, SPOTIFY_API + endpoint,
                headers=headers, timeout=HTTP_TIMEOUT, **kwargs
            )
        except requests.RequestException as error:
            print("SPOTIFY NETWORK ERROR:", error)
            raise SpotifyError("Can’t reach Spotify. Check your internet connection.", 503)

    response = send(token)
    if response.status_code == 401:
        new_token = refresh_access_token()
        if not new_token:
            raise SpotifyError("Spotify session expired. " + NOT_LOGGED_IN, 401)
        response = send(new_token)
    return response


def spotify_ok(response):
    if response.status_code not in (200, 202, 204):
        raise SpotifyError(spotify_error_text(response), response.status_code)
    return response


# ==========================================
# DEVICES
# ==========================================

def list_devices():
    response = spotify_ok(spotify_api("GET", "/me/player/devices"))
    return response.json().get("devices", [])


def launch_spotify_app():
    try:
        if IS_WINDOWS:
            # протокол spotify: открывает и обычную, и Microsoft Store версию
            os.startfile("spotify:")  # noqa: S606
        else:
            subprocess.Popen(
                ["open", "-g", "-a", "Spotify"],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL
            )
        return True
    except OSError:
        return False


def pick_device():
    """Активное устройство; если Spotify закрыт — открывает его и ждёт."""
    devices = list_devices()

    if not devices and launch_spotify_app():
        print("SPOTIFY NOT RUNNING — LAUNCHING APP")
        deadline = time.time() + DEVICE_WAIT_SECONDS
        while not devices and time.time() < deadline:
            time.sleep(1)
            devices = list_devices()

    if not devices:
        raise SpotifyError("Spotify sees no devices. Open the Spotify app.", 404)

    usable = [d for d in devices if not d.get("is_restricted")]
    if not usable:
        raise SpotifyError("This Spotify device is restricted and doesn’t accept commands.", 403)

    return next((d for d in usable if d.get("is_active")), usable[0])


# ==========================================
# PLAYBACK
# ==========================================

def track_info(track):
    artists = track.get("artists") or []
    images = (track.get("album") or {}).get("images") or []
    return {
        "id": track.get("id", ""),
        "name": track.get("name", ""),
        "artist": ", ".join(a.get("name", "") for a in artists),
        "image_url": images[0]["url"] if images else "",
        "duration_ms": track.get("duration_ms", 0) or 0,
    }


# ==========================================
# SMART SEARCH
# ==========================================

CYRILLIC_TO_LATIN = {
    "а": "a", "б": "b", "в": "v", "г": "g", "д": "d", "е": "e", "ё": "e", "ж": "zh",
    "з": "z", "и": "i", "й": "y", "к": "k", "л": "l", "м": "m", "н": "n", "о": "o",
    "п": "p", "р": "r", "с": "s", "т": "t", "у": "u", "ф": "f", "х": "h", "ц": "ts",
    "ч": "ch", "ш": "sh", "щ": "sch", "ъ": "", "ы": "y", "ь": "", "э": "e", "ю": "yu",
    "я": "ya", "і": "i", "ї": "yi", "є": "e", "ґ": "g",
}


def normalize(text):
    """«Нирвана!» и «Nirvana» → одинаковый вид для сравнения."""
    import re
    text = (text or "").lower().strip()
    text = "".join(CYRILLIC_TO_LATIN.get(ch, ch) for ch in text)
    text = re.sub(r"[^a-z0-9]+", "", text)
    return text.replace("the", "", 1) if text.startswith("the") else text


def similarity(a, b):
    from difflib import SequenceMatcher
    a, b = normalize(a), normalize(b)
    if not a or not b:
        return 0.0
    return SequenceMatcher(None, a, b).ratio()


def search_best(query):
    """Решает, что хотел пользователь: исполнителя или конкретный трек.

    «Nirvana» / «Нирвана»       → играет исполнителя (его популярные треки)
    «Smells Like Teen Spirit»   → играет этот трек (самую популярную версию)
    «Nirvana Come As You Are»   → трек
    """
    response = spotify_ok(spotify_api(
        "GET", "/search",
        params={"q": query, "type": "artist,track", "limit": 8},
    ))
    data = response.json()
    artists = data.get("artists", {}).get("items", [])
    tracks = data.get("tracks", {}).get("items", [])

    if not artists and not tracks:
        raise SpotifyError(f"Nothing found for “{query}”.", 404)

    # Spotify больше не отдаёт popularity для таких приложений, поэтому опираемся
    # на порядок результатов: он уже учитывает популярность.

    # 1. Исполнитель, чьё имя совпадает с запросом (и его место в выдаче)
    artist_rank, best_artist = next(
        ((i, a) for i, a in enumerate(artists[:5])
         if similarity(query, a.get("name")) >= 0.88),
        (None, None),
    )
    first_artist = artists[0] if artists else None

    # 2. Треки, чьё название совпадает с запросом
    title_matches = [t for t in tracks if similarity(query, t.get("name")) >= 0.9]

    # Транслит не всегда точный («Скриптонит» → «Skryptonite»):
    # первому исполнителю выдачи прощаем совпадение послабее
    if not best_artist and not title_matches and first_artist \
            and similarity(query, first_artist.get("name")) >= 0.75:
        artist_rank, best_artist = 0, first_artist

    # Исполнитель побеждает, если он первый в выдаче или трека с таким названием нет.
    # «One Last Breath»: первым идёт Creed, а не группа One Last Breath → трек Creed.
    if best_artist and (artist_rank == 0 or not title_matches):
        return "artist", best_artist

    if title_matches:
        # если первый исполнитель выдачи поёт одну из совпавших песен — берём её
        if first_artist:
            for t in title_matches:
                if any(a.get("id") == first_artist.get("id") for a in t.get("artists", [])):
                    return "track", t
        return "track", title_matches[0]

    # 3. «исполнитель + песня»: трек, у которого исполнитель упомянут в запросе
    q = normalize(query)
    with_artist = [
        t for t in tracks
        if any(normalize(a.get("name")) and normalize(a.get("name")) in q
               for a in t.get("artists", []))
    ]
    if with_artist:
        return "track", with_artist[0]

    if tracks:
        # среди первых результатов берём самый популярный — Spotify иногда
        # ставит первым редкий трек
        top = tracks[:3]
        return "track", max(top, key=lambda t: t.get("popularity", 0) or 0)

    return "artist", best_artist


def play_query(query):
    kind, item = search_best(query)
    if kind == "artist":
        return play_artist(item)
    return play_track(item)


def play_artist(artist):
    device = pick_device()
    print(f"PLAY ARTIST: {artist.get('name')} on {device.get('name')}")

    spotify_ok(spotify_api(
        "PUT", "/me/player/play", params={"device_id": device["id"]},
        json={"context_uri": artist["uri"]},
    ))

    images = artist.get("images") or []
    return {
        "success": True,
        "kind": "artist",
        "name": artist.get("name", ""),
        "artist": "Artist · top tracks",
        "image_url": images[0]["url"] if images else "",
        "duration_ms": 0,
    }


def play_track(track):
    device = pick_device()

    print(f"PLAY: {track['name']} — {track['artists'][0]['name']} on {device.get('name')}")

    body = {"uris": [track["uri"]], "position_ms": 0}
    album_uri = (track.get("album") or {}).get("uri")
    if album_uri:
        # играем в контексте альбома, чтобы потом шли следующие треки.
        # offset по URI, а не по track_number — иначе многодисковые альбомы ломаются.
        body = {"context_uri": album_uri, "offset": {"uri": track["uri"]}, "position_ms": 0}

    response = spotify_api(
        "PUT", "/me/player/play", params={"device_id": device["id"]}, json=body
    )
    if response.status_code not in (200, 202, 204) and "context_uri" in body:
        # некоторые альбомы не дают offset — включаем просто трек
        response = spotify_api(
            "PUT", "/me/player/play", params={"device_id": device["id"]},
            json={"uris": [track["uri"]], "position_ms": 0},
        )
    spotify_ok(response)

    return {"success": True, "kind": "track", **track_info(track)}


def get_playback_state():
    response = spotify_api("GET", "/me/player")
    if response.status_code == 204:
        return {"success": True, "playing": False, "progress_ms": 0,
                "duration_ms": 0, "track": None}
    spotify_ok(response)

    data = response.json()
    item = data.get("item")
    info = track_info(item) if item else None
    if info and info.get("id"):
        info["liked"] = is_liked(info["id"])
    return {
        "success": True,
        "playing": data.get("is_playing", False),
        "progress_ms": data.get("progress_ms") or 0,
        "duration_ms": info["duration_ms"] if info else 0,
        "track": info,
    }


# ==========================================
# LIKES («Любимые треки»)
# ==========================================

_liked_cache = {}   # track_id -> bool, чтобы не спрашивать Spotify каждые 1.5 с

NEED_RELOGIN = ("Likes need a new permission: open http://127.0.0.1:8888/login "
                "in your browser and log in again.")


def _library_request(method, track_id):
    """Сначала классический /me/tracks, если Spotify его не принимает — новый /me/library."""
    response = spotify_api(method, "/me/tracks", params={"ids": track_id})
    if response.status_code in (404, 405, 410):
        response = spotify_api(
            method, "/me/library", params={"uris": f"spotify:track:{track_id}"}
        )
    return response


def is_liked(track_id):
    if track_id in _liked_cache:
        return _liked_cache[track_id]
    try:
        response = spotify_api("GET", "/me/tracks/contains", params={"ids": track_id})
        if response.status_code in (404, 405, 410):
            response = spotify_api(
                "GET", "/me/library/contains", params={"uris": f"spotify:track:{track_id}"}
            )
        if response.status_code != 200:
            return False
        liked = bool((response.json() or [False])[0])
    except (SpotifyError, ValueError, IndexError):
        return False
    _liked_cache[track_id] = liked
    return liked


def set_liked(track_id=None, liked=None):
    if not track_id:
        state = get_playback_state()
        track_id = (state.get("track") or {}).get("id")
    if not track_id:
        raise SpotifyError("Nothing is playing right now.", 404)

    if liked is None:
        liked = not is_liked(track_id)

    response = _library_request("PUT" if liked else "DELETE", track_id)
    if response.status_code == 403:
        raise SpotifyError(NEED_RELOGIN, 403)
    spotify_ok(response)

    _liked_cache[track_id] = liked
    return {"success": True, "id": track_id, "liked": liked}


def player_action(action, position_ms=None):
    if action == "toggle":
        action = "pause" if get_playback_state().get("playing") else "play"

    commands = {
        "pause": ("PUT", "/me/player/pause", None),
        "play": ("PUT", "/me/player/play", None),
        "next": ("POST", "/me/player/next", None),
        "previous": ("POST", "/me/player/previous", None),
    }

    if action == "seek":
        try:
            position = max(0, int(position_ms))
        except (TypeError, ValueError):
            raise SpotifyError("Invalid position")
        commands["seek"] = ("PUT", "/me/player/seek", {"position_ms": position})

    if action not in commands:
        raise SpotifyError("Unknown command")

    method, endpoint, params = commands[action]
    response = spotify_api(method, endpoint, params=params)

    # Нет активного устройства (Spotify закрыт или давно не играл) — открываем Spotify,
    # ждём, пока он появится, и переносим воспроизведение на него.
    if response.status_code == 404 and action in ("play", "next", "previous"):
        device = pick_device()   # сам запускает Spotify, если он закрыт
        print(f"NO ACTIVE DEVICE — RESUMING ON {device.get('name')}")
        spotify_ok(spotify_api(
            "PUT", "/me/player",
            json={"device_ids": [device["id"]], "play": True},
        ))
        if action in ("next", "previous"):
            time.sleep(0.5)
            response = spotify_api(method, endpoint, params={"device_id": device["id"]})
        else:
            return {"success": True, "action": action, "launched": True}

    spotify_ok(response)
    return {"success": True, "action": action}


def json_result(func, *args):
    try:
        return func(*args)
    except SpotifyError as error:
        return {"success": False, "error": error.message}, error.status


# ==========================================
# NATIVE API (для Swift-приложения)
# ==========================================

@app.get("/health")
def health():
    return {"success": True, "logged_in": bool(load_token())}


@app.post("/native-play")
def native_play():
    data = request.get_json(silent=True) or {}
    query = (data.get("prompt") or "").strip()
    if not query:
        return {"success": False, "error": "Empty query."}, 400
    return json_result(play_query, query)


@app.get("/native-state")
def native_state():
    return json_result(get_playback_state)


@app.post("/native-like")
def native_like():
    """{"id": "...", "liked": true/false} — оба поля необязательны (по умолчанию toggle текущего)."""
    data = request.get_json(silent=True) or {}
    return json_result(set_liked, data.get("id"), data.get("liked"))


@app.post("/native-control")
def native_control():
    data = request.get_json(silent=True) or {}
    return json_result(player_action, data.get("action", ""), data.get("position_ms"))


# ==========================================
# WEB (вход и простой веб-интерфейс)
# ==========================================

PAGE = """
<!DOCTYPE html>
<html>
<head>
    <meta charset="UTF-8">
    <title>Spotify Player</title>
    <style>
        body { margin: 0; min-height: 100vh; background: #0b0b0b; color: white;
               font-family: -apple-system, BlinkMacSystemFont, sans-serif;
               display: flex; align-items: center; justify-content: center; text-align: center; }
        input { width: 420px; max-width: 70vw; padding: 16px 18px; border-radius: 14px;
                border: 1px solid #333; background: #181818; color: white; font-size: 17px; outline: none; }
        button, a.btn { margin-left: 8px; padding: 16px 20px; border: 0; border-radius: 14px;
                background: white; color: black; font-weight: 600; cursor: pointer;
                text-decoration: none; display: inline-block; font-size: 15px; }
        .muted { color: #888; font-size: 13px; }
        .error { color: #ff7a7a; }
        a { color: #aaa; }
    </style>
</head>
<body><div>{{ body|safe }}</div></body>
</html>
"""


def page(body):
    return render_template_string(PAGE, body=body)


@app.get("/")
def index():
    if not load_token():
        return page("""
            <div style="font-size:55px">🎧</div>
            <h1>Spotify Player</h1>
            <p class="muted">Log in once — after that the app works on its own.</p>
            <a class="btn" href="/login">Log in with Spotify</a>
        """)

    try:
        profile = spotify_ok(spotify_api("GET", "/me")).json()
    except SpotifyError as error:
        return page(f"""
            <h1>Spotify Player</h1>
            <p class="error">{escape(error.message)}</p>
            <a class="btn" href="/login">Log in again</a>
        """)

    name = escape(profile.get("display_name") or "friend")
    return page(f"""
        <h1>Spotify Player</h1>
        <p>Hi, {name} 👋</p>
        <form action="/ai-play" method="post">
            <input name="prompt" placeholder="What should I play?" autofocus required>
            <button>Play</button>
        </form>
        <p class="muted">In the app: ⇧ Space · <a href="/logout">log out</a></p>
    """)


@app.get("/login")
def login():
    if not CLIENT_ID or not CLIENT_SECRET:
        return redirect("/setup")

    state = secrets.token_urlsafe(16)
    session["oauth_state"] = state
    query = urlencode({
        "client_id": CLIENT_ID,
        "response_type": "code",
        "redirect_uri": REDIRECT_URI,
        "scope": SCOPES,
        "state": state,
    })
    return redirect(f"{SPOTIFY_AUTH}?{query}")


@app.get("/callback")
def callback():
    code = request.args.get("code")
    state = request.args.get("state")
    expected_state = session.pop("oauth_state", None)

    if not code:
        return page(f"<h1>Login cancelled</h1><p>{escape(request.args.get('error', ''))}</p>"
                    "<a href='/'>Back</a>"), 400
    if expected_state and state != expected_state:
        return page("<h1>Login error</h1><p>Invalid state, please try again.</p>"
                    "<a href='/login'>Log in</a>"), 400

    try:
        response = requests.post(
            SPOTIFY_TOKEN,
            data={
                "grant_type": "authorization_code",
                "code": code,
                "redirect_uri": REDIRECT_URI,
                "client_id": CLIENT_ID,
                "client_secret": CLIENT_SECRET,
            },
            timeout=HTTP_TIMEOUT,
        )
        data = response.json()
    except (requests.RequestException, ValueError) as error:
        return page(f"<h1>Login error</h1><p>{escape(str(error))}</p>"), 502

    if "access_token" not in data:
        return page(f"<h1>Spotify error</h1><p>{escape(str(data))}</p>"), 400

    save_token(data)
    print("SPOTIFY LOGIN SUCCESS")
    return redirect("/")


@app.post("/ai-play")
def ai_play():
    query = request.form.get("prompt", "").strip()
    if not query:
        return redirect("/")
    try:
        result = play_query(query)
    except SpotifyError as error:
        return page(f"""
            <h1>Couldn’t play that</h1>
            <p class="error">{escape(error.message)}</p>
            <a href="/">Back</a>
        """), error.status
    return page(f"""
        <h1>▶ {escape(result['name'])}</h1>
        <p class="muted">{escape(result['artist'])}</p>
        <a href="/">More</a>
    """)


@app.get("/logout")
def logout():
    session.clear()
    try:
        os.remove(TOKEN_FILE)
        print("SPOTIFY TOKEN DELETED")
    except FileNotFoundError:
        pass
    except OSError as error:
        print("TOKEN DELETE ERROR:", error)
    return redirect("/")


def reload_config():
    """Перечитать .env (после того как пользователь ввёл ключи на странице настройки)."""
    global CLIENT_ID, CLIENT_SECRET, REDIRECT_URI
    load_dotenv(ENV_FILE, override=True)
    CLIENT_ID = os.getenv("SPOTIFY_CLIENT_ID")
    CLIENT_SECRET = os.getenv("SPOTIFY_CLIENT_SECRET")
    REDIRECT_URI = os.getenv("SPOTIFY_REDIRECT_URI", "http://127.0.0.1:8888/callback")


def is_configured():
    return bool(CLIENT_ID and CLIENT_SECRET)


# ==========================================
# UI (окно плеера) и первая настройка
# ==========================================

@app.get("/ui")
def ui_index():
    return send_from_directory(UI_DIR, "index.html")


@app.get("/ui/<path:name>")
def ui_files(name):
    return send_from_directory(UI_DIR, name)


@app.get("/native-status")
def native_status():
    return {"success": True, "configured": is_configured(), "logged_in": bool(load_token())}


@app.route("/setup", methods=["GET", "POST"])
def setup():
    error = ""
    if request.method == "POST":
        client_id = request.form.get("client_id", "").strip()
        client_secret = request.form.get("client_secret", "").strip()
        if len(client_id) < 16 or len(client_secret) < 16:
            error = "Looks like the keys weren’t pasted completely."
        else:
            with open(ENV_FILE, "w", encoding="utf-8") as file:
                file.write(f"SPOTIFY_CLIENT_ID={client_id}\n")
                file.write(f"SPOTIFY_CLIENT_SECRET={client_secret}\n")
                file.write("SPOTIFY_REDIRECT_URI=http://127.0.0.1:8888/callback\n")
                file.write(f"FLASK_SECRET_KEY={secrets.token_hex(32)}\n")
            reload_config()
            return redirect("/login")

    return page(f"""
        <div style="font-size:48px">🎧</div>
        <h1>Spotify Player setup</h1>
        <p class="muted" style="max-width:460px;margin:0 auto 18px">
            Open <a href="https://developer.spotify.com/dashboard" target="_blank">developer.spotify.com/dashboard</a>,
            pick your app (or create one with the Redirect URI
            <code>http://127.0.0.1:8888/callback</code>) and paste its keys here.
        </p>
        <form method="post" style="display:flex;flex-direction:column;gap:10px;align-items:center">
            <input name="client_id" placeholder="Client ID" required autocomplete="off">
            <input name="client_secret" placeholder="Client Secret" required autocomplete="off" type="password">
            <button style="margin:6px 0 0">Save and log in</button>
        </form>
        <p class="error">{escape(error)}</p>
        <p class="muted">Keys are stored only on this computer: <code>{escape(ENV_FILE)}</code></p>
    """)


def run_server():
    from werkzeug.serving import make_server
    print("http://127.0.0.1:8888")
    server = make_server("127.0.0.1", 8888, app, threaded=True)
    server.serve_forever()


def watch_parent_process():
    """macOS: если приложение, запустившее сервер, умерло (например, Stop в Xcode),
    сервер тоже завершается — иначе он висит и держит порт 8888."""
    import threading

    parent_pid = int(os.getenv("SPOTIFY_DJ_PARENT_PID") or 0)
    if not parent_pid:
        return

    def loop():
        while True:
            time.sleep(2)
            # когда родитель умирает, процесс «усыновляет» launchd и ppid меняется
            if os.getppid() != parent_pid:
                print("PARENT APP EXITED — SHUTTING DOWN SERVER")
                os._exit(0)

    threading.Thread(target=loop, daemon=True).start()


if __name__ == "__main__":
    watch_parent_process()
    run_server()
