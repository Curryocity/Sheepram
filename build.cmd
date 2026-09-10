@echo off
setlocal
cd /d "%~dp0"
call C:\dev\tools\msvc\setup_x64.bat
if errorlevel 1 exit /b 1
if not exist build mkdir build
cl /nologo /c /EHsc /Ithird_party/nfd/src/include /Fobuild/nfd_win.obj third_party/nfd/src/nfd_win.cpp
if errorlevel 1 exit /b 1
rc /nologo /fo build/app_icon.res resources/windows/app_icon.rc
if errorlevel 1 exit /b 1
odin build src -o:speed -out:build/Sheepram.exe
if errorlevel 1 exit /b 1
xcopy asset build\asset\ /E /I /Y >nul
if errorlevel 1 exit /b 1
echo Built build\Sheepram.exe
