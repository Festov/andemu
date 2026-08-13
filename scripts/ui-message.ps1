#Requires -Version 5.1
<#
.SYNOPSIS
  Unicode-safe MessageBox for andemu (called from launch.vbs).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('MissingScripts', 'SetupStart', 'SetupFailed', 'MissingEmulator', 'StartFailed')]
    [string]$Id,

    [string]$Detail = '',

    [int]$Code = 0
)

$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms

switch ($Id) {
    'MissingScripts' {
        $title = 'andemu'
        $icon = [System.Windows.Forms.MessageBoxIcon]::Error
        $text = "Не найдены scripts\setup.ps1 / start.ps1 в:`n$Detail"
    }
    'SetupStart' {
        $title = 'andemu'
        $icon = [System.Windows.Forms.MessageBoxIcon]::Information
        $text = "Сейчас будет установка (один раз): JDK при необходимости + Android runtime (~3-6 GB).`nПосле установки эмулятор запустится без окна консоли."
    }
    'SetupFailed' {
        $title = 'andemu'
        $icon = [System.Windows.Forms.MessageBoxIcon]::Error
        $text = "Ошибка установки (код $Code).`nСмотрите logs\setup-latest.log"
    }
    'MissingEmulator' {
        $title = 'andemu'
        $icon = [System.Windows.Forms.MessageBoxIcon]::Error
        $text = 'После setup не найден emulator.exe'
    }
    'StartFailed' {
        $title = 'andemu - ошибка запуска'
        $icon = [System.Windows.Forms.MessageBoxIcon]::Error
        if ($Detail) {
            $text = $Detail
        } else {
            $text = 'Ошибка запуска. Смотрите logs\start-latest.log'
        }
    }
    default {
        $title = 'andemu'
        $icon = [System.Windows.Forms.MessageBoxIcon]::Error
        $text = "Неизвестный диалог: $Id"
    }
}

[void][System.Windows.Forms.MessageBox]::Show(
    $text,
    $title,
    [System.Windows.Forms.MessageBoxButtons]::OK,
    $icon
)
