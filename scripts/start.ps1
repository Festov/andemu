#Requires -Version 5.1
<#
.SYNOPSIS
  Запуск AVD, установка APK и старт ТСД-приложения.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

. (Join-Path $PSScriptRoot 'common.ps1')

function Get-ProjectRoot {
    return (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
}

function Read-Config {
    param([string]$Root)
    $configPath = Join-Path $Root 'config.json'
    if (-not (Test-Path -LiteralPath $configPath)) {
        throw "Не найден config.json: $configPath"
    }
    return Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
}

function Set-SdkEnvironment {
    param(
        [string]$SdkRoot,
        [string]$AvdHome
    )
    $env:ANDROID_SDK_ROOT = $SdkRoot
    $env:ANDROID_HOME = $SdkRoot
    $env:ANDROID_AVD_HOME = $AvdHome

    $pathsToPrepend = @(
        (Join-Path $SdkRoot 'cmdline-tools\latest\bin'),
        (Join-Path $SdkRoot 'platform-tools'),
        (Join-Path $SdkRoot 'emulator'),
        (Join-Path $SdkRoot 'build-tools')
    )
    foreach ($p in $pathsToPrepend) {
        if ((Test-Path -LiteralPath $p) -and ($env:PATH -notlike "*$p*")) {
            $env:PATH = "$p;$env:PATH"
        }
    }

    # Добавить все версии build-tools в PATH (для aapt)
    $btRoot = Join-Path $SdkRoot 'build-tools'
    if (Test-Path -LiteralPath $btRoot) {
        Get-ChildItem -LiteralPath $btRoot -Directory | Sort-Object Name -Descending | ForEach-Object {
            if ($env:PATH -notlike ("*" + $_.FullName + "*")) {
                $env:PATH = "$($_.FullName);$env:PATH"
            }
        }
    }
}

function Invoke-AdbText {
    param(
        [string]$Adb,
        [string[]]$AdbArgs
    )
    # adb пишет служебные сообщения в stderr (daemon starting) — не считаем это ошибкой
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = & $Adb @AdbArgs 2>&1
        $code = $LASTEXITCODE
        $text = ($output | ForEach-Object { "$_" }) -join [Environment]::NewLine
        return [pscustomobject]@{ ExitCode = $code; Text = $text }
    } finally {
        $ErrorActionPreference = $prev
    }
}

function Get-EmulatorLogTail {
    param(
        [string]$Root,
        [int]$Lines = 40
    )
    $err = Join-Path $Root 'logs\emulator-stderr.log'
    $out = Join-Path $Root 'logs\emulator-stdout.log'
    $chunks = @()
    foreach ($f in @($err, $out)) {
        if (Test-Path -LiteralPath $f) {
            try {
                $tail = Get-Content -LiteralPath $f -Tail $Lines -ErrorAction SilentlyContinue
                if ($tail) {
                    $chunks += ("--- $(Split-Path $f -Leaf) ---")
                    $chunks += ($tail -join [Environment]::NewLine)
                }
            } catch {}
        }
    }
    return ($chunks -join [Environment]::NewLine)
}

function Wait-ForBootCompleted {
    param(
        [string]$Adb,
        [int]$TimeoutSec = 180,
        [int]$EmulatorPid = 0
    )

    $root = Get-AndemuRoot
    Write-Info "Ожидаю появления эмулятора в adb (до $TimeoutSec сек)..."
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $deviceSeen = $false

    while ($sw.Elapsed.TotalSeconds -lt $TimeoutSec) {
        if ($EmulatorPid -gt 0) {
            $alive = Get-Process -Id $EmulatorPid -ErrorAction SilentlyContinue
            if (-not $alive) {
                $tail = Get-EmulatorLogTail -Root $root
                if ($tail) { Write-DebugLog $tail }
                throw @"
Процесс эмулятора завершился до подключения adb (PID $EmulatorPid).
Смотрите logs\emulator-stderr.log — там обычно точная причина
(драйвер GPU/hypervisor, антивирус, нехватка RAM и т.п.).
"@
            }
        }

        $dev = Invoke-AdbText -Adb $Adb -AdbArgs @('devices')
        $text = if ($dev.Text) { $dev.Text } else { '' }
        if ($text -match "emulator-\d+\s+device") {
            $deviceSeen = $true
            Write-Ok ("adb device online ({0} сек)" -f [int]$sw.Elapsed.TotalSeconds)
            break
        }
        if ($text -match "emulator-\d+\s+offline") {
            Write-Info "Эмулятор в adb пока offline..."
        }

        Start-Sleep -Seconds 2
    }

    if (-not $deviceSeen) {
        $tail = Get-EmulatorLogTail -Root $root
        if ($tail) { Write-DebugLog $tail }
        throw @"
Таймаут: эмулятор не появился в adb за $TimeoutSec сек.
Если в Диспетчере задач виртуализация уже включена — откройте logs\emulator-stderr.log
и пришлите хвост файла (или проверьте, не блокирует ли антивирус qemu-system*.exe).
Также полезно вручную: runtime\android-sdk\emulator\emulator.exe -accel-check
"@
    }

    Write-Info "Ожидаю sys.boot_completed (до $TimeoutSec сек)..."
    $sw.Restart()
    while ($sw.Elapsed.TotalSeconds -lt $TimeoutSec) {
        if ($EmulatorPid -gt 0) {
            $alive = Get-Process -Id $EmulatorPid -ErrorAction SilentlyContinue
            if (-not $alive) {
                throw "Процесс эмулятора завершился во время загрузки Android."
            }
        }

        $boot = (Invoke-AdbText -Adb $Adb -AdbArgs @('shell', 'getprop', 'sys.boot_completed')).Text
        if ($boot) { $boot = $boot.Trim() }
        if ($boot -eq '1') {
            Start-Sleep -Seconds 3
            Write-Ok "Эмулятор загружен ($([int]$sw.Elapsed.TotalSeconds) сек)"
            return
        }
        Start-Sleep -Seconds 2
    }

    $tail = Get-EmulatorLogTail -Root $root
    if ($tail) { Write-DebugLog $tail }
    throw "Таймаут ожидания загрузки эмулятора ($TimeoutSec сек). Проверьте виртуализацию (WHPX/Hyper-V) и logs\emulator-stderr.log"
}

function Find-Aapt {
    param([string]$SdkRoot)
    $candidates = @()
    $bt = Join-Path $SdkRoot 'build-tools'
    if (Test-Path -LiteralPath $bt) {
        $candidates += Get-ChildItem -LiteralPath $bt -Recurse -Filter 'aapt.exe' -ErrorAction SilentlyContinue |
            Sort-Object FullName -Descending
    }
    $cmdlineAapt = Join-Path $SdkRoot 'cmdline-tools\latest\bin\aapt.exe'
    if (Test-Path -LiteralPath $cmdlineAapt) { $candidates += Get-Item $cmdlineAapt }
    if ($candidates.Count -gt 0) { return $candidates[0].FullName }
    return $null
}

function Get-PackageFromApk {
    param(
        [string]$SdkRoot,
        [string]$ApkPath
    )
    $aapt = Find-Aapt -SdkRoot $SdkRoot
    if (-not $aapt) {
        Write-Warn "aapt не найден — package name из APK определить нельзя. Установите build-tools или укажите apkPackage в config.json"
        return $null
    }
    Write-Info "Определяю package name через aapt..."
    $dump = & $aapt dump badging $ApkPath 2>$null | Out-String
    if ($dump -match "package:\s+name='([^']+)'") {
        return $Matches[1]
    }
    return $null
}

function Get-PackageFromPmList {
    param(
        [string]$Adb,
        [string]$Hint
    )
    $list = (Invoke-AdbText -Adb $Adb -AdbArgs @('shell', 'pm', 'list', 'packages')).Text
    if (-not $list) { return $null }

    $packages = @()
    foreach ($line in ($list -split "`r?`n")) {
        if ($line -match '^package:(.+)$') {
            $packages += $Matches[1].Trim()
        }
    }

    if ($Hint -and ($packages -contains $Hint)) {
        return $Hint
    }

    # Эвристика: исключаем системные префиксы
    $skip = @(
        'android.', 'com.android.', 'com.google.', 'com.qualcomm.',
        'com.samsung.', 'org.chromium.', 'com.example.android.'
    )
    $userPkgs = $packages | Where-Object {
        $p = $_
        -not ($skip | Where-Object { $p.StartsWith($_) })
    }

    if ($userPkgs.Count -eq 1) { return $userPkgs[0] }
    if ($Hint) {
        $partial = $userPkgs | Where-Object { $_ -like "*$Hint*" }
        if ($partial.Count -eq 1) { return $partial[0] }
    }
    return $null
}

function Resolve-ApkPackage {
    param(
        [object]$Config,
        [string]$SdkRoot,
        [string]$ApkPath,
        [string]$Adb,
        [bool]$AfterInstall
    )

    $pkg = [string]$Config.apkPackage
    if ($pkg -and $pkg.Trim().Length -gt 0) {
        return $pkg.Trim()
    }

    Write-Warn "apkPackage пустой — пробую определить автоматически"

    $fromApk = Get-PackageFromApk -SdkRoot $SdkRoot -ApkPath $ApkPath
    if ($fromApk) {
        Write-Ok "Package из APK: $fromApk"
        return $fromApk
    }

    if ($AfterInstall) {
        $fromPm = Get-PackageFromPmList -Adb $Adb -Hint $null
        if ($fromPm) {
            Write-Ok "Package из pm list: $fromPm"
            return $fromPm
        }
    }

    return $null
}

function Stop-RunningEmulator {
    param([string]$Adb)
    Write-Warn "Останавливаю текущий эмулятор (нужен cold boot под новый экран)..."
    $null = Invoke-AdbText -Adb $Adb -AdbArgs @('emu', 'kill')
    Start-Sleep -Seconds 2
    # на случай если emu kill не сработал
    Get-Process -Name 'qemu-system*', 'emulator' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 1
}

function Start-EmulatorProcess {
    param(
        [string]$EmulatorExe,
        [object]$Config,
        [bool]$ForceRestart = $false
    )

    $adb = Join-Path (Split-Path (Split-Path $EmulatorExe)) 'platform-tools\adb.exe'
    if (Test-Path -LiteralPath $adb) {
        $dev = Invoke-AdbText -Adb $adb -AdbArgs @('devices')
        Write-DebugLog ("adb devices: " + ($dev.Text.Trim() -replace "`r?`n", ' | '))
        $running = ($dev.Text -match "emulator-\d+\s+device")
        if ($running -and $ForceRestart) {
            Stop-RunningEmulator -Adb $adb
        } elseif ($running) {
            Write-Ok "Эмулятор уже запущен — переиспользуем сессию"
            return $null
        }
    }

    $argList = @('-avd', $Config.avdName)
    if ($Config.emulatorArgs) {
        foreach ($a in $Config.emulatorArgs) { $argList += [string]$a }
    }

    $root = Get-AndemuRoot
    $emuLogDir = Join-Path $root 'logs'
    if (-not (Test-Path -LiteralPath $emuLogDir)) {
        New-Item -ItemType Directory -Path $emuLogDir -Force | Out-Null
    }
    $emuStdout = Join-Path $emuLogDir 'emulator-stdout.log'
    $emuStderr = Join-Path $emuLogDir 'emulator-stderr.log'

    Write-Info ("Запускаю: emulator.exe " + ($argList -join ' '))
    Write-DebugLog "emulator logs: $emuLogDir"

    # Redirect логов + без лишней консоли; Qt-окно эмулятора всё равно появится
    $proc = Start-Process -FilePath $EmulatorExe `
        -ArgumentList $argList `
        -WorkingDirectory (Split-Path -Parent $EmulatorExe) `
        -PassThru `
        -WindowStyle Hidden `
        -RedirectStandardOutput $emuStdout `
        -RedirectStandardError $emuStderr

    if (-not $proc) {
        throw "Не удалось запустить emulator.exe"
    }
    Write-Ok "Процесс эмулятора PID=$($proc.Id)"
    return $proc
}

function Lock-PortraitOrientation {
    param([string]$Adb)
    Write-Info "Фиксирую портретную ориентацию (без автоповорота)"
    $null = Invoke-AdbText -Adb $Adb -AdbArgs @('shell', 'settings', 'put', 'system', 'accelerometer_rotation', '0')
    $null = Invoke-AdbText -Adb $Adb -AdbArgs @('shell', 'settings', 'put', 'system', 'user_rotation', '0')
    $null = Invoke-AdbText -Adb $Adb -AdbArgs @('shell', 'wm', 'user-rotation', 'lock', '0')
}

function Start-ToolbarHelper {
    param([object]$Config)

    # не плодим хелперы
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -and $_.CommandLine -like '*toggle-emulator-toolbar.ps1*' } |
        ForEach-Object {
            try { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue } catch {}
        }

    $rootLocal = Get-AndemuRoot
    $toolbarHelper = Join-Path $rootLocal 'scripts\toggle-emulator-toolbar.ps1'
    $toolbarArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', $toolbarHelper, '-Watch', '-HideOnStart')

    Write-Info "Скрываю боковую панель эмулятора (rotate отключён)"
    Start-Process -FilePath 'powershell.exe' -ArgumentList $toolbarArgs -WindowStyle Hidden | Out-Null
}

function Install-Apk {
    param(
        [string]$Adb,
        [string]$ApkPath
    )
    Write-Info "Устанавливаю APK: $ApkPath"
    $result = Invoke-AdbText -Adb $Adb -AdbArgs @('install', '-r', $ApkPath)
    if ($result.Text) {
        Write-Host $result.Text
        Write-DebugLog ("adb install: " + ($result.Text.Trim() -replace "`r?`n", ' | '))
    }
    if ($result.ExitCode -ne 0) {
        throw "adb install -r завершился с ошибкой (код $($result.ExitCode)). Возможно APK не совместим с архитектурой x86_64 или API."
    }
    Write-Ok "APK установлен (или обновлён)"
}

function Start-App {
    param(
        [string]$Adb,
        [string]$PackageName
    )
    Write-Info "Запускаю приложение: $PackageName"
    $monkey = Invoke-AdbText -Adb $Adb -AdbArgs @('shell', 'monkey', '-p', $PackageName, '-c', 'android.intent.category.LAUNCHER', '1')
    if ($monkey.Text) { Write-DebugLog ("monkey: " + ($monkey.Text.Trim() -replace "`r?`n", ' | ')) }
    if ($monkey.ExitCode -ne 0) {
        Write-Warn "monkey вернул код $($monkey.ExitCode) — пробую am start"
        $am = Invoke-AdbText -Adb $Adb -AdbArgs @('shell', 'am', 'start', '-a', 'android.intent.action.MAIN', '-c', 'android.intent.category.LAUNCHER', $PackageName)
        if ($am.Text) { Write-DebugLog ("am start: " + ($am.Text.Trim() -replace "`r?`n", ' | ')) }
        if ($am.ExitCode -ne 0) {
            throw "Не удалось запустить приложение $PackageName"
        }
    }
    Write-Ok "Приложение запущено"
}

function Show-BarcodeHints {
    param([string]$Root)
    Write-Host ''
    Write-Host '----------------------------------------' -ForegroundColor DarkGray
    Write-Host 'Эмуляция штрихкода:' -ForegroundColor White
    Write-Host '  1. Клавиатура эмулятора: введите код и нажмите Enter'
    Write-Host '  2. Скрипт:'
    Write-Host ("     powershell -NoProfile -ExecutionPolicy Bypass -File `"$Root\scripts\scan-barcode.ps1`" 4601234567890")
    Write-Host '  3. Вручную через adb:'
    Write-Host '     adb shell input text 4601234567890'
    Write-Host '     adb shell input keyevent 66'
    Write-Host '  4. Если сканирование через камеру: Extended controls (...) → Camera'
    Write-Host '  5. Боковая панель эмулятора скрыта (rotate отключён — ломал размер окна)'
    Write-Host '----------------------------------------' -ForegroundColor DarkGray
    Write-Host ''
}

# -------------------- main --------------------
try {
    $root = Get-ProjectRoot
    $null = Initialize-AndemuLog -Name start -Root $root
    Write-Info "Корень проекта: $root"

    $config = Read-Config -Root $root
    Write-DebugLog ("apkFileName=$($config.apkFileName); apkPackage=$($config.apkPackage); avd=$($config.avdName)")

    $sdkRoot = Join-Path $root 'runtime\android-sdk'
    $avdHome = Join-Path $root 'avd'
    $emulatorExe = Join-Path $sdkRoot 'emulator\emulator.exe'
    $adb = Join-Path $sdkRoot 'platform-tools\adb.exe'
    $apkPath = Join-Path $root ("app\" + $config.apkFileName)

    if (-not (Test-Path -LiteralPath $emulatorExe)) {
        throw "Не найден emulator.exe. Сначала выполните setup (Start-TSD-Emulator.bat сделает это автоматически)."
    }
    if (-not (Test-Path -LiteralPath $adb)) {
        throw "Не найден adb.exe: $adb"
    }
    if (-not (Test-Path -LiteralPath $apkPath)) {
        throw @"
APK не найден: $apkPath

Положите файл APK в папку app\ и проверьте apkFileName в config.json.
"@
    }
    Write-Ok "APK найден: $apkPath"

    Set-SdkEnvironment -SdkRoot $sdkRoot -AvdHome $avdHome

    # Всегда синхронизируем экран AVD с config.json (раньше правки не попадали в уже созданный AVD)
    $displayChanged = Update-AndemuAvdDisplay -Config $config -AvdHome $avdHome

    $emuProc = Start-EmulatorProcess -EmulatorExe $emulatorExe -Config $config -ForceRestart:$displayChanged
    $emuPid = 0
    if ($emuProc -and $emuProc.Id) { $emuPid = [int]$emuProc.Id }
    Wait-ForBootCompleted -Adb $adb -TimeoutSec 180 -EmulatorPid $emuPid
    Lock-PortraitOrientation -Adb $adb

    # Скрыть боковую панель с rotate; кнопки питания/закрытия — в заголовке
    Start-ToolbarHelper -Config $config

    Install-Apk -Adb $adb -ApkPath $apkPath

    $packageName = Resolve-ApkPackage -Config $config -SdkRoot $sdkRoot -ApkPath $apkPath -Adb $adb -AfterInstall $true
    if (-not $packageName) {
        throw "Не удалось определить package name. Укажите apkPackage в config.json (например com.company.tsd)."
    }
    Write-Info "Используем package: $packageName"

    Start-App -Adb $adb -PackageName $packageName
    Show-BarcodeHints -Root $root

    Write-Ok "$($config.appName) готов к работе."
    Write-Info "Готово. Логи: $root\logs\"
    Complete-AndemuLog -ExitCode 0
    exit 0
} catch {
    Write-AndemuException -ErrorRecord $_
    $emuErr = Join-Path (Get-AndemuRoot) 'logs\emulator-stderr.log'
    if (Test-Path -LiteralPath $emuErr) {
        Write-Warn "Смотрите также: $emuErr"
        try {
            $tail = Get-Content -LiteralPath $emuErr -Tail 30 -ErrorAction SilentlyContinue | Out-String
            if ($tail) { Write-DebugLog ("emulator-stderr tail: " + ($tail.Trim() -replace "`r?`n", ' | ')) }
        } catch {}
    }
    Complete-AndemuLog -ExitCode 1

    # При скрытом запуске — показать ошибку в MessageBox (Unicode через WinForms)
    if ($env:ANDEMU_HIDDEN -eq '1') {
        $msg = $_.Exception.Message
        $logHint = Join-Path (Get-AndemuRoot) 'logs\start-latest.log'
        $ui = Join-Path $PSScriptRoot 'ui-message.ps1'
        $detail = $msg + [Environment]::NewLine + [Environment]::NewLine + 'Log: ' + $logHint
        try {
            if (Test-Path -LiteralPath $ui) {
                Start-Process -FilePath 'powershell.exe' -Wait -WindowStyle Normal -ArgumentList @(
                    '-NoProfile', '-ExecutionPolicy', 'Bypass',
                    '-File', $ui,
                    '-Id', 'StartFailed',
                    '-Detail', $detail
                ) | Out-Null
            } else {
                Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
                [void][System.Windows.Forms.MessageBox]::Show(
                    $detail,
                    'andemu - start error',
                    [System.Windows.Forms.MessageBoxButtons]::OK,
                    [System.Windows.Forms.MessageBoxIcon]::Error
                )
            }
        } catch {
            Start-Process -FilePath $env:ComSpec -ArgumentList @('/c', "echo ERROR & echo Log: $logHint & pause")
        }
    }
    exit 1
}
