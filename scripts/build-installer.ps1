#Requires -Version 5.1
<#
.SYNOPSIS
  Сборка portable ZIP и вспомогательных файлов установщика.
.DESCRIPTION
  Требует уже выполненный setup (runtime) и наличие APK.
  Создаёт:
    dist\andemu-portable.zip
    dist\install.bat
    dist\TSD-Emulator-Setup.iss  (шаблон для Inno Setup)
#>
[CmdletBinding()]
param(
    [switch]$SkipZip,
    [string]$ZipName = 'andemu-portable.zip'
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

function Write-Info([string]$Message)  { Write-Host "[INFO]  $Message" -ForegroundColor Cyan }
function Write-Ok([string]$Message)    { Write-Host "[OK]    $Message" -ForegroundColor Green }
function Write-Warn([string]$Message)  { Write-Host "[WARN]  $Message" -ForegroundColor Yellow }
function Write-Err([string]$Message)   { Write-Host "[ОШИБКА] $Message" -ForegroundColor Red }

function Get-ProjectRoot {
    return (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
}

function Read-Config {
    param([string]$Root)
    $configPath = Join-Path $Root 'config.json'
    if (-not (Test-Path -LiteralPath $configPath)) {
        throw "Не найден config.json"
    }
    return Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
}

function New-InstallBat {
    param(
        [string]$DistDir,
        [string]$ZipFileName
    )
    $batPath = Join-Path $DistDir 'install.bat'
    $content = @"
@echo off
chcp 65001 >nul
setlocal
cd /d "%~dp0"

set "ZIP=%~dp0$ZipFileName"
set "TARGET=%USERPROFILE%\andemu"

echo ========================================
echo  Установка TSD Emulator (portable)
echo ========================================
echo.

if not exist "%ZIP%" (
    echo [ОШИБКА] Не найден архив: %ZIP%
    pause
    exit /b 1
)

echo [INFO] Распаковка в %TARGET% ...
if exist "%TARGET%" (
    echo [WARN] Папка уже существует. Будет обновлена.
)

where tar >nul 2>&1
if not errorlevel 1 (
    if not exist "%TARGET%" mkdir "%TARGET%"
    tar -xf "%ZIP%" -C "%TARGET%"
) else (
    powershell -NoProfile -ExecutionPolicy Bypass -Command "Expand-Archive -LiteralPath '%ZIP%' -DestinationPath '%TARGET%' -Force"
)

if errorlevel 1 (
    echo [ОШИБКА] Не удалось распаковать архив
    pause
    exit /b 1
)

echo.
echo [OK] Установка завершена.
echo Запуск: %TARGET%\Start-TSD-Emulator.bat
echo.
start "" "%TARGET%"
pause
endlocal
"@
    Set-Content -LiteralPath $batPath -Value $content -Encoding ASCII
    Write-Ok "Создан: $batPath"
}

function New-InnoIss {
    param(
        [string]$DistDir,
        [string]$Root,
        [object]$Config
    )
    $issPath = Join-Path $DistDir 'TSD-Emulator-Setup.iss'
    $appName = if ($Config.appName) { [string]$Config.appName } else { 'TSD Process Emulator' }

    $content = @"
; Inno Setup script — соберите TSD-Emulator-Setup.exe
; Требуется: https://jrsoftware.org/isinfo.php
; Перед сборкой: выполните scripts\build-installer.ps1 (чтобы runtime и APK были на месте),
; затем откройте этот .iss в Inno Setup Compiler и нажмите Build.
;
; ВАЖНО: размер установщика будет большим (~3-6+ GB), т.к. включает Android SDK + system image.

#define MyAppName "$appName"
#define MyAppVersion "1.0.0"
#define MyAppPublisher "Internal"
#define MyAppExeName "Start-TSD-Emulator.bat"
#define SourceRoot "$($Root.Replace('\', '\\'))"

[Setup]
AppId={{A7C3E9F1-2B4D-4E8A-9C1F-8D6E5B4A3210}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
DefaultDirName={localappdata}\andemu
DefaultGroupName={#MyAppName}
DisableProgramGroupPage=yes
OutputDir={#SourceRoot}\dist
OutputBaseFilename=TSD-Emulator-Setup
Compression=lzma
SolidCompression=yes
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
PrivilegesRequired=lowest
WizardStyle=modern

[Languages]
Name: "russian"; MessagesFile: "compiler:Languages\Russian.isl"
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "Создать ярлык на рабочем столе"; GroupDescription: "Дополнительно:"

[Files]
; Весь portable-пакет (runtime уже должен быть скачан setup'ом)
Source: "{#SourceRoot}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs; Excludes: "dist\*,.git\*,*.zip"

[Icons]
Name: "{group}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "Запустить {#MyAppName}"; Flags: nowait postinstall skipifsilent shellexec
"@
    Set-Content -LiteralPath $issPath -Value $content -Encoding UTF8
    Write-Ok "Создан шаблон Inno Setup: $issPath"
    Write-Info "Откройте файл в Inno Setup Compiler и соберите TSD-Emulator-Setup.exe"
}

# -------------------- main --------------------
try {
    $root = Get-ProjectRoot
    $config = Read-Config -Root $root
    $distDir = Join-Path $root 'dist'
    if (-not (Test-Path -LiteralPath $distDir)) {
        New-Item -ItemType Directory -Path $distDir -Force | Out-Null
    }

    $emulatorExe = Join-Path $root 'runtime\android-sdk\emulator\emulator.exe'
    $apkPath = Join-Path $root ("app\" + $config.apkFileName)

    if (-not (Test-Path -LiteralPath $emulatorExe)) {
        throw "Runtime не установлен. Сначала запустите scripts\setup.ps1 (или Start-TSD-Emulator.bat)."
    }
    if (-not (Test-Path -LiteralPath $apkPath)) {
        throw "APK не найден: $apkPath. Положите APK в app\ и проверьте apkFileName в config.json."
    }

    Write-Ok "Runtime найден"
    Write-Ok "APK найден: $apkPath"

    New-InstallBat -DistDir $distDir -ZipFileName $ZipName
    New-InnoIss -DistDir $distDir -Root $root -Config $config

    if ($SkipZip) {
        Write-Warn "Пропуск создания ZIP (-SkipZip)"
        exit 0
    }

    $zipPath = Join-Path $distDir $ZipName
    if (Test-Path -LiteralPath $zipPath) {
        Remove-Item -LiteralPath $zipPath -Force
    }

    Write-Info "Создаю архив (это может занять несколько минут, размер ~3-6+ GB)..."
    Write-Info "Источник: $root"
    Write-Info "Назначение: $zipPath"

    # Исключаем dist из архива через временный staging или Compress-Archive с фильтрацией
    $excludeNames = @('dist', '.git', '.gitignore')
    $items = Get-ChildItem -LiteralPath $root -Force | Where-Object {
        $excludeNames -notcontains $_.Name
    }

    # Compress-Archive не умеет исключать подпапки гибко — используем .NET / tar если есть
    $tar = Get-Command tar -ErrorAction SilentlyContinue
    if ($tar) {
        Push-Location $root
        try {
            $relative = $items | ForEach-Object { $_.Name }
            & tar -a -cf $zipPath --exclude=dist --exclude=.git @relative
            if ($LASTEXITCODE -ne 0) {
                throw "tar завершился с кодом $LASTEXITCODE"
            }
        } finally {
            Pop-Location
        }
    } else {
        # Fallback: временная папка без dist
        $stage = Join-Path $env:TEMP ("tsd-pack-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $stage -Force | Out-Null
        try {
            foreach ($item in $items) {
                $dest = Join-Path $stage $item.Name
                Copy-Item -LiteralPath $item.FullName -Destination $dest -Recurse -Force
            }
            Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $zipPath -Force
        } finally {
            Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    if (-not (Test-Path -LiteralPath $zipPath)) {
        throw "ZIP не создан"
    }

    $sizeGb = [math]::Round((Get-Item $zipPath).Length / 1GB, 2)
    Write-Ok "Готово: $zipPath ($sizeGb GB)"
    Write-Host ''
    Write-Host 'Артефакты:' -ForegroundColor White
    Write-Host "  - $zipPath"
    Write-Host "  - $(Join-Path $distDir 'install.bat')"
    Write-Host "  - $(Join-Path $distDir 'TSD-Emulator-Setup.iss')"
    Write-Host ''
    exit 0
} catch {
    Write-Err $_.Exception.Message
    exit 1
}
