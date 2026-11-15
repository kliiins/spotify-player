#!/bin/sh
# Собирает сервер для macOS-приложения в server/dist/SpotifyDJServer.
# Xcode вызывает этот скрипт сам, если готового сервера ещё нет.
set -e
cd "$(dirname "$0")"
PY="${PYTHON:-python3}"
if [ ! -d .venv ]; then
  "$PY" -m venv .venv
fi
.venv/bin/pip install -q -r requirements.txt
.venv/bin/pyinstaller --noconfirm --log-level WARN SpotifyDJServer.spec
echo "✅ server/dist/SpotifyDJServer готов"
