@echo off
setlocal
cd /d "%~dp0"

echo.
echo  ==============================================
echo     Spotify Player - building the Windows .exe
echo  ==============================================
echo.

where py >nul 2>nul
if %errorlevel%==0 (set PY=py -3) else (set PY=python)

%PY% --version >nul 2>nul
if errorlevel 1 (
    echo [!] Python was not found.
    echo     Install it from https://www.python.org/downloads/
    echo     and tick "Add Python to PATH" during installation.
    pause
    exit /b 1
)

if not exist .venv (
    echo [1/4] Creating a virtual environment...
    %PY% -m venv .venv || goto :error
)

echo [2/4] Installing dependencies (1-2 minutes the first time)...
call .venv\Scripts\python -m pip install --upgrade pip -q || goto :error
call .venv\Scripts\python -m pip install -r requirements.txt -q || goto :error

echo [3/4] Drawing the icon...
call .venv\Scripts\python make_icon.py || goto :error

echo [4/4] Building SpotifyPlayer.exe...
call .venv\Scripts\pyinstaller --noconfirm --clean --windowed --onedir ^
    --name SpotifyPlayer ^
    --icon icon.ico ^
    --add-data "ui;ui" ^
    --paths ..\server ^
    --hidden-import pystray._win32 ^
    --collect-submodules webview ^
    main.py || goto :error

echo.
echo  Done!  The app is here:
echo     %cd%\dist\SpotifyPlayer\SpotifyPlayer.exe
echo.
echo  You can move the dist\SpotifyPlayer folder anywhere you like.
echo.
explorer dist\SpotifyPlayer
pause
exit /b 0

:error
echo.
echo [!] Something went wrong. Copy the error text above and open an issue on GitHub.
pause
exit /b 1
