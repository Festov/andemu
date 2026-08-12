#Requires -Version 5.1
<#
.SYNOPSIS
  Держит скрытой правую панель Android Emulator (rotate ломает размер окна).
#>
[CmdletBinding()]
param(
    [switch]$Watch,
    [switch]$HideOnStart,
    [switch]$Hide
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')

$root = Get-AndemuRoot
$null = Initialize-AndemuLog -Name 'toolbar' -Root $root

Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Collections.Generic;
using System.Runtime.InteropServices;

public static class EmuToolbar {
  public delegate bool EnumProc(IntPtr hWnd, IntPtr lParam);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr lp);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern int GetWindowText(IntPtr hWnd, StringBuilder sb, int max);
  [DllImport("user32.dll")] public static extern int GetWindowTextLength(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT rc);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
  [DllImport("user32.dll")] public static extern int SetWindowRgn(IntPtr hWnd, IntPtr hRgn, bool bRedraw);

  public const int SW_HIDE = 0;

  [StructLayout(LayoutKind.Sequential)]
  public struct RECT { public int Left, Top, Right, Bottom; }

  public class WinInfo {
    public IntPtr Hwnd;
    public uint Pid;
    public string Title;
    public int Left, Top, Width, Height;
    public bool Visible;
  }

  public static List<WinInfo> ListProcessWindows(HashSet<int> pids) {
    var list = new List<WinInfo>();
    EnumWindows((hWnd, l) => {
      uint pid;
      GetWindowThreadProcessId(hWnd, out pid);
      if (!pids.Contains((int)pid)) return true;
      bool vis = IsWindowVisible(hWnd);
      int len = GetWindowTextLength(hWnd);
      var sb = new StringBuilder(Math.Max(1, len + 1));
      GetWindowText(hWnd, sb, sb.Capacity);
      RECT rc;
      GetWindowRect(hWnd, out rc);
      int w = rc.Right - rc.Left;
      int h = rc.Bottom - rc.Top;
      if (w <= 0 || h <= 0) return true;
      list.Add(new WinInfo {
        Hwnd = hWnd, Pid = pid, Title = sb.ToString(),
        Left = rc.Left, Top = rc.Top, Width = w, Height = h, Visible = vis
      });
      return true;
    }, IntPtr.Zero);
    return list;
  }
}
'@

function Get-EmulatorPids {
    $set = New-Object 'System.Collections.Generic.HashSet[int]'
    Get-Process -Name 'emulator','qemu-system*' -ErrorAction SilentlyContinue | ForEach-Object {
        [void]$set.Add([int]$_.Id)
    }
    return $set
}

function Find-EmulatorWindows {
    $pids = Get-EmulatorPids
    if ($pids.Count -eq 0) { return @{ Main = $null; Toolbar = $null } }

    $all = [EmuToolbar]::ListProcessWindows($pids)
    $mainCandidates = @($all | Where-Object {
        $_.Visible -and $_.Width -gt 200 -and $_.Height -gt 200 -and (
            $_.Title -match 'Android Emulator|TSD_AVD|Emulator'
        )
    })
    if ($mainCandidates.Count -eq 0) {
        $mainCandidates = @($all | Where-Object { $_.Visible -and ($_.Width * $_.Height) -gt 50000 })
    }
    $main = $mainCandidates | Sort-Object { $_.Width * $_.Height } -Descending | Select-Object -First 1

    $toolbar = $null
    if ($main) {
        $toolbar = @(
            $all | Where-Object {
                $_.Hwnd -ne $main.Hwnd -and
                $_.Width -ge 20 -and $_.Width -le 160 -and
                $_.Height -ge 120 -and
                $_.Left -ge ($main.Left + $main.Width - 40) -and
                $_.Left -le ($main.Left + $main.Width + 80) -and
                [Math]::Abs($_.Top - $main.Top) -lt 120
            } | Sort-Object Height -Descending
        ) | Select-Object -First 1

        if (-not $toolbar) {
            $toolbar = @(
                $all | Where-Object {
                    $_.Hwnd -ne $main.Hwnd -and
                    $_.Width -ge 20 -and $_.Width -le 160 -and
                    $_.Height -ge [int]($main.Height * 0.4)
                } | Sort-Object Height -Descending
            ) | Select-Object -First 1
        }
    }

    return @{ Main = $main; Toolbar = $toolbar }
}

function Repair-MainWindowRegion {
    $found = Find-EmulatorWindows
    if ($found.Main) {
        [void][EmuToolbar]::SetWindowRgn($found.Main.Hwnd, [IntPtr]::Zero, $true)
    }
}

function Hide-ToolbarWindow {
    Repair-MainWindowRegion
    $found = Find-EmulatorWindows
    if (-not $found.Main) {
        Write-Warn "Окно эмулятора не найдено"
        return $false
    }
    if (-not $found.Toolbar) {
        Write-DebugLog "toolbar window not found yet"
        return $false
    }
    [void][EmuToolbar]::ShowWindow($found.Toolbar.Hwnd, [EmuToolbar]::SW_HIDE)
    Write-Ok "Правая панель эмулятора скрыта"
    return $true
}

if ($Hide -and -not $Watch) {
    Hide-ToolbarWindow | Out-Null
    Complete-AndemuLog -ExitCode 0
    exit 0
}

if (-not $Watch) {
    Write-Info "Использование: -Watch -HideOnStart"
    Complete-AndemuLog -ExitCode 0
    exit 0
}

Write-Info "Ожидаю окно Android Emulator..."
$deadline = (Get-Date).AddMinutes(3)
while ((Get-Date) -lt $deadline -and -not (Find-EmulatorWindows).Main) {
    Start-Sleep -Seconds 1
}
if (-not (Find-EmulatorWindows).Main) {
    Write-Warn "Окно эмулятора не появилось"
    Complete-AndemuLog -ExitCode 1
    exit 1
}

Repair-MainWindowRegion
Start-Sleep -Seconds 1
for ($i = 0; $i -lt 20 -and -not (Find-EmulatorWindows).Toolbar; $i++) {
    Start-Sleep -Milliseconds 500
}

Hide-ToolbarWindow | Out-Null
Write-Ok "Боковая панель скрыта постоянно (без rotate)"

try {
    while ($true) {
        Start-Sleep -Milliseconds 800
        $found = Find-EmulatorWindows
        if (-not $found.Main) {
            Write-Info "Эмулятор закрыт — стоп"
            break
        }
        if ($found.Toolbar -and $found.Toolbar.Visible) {
            [void][EmuToolbar]::ShowWindow($found.Toolbar.Hwnd, [EmuToolbar]::SW_HIDE)
            Write-DebugLog "toolbar re-hidden"
        }
    }
} finally {
    Complete-AndemuLog -ExitCode 0
}
exit 0
