@echo off
:: Тонкая обёртка: сразу передаёт управление VBS (без консоли) и закрывается.
cd /d "%~dp0"
wscript //nologo "%~dp0scripts\launch.vbs"
exit
