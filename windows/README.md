# Spotify Player for Windows

A mini player: press **Shift+Space**, type an artist or a song, hit Enter, and Spotify plays it.
Same app as on macOS: same design, smart search, now playing, ⏮ ⏯ ⏭, seeking and ❤️ likes.

> The easiest way is to download the ready-made `SpotifyPlayer-Windows.zip` from the repository's **Releases** page.
> The steps below are for building it yourself.

## Build (once)

1. Install **Python 3.11 or newer**: https://www.python.org/downloads/
   During installation **make sure to tick "Add Python to PATH"**.
2. Download the repository (Code → Download ZIP) and unzip it, for example to `C:\Apps\spotify-player`.
3. Open the `windows` folder and double-click **`build.bat`**. The first build takes 2–4 minutes.
4. When you see "Done!", the `dist\SpotifyPlayer` folder opens. It contains **`SpotifyPlayer.exe`**.
   You can move this folder anywhere, for example to `C:\Program Files`.

> If Windows says "Windows protected your PC", click **More info → Run anyway**.
> This happens with any app that doesn't have a paid code-signing certificate.

## First launch

1. Run `SpotifyPlayer.exe`. A green waveform icon appears in the tray next to the clock.
2. A **setup** page opens in your browser. Paste your Spotify keys there:
   - open https://developer.spotify.com/dashboard;
   - pick your app (or create a new one);
   - make sure **Redirect URIs** contains `http://127.0.0.1:8888/callback`;
   - copy the **Client ID** and **Client Secret** to the setup page and click "Save and log in".
3. Log in to Spotify and allow access. That's it.

Keys and login are stored only on this computer, in `%APPDATA%\SpotifyPlayer`.

## Controls

| Action | How |
|---|---|
| Show / hide | **Shift+Space** or click the tray icon |
| Play | type and press **Enter** |
| Play / pause | **Ctrl+P** |
| Previous / next | **Ctrl+←** / **Ctrl+→** |
| Like | **Ctrl+L** or ♥ |
| Seek | click the progress bar |
| Close the window | **Esc** |

The tray icon menu has "Log in to Spotify…", **"Start with Windows"** (checkbox) and "Quit".

## Troubleshooting

- **"Spotify sees no devices"**: open the Spotify app on this computer. Usually the player opens it for you.
- **"Premium required"**: controlling playback through the Spotify API only works with Premium.
- **Shift+Space does nothing**: make sure the app is running (tray icon). Some full-screen games capture the keyboard.
- **Switch account or keys**: delete the `%APPDATA%\SpotifyPlayer` folder and start the app again.
- **Build error**: copy the text from the `build.bat` window and open an issue.

## Files

- `main.py`: window, tray icon, Shift+Space, autostart
- `../server/server.py`: Spotify logic (search, playback, likes), shared with macOS
- `ui/index.html`: the window UI
- `build.bat`: builds the `.exe`; `run_dev.bat`: runs from source (for debugging)
