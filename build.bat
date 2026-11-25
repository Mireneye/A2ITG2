@echo off
rem Builds A2ITG2 into build\a2itg2.apk.   build.bat install   also installs it on a phone plugged in with USB debugging.
rem
rem Needs (see README.md, "Setting up"):
rem   odin on PATH (dev-2026-11a or newer)
rem   ODIN_ANDROID_NDK   the Android NDK folder
rem   ODIN_ANDROID_SDK   the Android SDK folder (defaults to %LocalAppData%\Android\Sdk)
rem   a JDK, through JAVA_HOME or PATH
setlocal
cd /d "%~dp0"

set MIN_ANDROID=29
set ABI_DIR=app\lib\arm64-v8a

if "%ODIN_ANDROID_NDK%"=="" (
	echo ODIN_ANDROID_NDK is not set. See README.md, "Setting up".
	exit /b 1
)
if "%ODIN_ANDROID_SDK%"=="" set ODIN_ANDROID_SDK=%LocalAppData%\Android\Sdk

rem The bundler signs with Android's usual debug key. Make one if this PC has none yet.
if not exist "%USERPROFILE%\.android\debug.keystore" (
	echo Making the debug signing key in %USERPROFILE%\.android ...
	if not exist "%USERPROFILE%\.android" mkdir "%USERPROFILE%\.android"
	keytool -genkeypair -keystore "%USERPROFILE%\.android\debug.keystore" -storepass android -alias androiddebugkey -keypass android -keyalg RSA -keysize 2048 -validity 10000 -dname "CN=Android Debug,O=Android,C=US" || exit /b 1
)

if not exist %ABI_DIR% mkdir %ABI_DIR%
if not exist build mkdir build

echo Compiling ...
odin build src -target:linux_arm64 -subtarget:android -minimum-os-version:%MIN_ANDROID% -build-mode:shared -o:speed -vet -out:%ABI_DIR%\liba2itg2.so || exit /b 1

echo Bundling ...
odin bundle android app -minimum-os-version:%MIN_ANDROID% -out:build\a2itg2.apk || exit /b 1
echo Built build\a2itg2.apk

if /i "%~1"=="install" (
	"%ODIN_ANDROID_SDK%\platform-tools\adb.exe" install -r build\a2itg2.apk || exit /b 1
	"%ODIN_ANDROID_SDK%\platform-tools\adb.exe" shell am start -n org.mireneye.a2itg2/org.odin_lang.OdinActivity
)
