@echo off
REM Buduje WoWForeverWatcher.exe i paczke WoWForever_paczka.zip dla znajomych.
chcp 65001 >nul
cd /d "%~dp0"

python -m pip install --upgrade requests pyinstaller || goto :error
python -m PyInstaller --onefile --console --clean --name WoWForeverWatcher wow_forever_watcher.py || goto :error

if exist paczka rmdir /s /q paczka
mkdir paczka
copy dist\WoWForeverWatcher.exe paczka\ >nul
xcopy WoWForever paczka\WoWForever\ /e /i /q >nul
copy README.md paczka\INSTRUKCJA.md >nul
powershell -NoProfile -Command "Compress-Archive -Path 'paczka\*' -DestinationPath 'WoWForever_paczka.zip' -Force" || goto :error

echo.
echo Gotowe! Plik do wyslania znajomym: WoWForever_paczka.zip
pause
exit /b 0

:error
echo.
echo Cos poszlo nie tak - sprawdz komunikaty powyzej.
pause
exit /b 1
