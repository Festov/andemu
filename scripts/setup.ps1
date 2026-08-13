#Requires -Version 5.1
<#
.SYNOPSIS
  Первичная установка portable Android SDK + создание AVD для ТСД-эмулятора.
.DESCRIPTION
  Idempotent: повторный запуск не ломает уже установленный runtime.
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
    try {
        return Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        throw "Не удалось прочитать config.json: $($_.Exception.Message)"
    }
}

function Ensure-Directory {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Set-SdkEnvironment {
    param(
        [string]$SdkRoot,
        [string]$AvdHome
    )
    $env:ANDROID_SDK_ROOT = $SdkRoot
    $env:ANDROID_HOME = $SdkRoot
    $env:ANDROID_AVD_HOME = $AvdHome
    $env:ANDROID_SDK_HOME = (Split-Path -Parent $AvdHome)

    $pathsToPrepend = @(
        (Join-Path $SdkRoot 'cmdline-tools\latest\bin'),
        (Join-Path $SdkRoot 'platform-tools'),
        (Join-Path $SdkRoot 'emulator')
    )
    foreach ($p in $pathsToPrepend) {
        if ($env:PATH -notlike "*$p*") {
            $env:PATH = "$p;$env:PATH"
        }
    }
}

function Get-SdkManager {
    param([string]$SdkRoot)
    $sm = Join-Path $SdkRoot 'cmdline-tools\latest\bin\sdkmanager.bat'
    if (-not (Test-Path -LiteralPath $sm)) {
        throw "sdkmanager не найден: $sm"
    }
    return $sm
}

function Get-AvdManager {
    param([string]$SdkRoot)
    $am = Join-Path $SdkRoot 'cmdline-tools\latest\bin\avdmanager.bat'
    if (-not (Test-Path -LiteralPath $am)) {
        throw "avdmanager не найден: $am"
    }
    return $am
}

function Install-CommandLineTools {
    param(
        [string]$Root,
        [string]$SdkRoot,
        [string]$ZipUrl = 'https://dl.google.com/android/repository/commandlinetools-win-11076708_latest.zip',
        [string]$ZipFileName = 'commandlinetools-win-11076708_latest.zip'
    )

    $latestDir = Join-Path $SdkRoot 'cmdline-tools\latest'
    $sdkmanager = Join-Path $latestDir 'bin\sdkmanager.bat'
    if (Test-Path -LiteralPath $sdkmanager) {
        Write-Ok "Command-line tools уже установлены: $latestDir"
        return
    }

    $workDir = $null
    try {
        # Архив живёт в runtime\cache до успешного конца setup (не удаляем при ошибке)
        $zipPath = Get-AndemuCachedZip -Root $Root -FileName $ZipFileName -Url $ZipUrl -MinBytes 10MB

        # Короткий stage рядом с SDK — меньше MAX_PATH, чем Downloads\...\runtime\.tmp\cmdline-extract-<guid>
        Ensure-Directory (Join-Path $SdkRoot 'cmdline-tools')
        $workDir = Join-Path $SdkRoot 'cmdline-tools\s'
        if (Test-Path -LiteralPath $workDir) {
            Remove-AndemuTempDir -Path $workDir
        }
        New-Item -ItemType Directory -Path $workDir -Force | Out-Null

        Write-Info "Распаковываю архив..."
        Expand-AndemuZip -ZipPath $zipPath -Destination $workDir

        $extracted = Join-Path $workDir 'cmdline-tools'
        if (-not (Test-Path -LiteralPath $extracted)) {
            # иногда zip уже «плоский» (bin/lib в корне)
            if (Test-Path -LiteralPath (Join-Path $workDir 'bin\sdkmanager.bat')) {
                $extracted = $workDir
            } else {
                throw "В архиве не найдена папка cmdline-tools"
            }
        }

        if (Test-Path -LiteralPath $latestDir) {
            Remove-AndemuTempDir -Path $latestDir
        }
        Move-Item -LiteralPath $extracted -Destination $latestDir
        if (-not (Test-Path -LiteralPath $sdkmanager)) {
            throw "После распаковки не найден sdkmanager.bat"
        }
        Write-Ok "Command-line tools установлены"
    } finally {
        # Кэш-zip не трогаем — только stage. Если extracted переехал в latest, workDir может остаться пустым/частичным.
        if ($workDir -and (Test-Path -LiteralPath $workDir)) {
            Remove-AndemuTempDir -Path $workDir
        }
    }
}

function Invoke-SdkManager {
    param(
        [string]$SdkManager,
        [string[]]$Arguments,
        [string]$InputText = $null
    )

    # Важно: пакеты вида build-tools;30.0.3 содержат ';' — для cmd их нужно в кавычках.
    # Правильный вызов: cmd /c ""C:\path\sdkmanager.bat" arg1 "pkg;ver" ..."
    $quotedArgs = foreach ($a in $Arguments) {
        $s = [string]$a
        if ($s -match '[\s;,&]') {
            '"' + ($s -replace '"', '""') + '"'
        } else {
            $s
        }
    }
    $argString = ($quotedArgs -join ' ').Trim()
    Write-DebugLog "sdkmanager $argString"

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $env:ComSpec
    # Двойные кавычки вокруг всей команды + кавычки вокруг .bat — требование cmd.exe
    $psi.Arguments = '/c ""' + $SdkManager + '" ' + $argString + '"'
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.RedirectStandardInput = $true
    $psi.CreateNoWindow = $true
    $psi.EnvironmentVariables['ANDROID_SDK_ROOT'] = $env:ANDROID_SDK_ROOT
    $psi.EnvironmentVariables['ANDROID_HOME'] = $env:ANDROID_HOME
    $psi.EnvironmentVariables['JAVA_TOOL_OPTIONS'] = '-Dfile.encoding=UTF-8'
    if ($env:JAVA_HOME) {
        $psi.EnvironmentVariables['JAVA_HOME'] = $env:JAVA_HOME
        $psi.EnvironmentVariables['PATH'] = (Join-Path $env:JAVA_HOME 'bin') + ';' + $env:PATH
    }

    Write-DebugLog ("cmd args: " + $psi.Arguments)

    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi
    $null = $proc.Start()

    if ($null -ne $InputText) {
        $proc.StandardInput.Write($InputText)
        $proc.StandardInput.Close()
    } else {
        $proc.StandardInput.Close()
    }

    $stdout = $proc.StandardOutput.ReadToEnd()
    $stderr = $proc.StandardError.ReadToEnd()
    $proc.WaitForExit()

    if ($stdout) {
        Write-Host $stdout
        Write-DebugLog ("sdkmanager STDOUT: " + ($stdout.Trim() -replace "`r?`n", ' | '))
    }
    if ($stderr) {
        Write-Host $stderr
        Write-DebugLog ("sdkmanager STDERR: " + ($stderr.Trim() -replace "`r?`n", ' | '))
    }
    Write-DebugLog "sdkmanager EXIT: $($proc.ExitCode)"

    return $proc.ExitCode
}

function Accept-Licenses {
    param([string]$SdkManager)
    Write-Info "Принимаю лицензии SDK..."
    # sdkmanager --licenses ожидает многократный ввод "y"
    # Важно: скобки — иначе PowerShell склеит массив в одну строку из-за приоритета ',' и '+'
    $yes = (("y`n") * 100)
    $licenseArgs = @(
        ('--sdk_root=' + $env:ANDROID_SDK_ROOT),
        '--licenses'
    )
    $code = Invoke-SdkManager -SdkManager $SdkManager -Arguments $licenseArgs -InputText $yes
    if ($code -ne 0) {
        Write-Warn "sdkmanager --licenses вернул код $code (иногда это нормально, если лицензии уже приняты)"
    } else {
        Write-Ok "Лицензии приняты"
    }
}

function Install-SdkPackages {
    param(
        [string]$SdkManager,
        [object]$Config
    )

    $packages = @(
        'platform-tools',
        'emulator',
        'build-tools;30.0.3',
        ("platforms;" + $Config.androidApi),
        $Config.systemImage
    )

    Write-Info "Устанавливаю пакеты SDK:"
    foreach ($p in $packages) { Write-Host "  - $p" }

    $args = @('--sdk_root=' + $env:ANDROID_SDK_ROOT) + $packages
    $code = Invoke-SdkManager -SdkManager $SdkManager -Arguments $args -InputText "y`n"
    if ($code -ne 0) {
        throw "Установка пакетов SDK завершилась с кодом $code"
    }

    $emulatorExe = Join-Path $env:ANDROID_SDK_ROOT 'emulator\emulator.exe'
    $adbExe = Join-Path $env:ANDROID_SDK_ROOT 'platform-tools\adb.exe'
    if (-not (Test-Path -LiteralPath $emulatorExe)) {
        throw "После установки не найден emulator.exe"
    }
    if (-not (Test-Path -LiteralPath $adbExe)) {
        throw "После установки не найден adb.exe"
    }
    Write-Ok "Пакеты SDK установлены"
}

function Test-AvdExists {
    param(
        [string]$AvdManager,
        [string]$AvdName,
        [string]$AvdHome
    )
    $ini = Join-Path $AvdHome ($AvdName + '.ini')
    $dir = Join-Path $AvdHome ($AvdName + '.avd')
    return ((Test-Path -LiteralPath $ini) -and (Test-Path -LiteralPath $dir))
}

function New-TsdAvd {
    param(
        [string]$AvdManager,
        [object]$Config,
        [string]$AvdHome
    )

    if (Test-AvdExists -AvdManager $AvdManager -AvdName $Config.avdName -AvdHome $AvdHome) {
        Write-Ok "AVD уже существует: $($Config.avdName)"
        return
    }

    Write-Info "Создаю AVD: $($Config.avdName)"
    $device = 'pixel'
    $avdArgs = @(
        'create', 'avd',
        '-n', $Config.avdName,
        '-k', $Config.systemImage,
        '-d', $device,
        '--force'
    )

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $env:ComSpec
    $quotedArgs = foreach ($a in $avdArgs) {
        $s = [string]$a
        if ($s -match '[\s;,&]') {
            '"' + ($s -replace '"', '""') + '"'
        } else {
            $s
        }
    }
    $argString = ($quotedArgs -join ' ').Trim()
    $psi.Arguments = '/c ""' + $AvdManager + '" ' + $argString + '"'
    Write-DebugLog ("avdmanager cmd: " + $psi.Arguments)
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.RedirectStandardInput = $true
    $psi.CreateNoWindow = $true
    $psi.EnvironmentVariables['ANDROID_SDK_ROOT'] = $env:ANDROID_SDK_ROOT
    $psi.EnvironmentVariables['ANDROID_HOME'] = $env:ANDROID_HOME
    $psi.EnvironmentVariables['ANDROID_AVD_HOME'] = $AvdHome

    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi
    $null = $proc.Start()
    # Ответ "no" на вопрос о custom hardware profile
    $proc.StandardInput.WriteLine('no')
    $proc.StandardInput.Close()
    $stdout = $proc.StandardOutput.ReadToEnd()
    $stderr = $proc.StandardError.ReadToEnd()
    $proc.WaitForExit()
    if ($stdout) {
        Write-Host $stdout
        Write-DebugLog ("avdmanager STDOUT: " + ($stdout.Trim() -replace "`r?`n", ' | '))
    }
    if ($stderr) {
        Write-Host $stderr
        Write-DebugLog ("avdmanager STDERR: " + ($stderr.Trim() -replace "`r?`n", ' | '))
    }

    if (-not (Test-AvdExists -AvdManager $AvdManager -AvdName $Config.avdName -AvdHome $AvdHome)) {
        throw "Не удалось создать AVD $($Config.avdName). Код выхода: $($proc.ExitCode)"
    }
    Write-Ok "AVD создан"
}

# -------------------- main --------------------
$exitCode = 1
try {
    $root = Get-ProjectRoot
    $null = Initialize-AndemuLog -Name setup -Root $root
    Write-Info "Корень проекта: $root"

    # JDK 17+ нужен sdkmanager/avdmanager (системный или portable runtime\jdk)
    $null = Ensure-AndemuJdk -Root $root -MinMajor 17
    Write-DebugLog "JAVA_HOME=$env:JAVA_HOME"

    $config = Read-Config -Root $root
    Write-DebugLog ("config: api=$($config.androidApi); image=$($config.systemImage); avd=$($config.avdName)")

    $sdkRoot = Join-Path $root 'runtime\android-sdk'
    $avdHome = Join-Path $root 'avd'
    $appDir  = Join-Path $root 'app'

    Ensure-Directory $sdkRoot
    Ensure-Directory $avdHome
    Ensure-Directory $appDir
    Ensure-Directory (Join-Path $root 'runtime')
    Ensure-Directory (Join-Path $root 'dist')
    Ensure-Directory (Join-Path $root 'logs')

    Install-CommandLineTools -Root $root -SdkRoot $sdkRoot
    Set-SdkEnvironment -SdkRoot $sdkRoot -AvdHome $avdHome

    $sdkManager = Get-SdkManager -SdkRoot $sdkRoot
    $avdManager = Get-AvdManager -SdkRoot $sdkRoot

    Accept-Licenses -SdkManager $sdkManager
    Install-SdkPackages -SdkManager $sdkManager -Config $config
    New-TsdAvd -AvdManager $avdManager -Config $config -AvdHome $avdHome
    $null = Update-AndemuAvdDisplay -Config $config -AvdHome $avdHome

    $emulatorExe = Join-Path $sdkRoot 'emulator\emulator.exe'
    if (-not (Test-Path -LiteralPath $emulatorExe)) {
        throw "Установка завершилась, но не найден emulator.exe: $emulatorExe"
    }

    # Архивы JDK/cmdline-tools больше не нужны
    Clear-AndemuSetupCache -Root $root

    Write-Host ''
    Write-Ok 'Установка завершена успешно.'
    Write-Host ''
    Write-Host 'Дальнейшие шаги:' -ForegroundColor White
    Write-Host "  1. Положите APK в папку: $appDir"
    Write-Host "  2. Обновите config.json (apkFileName, apkPackage, экран, Android API под ваш ТСД)"
    Write-Host '  3. Запустите Start-TSD-Emulator.vbs'
    Write-Host ''
    $exitCode = 0
} catch {
    Write-AndemuException -ErrorRecord $_
    $exitCode = 1
} finally {
    Complete-AndemuLog -ExitCode $exitCode
}
exit $exitCode
