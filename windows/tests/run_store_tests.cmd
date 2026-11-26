@echo off
setlocal
rem Run from a VS x64 Developer Command Prompt.
set "out=%TEMP%\h2readmd-build-%RANDOM%-%RANDOM%"
mkdir "%out%" || exit /b 1
pushd "%out%" || exit /b 1
cl /nologo /std:c++17 /utf-8 /EHsc /W4 /WX /DNOMINMAX /D_HAS_EXCEPTIONS=0 "%~dp0document_store_test.cpp" "%~dp0..\runner\document_store.cpp" /link bcrypt.lib ole32.lib || exit /b 1
document_store_test.exe
set "result=%errorlevel%"
popd
exit /b %result%
