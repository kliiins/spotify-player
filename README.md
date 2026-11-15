# 🎧 Spotify Player

Маленький быстрый плеер для **macOS** и **Windows**: жмёшь **Shift+Пробел**, пишешь исполнителя или песню, жмёшь Enter, и Spotify начинает играть.

*A tiny launcher-style Spotify controller for macOS and Windows: press Shift+Space, type an artist or a song, hit Enter.*

## Возможности

- ⚡ **Shift+Пробел** из любого приложения открывает окно поиска.
- 🧠 **Умный поиск.** «Nirvana» или «Нирвана» включит исполнителя, «smells like teen spirit» включит песню, «nirvana come as you are» включит нужный трек. Русские имена тоже понимает: «Скриптонит» найдёт Skryptonite.
- 🎵 **«Сейчас играет»**: обложка, плавный прогресс, перемотка кликом.
- ⏮ ⏯ ⏭ и ❤️ **лайк** прямо из окна, плюс горячие клавиши.
- 🌈 **Живой фон** из размытой обложки текущего трека и плавные анимации.
- 🚀 Если Spotify закрыт, плеер откроет его сам.

| | macOS | Windows |
|---|---|---|
| Открыть / спрятать | ⇧ Space | Shift+Space |
| Пауза | ⌘P | Ctrl+P |
| Пред. / след. трек | ⌘← / ⌘→ | Ctrl+← / Ctrl+→ |
| Лайк | ⌘L | Ctrl+L |
| Закрыть | Esc | Esc |

> Для управления воспроизведением через Spotify API нужен **Spotify Premium**.

## Установка

Скачай готовую сборку со страницы **[Releases](../../releases/latest)**:

- **macOS** (Apple Silicon, macOS 26+): `SpotifyPlayer-macOS.zip`. Распакуй и перетащи в «Программы».
  При первом запуске macOS скажет, что разработчик не проверен: кликни по приложению **правой кнопкой → «Открыть» → «Открыть»**.
  Или в Терминале: `xattr -cr "/Applications/spotifydj.app"`.
- **Windows 10/11**: `SpotifyPlayer-Windows.zip`. Распакуй и запусти `SpotifyPlayer.exe`.
  Если появится «Windows защитила ваш компьютер», нажми **«Подробнее» → «Выполнить в любом случае»**.

### Первый запуск: ключи Spotify

Плеер работает через твоё собственное приложение Spotify для разработчиков (это бесплатно, займёт пару минут):

1. Открой https://developer.spotify.com/dashboard и нажми **Create app**.
2. Название любое. В **Redirect URI** впиши `http://127.0.0.1:8888/callback`, отметь **Web API**.
3. Запусти плеер: в браузере откроется страница настройки. Вставь туда **Client ID** и **Client Secret** и войди в Spotify.

Ключи и вход хранятся только на твоём компьютере и никуда не отправляются, кроме самого Spotify.

## Как это устроено

```
┌──────────────┐   HTTP 127.0.0.1:8888   ┌──────────────┐   Web API   ┌─────────┐
│ окно плеера  │ ──────────────────────▶ │  server.py   │ ──────────▶ │ Spotify │
│ Swift / HTML │ ◀────────────────────── │ (Flask)      │ ◀────────── │         │
└──────────────┘                         └──────────────┘             └─────────┘
```

- `server/`: общий локальный сервер на Python (поиск, воспроизведение, лайки, вход через OAuth).
- `macos/`: приложение на SwiftUI для меню-бара; сервер собирается PyInstaller-ом и кладётся внутрь `.app`.
- `windows/`: окно на pywebview (HTML/CSS), значок в трее, глобальная горячая клавиша.

## Сборка из исходников

**macOS** (Xcode 27+, Python 3.11+):
```bash
open macos/spotifydj.xcodeproj
```
Нажми Run. При первой сборке Xcode сам соберёт сервер (`server/build_mac.sh`).

**Windows** (Python 3.11+): запусти `windows\build.bat`. Готовый `.exe` появится в `windows\dist\SpotifyPlayer`.
Подробности в [windows/README.md](windows/README.md).

Windows-сборку для релизов делает GitHub Actions ([windows-release.yml](.github/workflows/windows-release.yml)): при публикации релиза `SpotifyPlayer-Windows.zip` прикрепляется к нему автоматически.

## Автор

Сделал [@tenssage](https://t.me/tenssage). Проект не связан со Spotify AB, «Spotify» является товарным знаком Spotify AB.

Лицензия: [MIT](LICENSE).
