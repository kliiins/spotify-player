@echo off
chcp 65001 >nul
setlocal
cd /d "%~dp0"

echo.
echo  ==============================================
echo     Spotify Player - сборка .exe для Windows
echo  ==============================================
echo.

where py >nul 2>nul
if %errorlevel%==0 (set PY=py -3) else (set PY=python)

%PY% --version >nul 2>nul
if errorlevel 1 (
    echo [!] Python не найден.
    echo     Установи его с https://www.python.org/downloads/
    echo     и при установке поставь галочку "Add Python to PATH".
    pause
    exit /b 1
)

if not exist .venv (
    echo [1/4] Создаю виртуальное окружение...
    %PY% -m venv .venv || goto :error
)

echo [2/4] Ставлю зависимости (первый раз 1-2 минуты)...
call .venv\Scripts\python -m pip install --upgrade pip -q || goto :error
call .venv\Scripts\python -m pip install -r requirements.txt -q || goto :error

echo [3/4] Рисую значок...
call .venv\Scripts\python make_icon.py || goto :error

echo [4/4] Собираю SpotifyPlayer.exe...
call .venv\Scripts\pyinstaller --noconfirm --clean --windowed --onedir ^
    --name SpotifyPlayer ^
    --icon icon.ico ^
    --add-data "ui;ui" ^
    --paths ..\server ^
    --hidden-import pystray._win32 ^
    --collect-submodules webview ^
    main.py || goto :error

echo.
echo  Готово!  Программа лежит тут:
echo     %cd%\dist\SpotifyPlayer\SpotifyPlayer.exe
echo.
echo  Папку dist\SpotifyPlayer можно перенести куда угодно.
echo.
explorer dist\SpotifyPlayer
pause
exit /b 0

:error
echo.
echo [!] Что-то пошло не так. Скопируй текст ошибки выше и пришли его Claude.
pause
exit /b 1
