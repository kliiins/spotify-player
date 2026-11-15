#!/bin/sh
# Builds the server for the macOS app into server/dist/SpotifyDJServer.
# Xcode runs this script automatically if the server has not been built yet.
set -e
cd "$(dirname "$0")"
PY="${PYTHON:-python3}"
if [ ! -d .venv ]; then
  "$PY" -m venv .venv
fi
.venv/bin/pip install -q -r requirements.txt
.venv/bin/pyinstaller --noconfirm --log-level WARN SpotifyDJServer.spec
echo "✅ server/dist/SpotifyDJServer is ready"
