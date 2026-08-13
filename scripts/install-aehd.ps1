#Requires -Version 5.1
<#
.SYNOPSIS
  Установка Android Emulator Hypervisor Driver (AEHD) — для ПК без WHPX.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

. (Join-Path $PSScriptRoot 'common.ps1')

$exitCode = 1
try {
    $root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $null = Initialize-AndemuLog -Name setup -Root $root
    Write-Info "Установка AEHD. Корень: $root"

    $sdkRoot = Join-Path $root 'runtime\android-sdk'
    if (-not (Test-Path -LiteralPath (Join-Path $sdkRoot 'emulator\emulator.exe'))) {
        throw "Сначала нужен установленный SDK (запустите Start-TSD-Emulator.vbs один раз для setup)."
    }

    $ok = Install-AndemuAehdDriver -SdkRoot $sdkRoot -Root $root
    $accel = Get-AndemuAccelCheckText -SdkRoot $sdkRoot
    if ($accel) { Write-Host $accel }

    if ($ok -and (Test-AndemuAccelOk -AccelText $accel)) {
        Write-Ok 'AEHD установлен и работает. Можно запускать Start-TSD-Emulator.vbs'
        try {
            Add-Type -AssemblyName System.Windows.Forms
            [void][System.Windows.Forms.MessageBox]::Show(
                "AEHD установлен.`nМожно запускать Start-TSD-Emulator.vbs",
                'andemu',
                'OK',
                'Information'
            )
        } catch {}
        $exitCode = 0
    } else {
        $hv = Test-AndemuHyperVPresent
        $msg = Get-AndemuAccelerationHelpText -AccelText $accel -HyperVPresent:$hv
        Write-Err $msg
        try {
            Add-Type -AssemblyName System.Windows.Forms
            [void][System.Windows.Forms.MessageBox]::Show($msg, 'andemu - AEHD', 'OK', 'Error')
        } catch {}
        $exitCode = 1
    }
} catch {
    Write-AndemuException -ErrorRecord $_
    $exitCode = 1
} finally {
    Complete-AndemuLog -ExitCode $exitCode
}
exit $exitCode
