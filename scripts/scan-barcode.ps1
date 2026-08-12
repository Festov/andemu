#Requires -Version 5.1
<#
.SYNOPSIS
  Эмуляция ввода штрихкода в запущенный Android-эмулятор.
.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File scripts\scan-barcode.ps1 4601234567890
.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File scripts\scan-barcode.ps1 -Code 4601234567890 -NoEnter
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Code,

    [switch]$NoEnter,

    [string]$AdbPath
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

. (Join-Path $PSScriptRoot 'common.ps1')

function Get-ProjectRoot {
    return (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
}

$exitCode = 1
try {
    if (-not $Code -or $Code.Trim().Length -eq 0) {
        throw "Укажите код штрихкода. Пример: powershell -File scripts\scan-barcode.ps1 4601234567890"
    }

    $root = Get-ProjectRoot
    $null = Initialize-AndemuLog -Name scan -Root $root

    if (-not $AdbPath) {
        $AdbPath = Join-Path $root 'runtime\android-sdk\platform-tools\adb.exe'
    }
    if (-not (Test-Path -LiteralPath $AdbPath)) {
        throw "adb не найден: $AdbPath. Сначала выполните setup / запустите эмулятор."
    }

    $env:ANDROID_SDK_ROOT = Join-Path $root 'runtime\android-sdk'
    $env:ANDROID_HOME = $env:ANDROID_SDK_ROOT
    $env:ANDROID_AVD_HOME = Join-Path $root 'avd'

    $devices = & $AdbPath devices 2>$null | Out-String
    Write-DebugLog ("adb devices: " + ($devices.Trim() -replace "`r?`n", ' | '))
    if ($devices -notmatch "emulator-\d+\s+device" -and $devices -notmatch "\tdevice") {
        throw "Нет подключённого устройства/эмулятора. Сначала запустите Start-TSD-Emulator.bat"
    }

    # adb shell input text не любит некоторые символы — экранируем пробелы и спецсимволы
    $escaped = $Code.Trim() `
        -replace ' ', '%s' `
        -replace '&', '\&' `
        -replace '<', '\<' `
        -replace '>', '\>' `
        -replace '\|', '\|' `
        -replace ';', '\;' `
        -replace '\(', '\(' `
        -replace '\)', '\)' `
        -replace "'", "\\'"

    Write-Info "Отправляю текст: $($Code.Trim())"
    & $AdbPath shell input text $escaped
    if ($LASTEXITCODE -ne 0) {
        throw "adb shell input text завершился с ошибкой"
    }

    if (-not $NoEnter) {
        Write-Info "Отправляю Enter (KEYCODE_ENTER = 66)"
        & $AdbPath shell input keyevent 66
        if ($LASTEXITCODE -ne 0) {
            throw "adb shell input keyevent 66 завершился с ошибкой"
        }
    }

    Write-Ok "Штрихкод отправлен"
    $exitCode = 0
} catch {
    Write-AndemuException -ErrorRecord $_
    $exitCode = 1
} finally {
    Complete-AndemuLog -ExitCode $exitCode
}
exit $exitCode
