@echo off
chcp 65001 >nul
cd /d "%~dp0"
if not exist .venv (
    py -3 -m venv .venv
    call .venv\Scripts\python -m pip install -r requirements.txt
)
call .venv\Scripts\python main.py
