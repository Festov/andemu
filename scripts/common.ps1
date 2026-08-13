#Requires -Version 5.1
<#
.SYNOPSIS
  Общие функции логирования для andemu.
#>

$script:AndemuLogFile = $null
$script:AndemuLogInitialized = $false

function Get-AndemuRoot {
    if ($PSScriptRoot) {
        return (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    }
    return (Get-Location).Path
}

function Initialize-AndemuLog {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('setup', 'start', 'scan', 'build', 'bat', 'toolbar')]
        [string]$Name,

        [string]$Root
    )

    if (-not $Root) { $Root = Get-AndemuRoot }
    $logsDir = Join-Path $Root 'logs'
    if (-not (Test-Path -LiteralPath $logsDir)) {
        New-Item -ItemType Directory -Path $logsDir -Force | Out-Null
    }

    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $script:AndemuLogFile = Join-Path $logsDir ("$Name-$stamp.log")
    $script:AndemuLogInitialized = $true

    $header = @(
        "======== andemu log ========",
        "name      : $Name",
        "started   : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')",
        "root      : $Root",
        "user      : $env:USERNAME",
        "computer  : $env:COMPUTERNAME",
        "psVersion : $($PSVersionTable.PSVersion)",
        "os        : $([Environment]::OSVersion.VersionString)",
        "logFile   : $($script:AndemuLogFile)",
        "============================="
    ) -join [Environment]::NewLine

    Add-Content -LiteralPath $script:AndemuLogFile -Value $header -Encoding UTF8

    # Удобный ярлык на последний лог этого типа
    $latest = Join-Path $logsDir ("$Name-latest.log")
    try {
        Copy-Item -LiteralPath $script:AndemuLogFile -Destination $latest -Force -ErrorAction SilentlyContinue
    } catch {}

    return $script:AndemuLogFile
}

function Write-AndemuLog {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,

        [ValidateSet('INFO', 'OK', 'WARN', 'ERROR', 'DEBUG')]
        [string]$Level = 'INFO'
    )

    $line = "{0} [{1,-5}] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message

    switch ($Level) {
        'INFO'  { Write-Host "[INFO]  $Message" -ForegroundColor Cyan }
        'OK'    { Write-Host "[OK]    $Message" -ForegroundColor Green }
        'WARN'  { Write-Host "[WARN]  $Message" -ForegroundColor Yellow }
        'ERROR' { Write-Host "[ОШИБКА] $Message" -ForegroundColor Red }
        'DEBUG' { Write-Host "[DEBUG] $Message" -ForegroundColor DarkGray }
    }

    if ($script:AndemuLogInitialized -and $script:AndemuLogFile) {
        try {
            Add-Content -LiteralPath $script:AndemuLogFile -Value $line -Encoding UTF8
            # обновляем latest
            $latest = Join-Path (Split-Path $script:AndemuLogFile) ((Split-Path $script:AndemuLogFile -Leaf) -replace '-\d{8}-\d{6}', '-latest')
            if ($latest -ne $script:AndemuLogFile) {
                # cheaper: just append is enough for timestamped; sync latest periodically via Copy at end
            }
        } catch {
            # не роняем скрипт из-за лога
        }
    }
}

function Write-Info([string]$Message)  { Write-AndemuLog -Level INFO  -Message $Message }
function Write-Ok([string]$Message)    { Write-AndemuLog -Level OK    -Message $Message }
function Write-Warn([string]$Message)  { Write-AndemuLog -Level WARN  -Message $Message }
function Write-Err([string]$Message)   { Write-AndemuLog -Level ERROR -Message $Message }
function Write-DebugLog([string]$Message) { Write-AndemuLog -Level DEBUG -Message $Message }

function Write-AndemuException {
    param(
        [Parameter(Mandatory = $true)]
        $ErrorRecord
    )
    Write-Err $ErrorRecord.Exception.Message
    if ($ErrorRecord.ScriptStackTrace) {
        Write-AndemuLog -Level DEBUG -Message ("StackTrace: " + $ErrorRecord.ScriptStackTrace)
        Write-Host $ErrorRecord.ScriptStackTrace -ForegroundColor DarkGray
    }
    if ($ErrorRecord.InvocationInfo -and $ErrorRecord.InvocationInfo.PositionMessage) {
        Write-AndemuLog -Level DEBUG -Message ("Position: " + ($ErrorRecord.InvocationInfo.PositionMessage -replace "`r?`n", ' | '))
    }
}

function Complete-AndemuLog {
    param([int]$ExitCode = 0)
    if (-not ($script:AndemuLogInitialized -and $script:AndemuLogFile)) { return }

    $footer = @(
        "-----------------------------",
        "finished  : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')",
        "exitCode  : $ExitCode",
        "============================="
    ) -join [Environment]::NewLine
    try {
        Add-Content -LiteralPath $script:AndemuLogFile -Value $footer -Encoding UTF8
        $leaf = Split-Path $script:AndemuLogFile -Leaf
        if ($leaf -match '^(setup|start|scan|build|bat|toolbar)-') {
            $name = $Matches[1]
            $latest = Join-Path (Split-Path $script:AndemuLogFile) ("$name-latest.log")
            Copy-Item -LiteralPath $script:AndemuLogFile -Destination $latest -Force -ErrorAction SilentlyContinue
        }
        Write-Host ""
        Write-Host "[LOG] $($script:AndemuLogFile)" -ForegroundColor DarkCyan
    } catch {}
}

function Set-IniValue {
    param(
        [string[]]$Lines,
        [string]$Key,
        [string]$Value
    )
    $found = $false
    $result = foreach ($line in $Lines) {
        if ($line -match ("^\s*" + [regex]::Escape($Key) + "\s*=")) {
            $found = $true
            "$Key=$Value"
        } else {
            $line
        }
    }
    if (-not $found) {
        $result += "$Key=$Value"
    }
    return ,$result
}

function Get-JavaMajorVersion {
    param([string]$JavaExe)
    if (-not (Test-Path -LiteralPath $JavaExe)) { return $null }
    try {
        $prevEap = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        $out = & $JavaExe -version 2>&1 | Out-String
        $ErrorActionPreference = $prevEap
    } catch {
        return $null
    }
    if ($out -match 'version\s+"1\.(\d+)') {
        return [int]$Matches[1]
    }
    if ($out -match 'version\s+"(\d+)') {
        return [int]$Matches[1]
    }
    return $null
}

function Resolve-JavaHomeFromExe {
    param([string]$JavaExe)
    if (-not (Test-Path -LiteralPath $JavaExe)) { return $null }

    $binDir = Split-Path -Parent $JavaExe
    if ((Split-Path -Leaf $binDir) -ieq 'bin') {
        $candidate = Split-Path -Parent $binDir
        if (Test-Path -LiteralPath (Join-Path $candidate 'bin\java.exe')) {
            return $candidate
        }
    }

    # Oracle javapath и подобные stub'ы — спрашиваем JVM
    try {
        $prevEap = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        $out = & $JavaExe -XshowSettings:properties -version 2>&1 | Out-String
        $ErrorActionPreference = $prevEap
    } catch {
        return $null
    }

    if ($out -match '(?m)^\s*java\.home\s*=\s*(.+?)\s*$') {
        $jh = $Matches[1].Trim()
        if ((Split-Path -Leaf $jh) -ieq 'jre') {
            $parent = Split-Path -Parent $jh
            if (Test-Path -LiteralPath (Join-Path $parent 'bin\javac.exe')) {
                return $parent
            }
        }
        return $jh
    }
    return $null
}

function Test-AndemuJdkHome {
    param(
        [string]$JdkHome,
        [int]$MinMajor = 17
    )
    if (-not $JdkHome) { return $false }
    $javaExe = Join-Path $JdkHome 'bin\java.exe'
    $javacExe = Join-Path $JdkHome 'bin\javac.exe'
    # sdkmanager надёжнее работает с полноценным JDK (javac)
    if (-not (Test-Path -LiteralPath $javaExe)) { return $false }
    if (-not (Test-Path -LiteralPath $javacExe)) { return $false }
    $major = Get-JavaMajorVersion -JavaExe $javaExe
    return ($null -ne $major -and $major -ge $MinMajor)
}

function Find-UsableJdkHome {
    <#
    .SYNOPSIS
      Ищет JDK 17+ : portable runtime\jdk, JAVA_HOME, java в PATH.
    #>
    param(
        [string]$Root,
        [int]$MinMajor = 17
    )

    $candidates = @()
    if ($Root) {
        $candidates += (Join-Path $Root 'runtime\jdk')
    }
    if ($env:JAVA_HOME) {
        $candidates += $env:JAVA_HOME.TrimEnd('\', '/')
    }

    foreach ($jdkDir in $candidates) {
        if (Test-AndemuJdkHome -JdkHome $jdkDir -MinMajor $MinMajor) {
            return $jdkDir
        }
    }

    $cmd = Get-Command java.exe -ErrorAction SilentlyContinue
    if ($cmd -and $cmd.Source) {
        $jdkDir = Resolve-JavaHomeFromExe -JavaExe $cmd.Source
        if (Test-AndemuJdkHome -JdkHome $jdkDir -MinMajor $MinMajor) {
            return $jdkDir
        }
    }

    return $null
}

function Set-AndemuJavaEnvironment {
    param([string]$JavaHome)
    if (-not $JavaHome) { return }
    $env:JAVA_HOME = $JavaHome
    $bin = Join-Path $JavaHome 'bin'
    if ($env:PATH -notlike "*$bin*") {
        $env:PATH = "$bin;$env:PATH"
    }
}

function Install-PortableTemurinJdk {
    param(
        [string]$Root,
        [int]$Major = 17,
        [string]$ZipUrl = 'https://api.adoptium.net/v3/binary/latest/17/ga/windows/x64/jdk/hotspot/normal/eclipse?project=jdk'
    )

    $jdkHome = Join-Path $Root 'runtime\jdk'
    $javaExe = Join-Path $jdkHome 'bin\java.exe'
    if (Test-Path -LiteralPath $javaExe) {
        $major = Get-JavaMajorVersion -JavaExe $javaExe
        if ($null -ne $major -and $major -ge $Major) {
            Write-Ok "Portable JDK уже установлен: $jdkHome (Java $major)"
            return $jdkHome
        }
    }

    Write-Info "Готовлю portable Eclipse Temurin JDK $Major..."

    $runtimeDir = Join-Path $Root 'runtime'
    if (-not (Test-Path -LiteralPath $runtimeDir)) {
        New-Item -ItemType Directory -Path $runtimeDir -Force | Out-Null
    }

    $workDir = $null
    try {
        $zipPath = Get-AndemuCachedZip -Root $Root -FileName 'temurin-jdk-17.zip' -Url $ZipUrl -MinBytes 20MB
        $workDir = New-AndemuTempDir -Root $Root -Prefix 'jdk-extract'

        Write-Info 'Распаковываю JDK...'
        Expand-Archive -LiteralPath $zipPath -DestinationPath $workDir -Force

        $extractedHome = Get-ChildItem -LiteralPath $workDir -Directory |
            Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'bin\java.exe') } |
            Select-Object -First 1

        if (-not $extractedHome) {
            throw 'В архиве JDK не найден bin\java.exe'
        }

        if (Test-Path -LiteralPath $jdkHome) {
            Remove-Item -LiteralPath $jdkHome -Recurse -Force
        }
        Move-Item -LiteralPath $extractedHome.FullName -Destination $jdkHome

        $major = Get-JavaMajorVersion -JavaExe (Join-Path $jdkHome 'bin\java.exe')
        if ($null -eq $major -or $major -lt $Major) {
            throw "После установки JDK версия недостаточна (нужна $Major+, получена: $major)"
        }

        Write-Ok "JDK установлен: $jdkHome (Java $major)"
        return $jdkHome
    } catch {
        throw "Не удалось установить portable JDK. Проверьте интернет и доступ к api.adoptium.net. $($_.Exception.Message)"
    } finally {
        # Архив в runtime\cache оставляем до успешного конца setup
        Remove-AndemuTempDir -Path $workDir
    }
}

function Ensure-AndemuJdk {
    <#
    .SYNOPSIS
      Гарантирует JDK 17+ для sdkmanager: использует системный или качает portable в runtime\jdk.
    #>
    param(
        [string]$Root,
        [int]$MinMajor = 17
    )

    $found = Find-UsableJdkHome -Root $Root -MinMajor $MinMajor
    if ($found) {
        Set-AndemuJavaEnvironment -JavaHome $found
        $ver = Get-JavaMajorVersion -JavaExe (Join-Path $found 'bin\java.exe')
        Write-Ok ("Java {0}: {1}" -f $ver, $found)
        return $found
    }

    Write-Warn "JDK $MinMajor+ не найден на ПК — скачаю portable в runtime\jdk"
    $installed = Install-PortableTemurinJdk -Root $Root -Major $MinMajor
    Set-AndemuJavaEnvironment -JavaHome $installed
    return $installed
}

function New-AndemuTempDir {
    <#
    .SYNOPSIS
      Временная папка внутри проекта (runtime\.tmp), без %TEMP% и 8.3-путей профиля.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Root,

        [string]$Prefix = 'tmp'
    )

    $base = Join-Path $Root 'runtime\.tmp'
    if (-not (Test-Path -LiteralPath $base)) {
        New-Item -ItemType Directory -Path $base -Force | Out-Null
    }
    $dir = Join-Path $base ($Prefix + '-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    return [System.IO.Path]::GetFullPath($dir)
}

function Remove-AndemuTempDir {
    param([string]$Path)
    if (-not $Path) { return }
    try {
        if (Test-Path -LiteralPath $Path) {
            cmd.exe /c "rmdir /s /q `"$Path`"" | Out-Null
        }
    } catch {}
    try {
        if (Test-Path -LiteralPath $Path) {
            Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue
        }
    } catch {}
}

function Get-AndemuCacheDir {
    param([Parameter(Mandatory = $true)][string]$Root)
    $dir = Join-Path $Root 'runtime\cache'
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    return [System.IO.Path]::GetFullPath($dir)
}

function Get-AndemuCachedZip {
    <#
    .SYNOPSIS
      Скачивает архив в runtime\cache (или берёт уже скачанный). Не удаляет при ошибках setup.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$FileName,
        [Parameter(Mandatory = $true)][string]$Url,
        [long]$MinBytes = 1MB
    )

    $cacheDir = Get-AndemuCacheDir -Root $Root
    $zipPath = Join-Path $cacheDir $FileName
    $partialPath = Join-Path $cacheDir ($FileName + '.partial')

    if (Test-Path -LiteralPath $zipPath) {
        $len = [long](Get-Item -LiteralPath $zipPath).Length
        if ($len -ge $MinBytes) {
            Write-Ok ("Кэш: {0} ({1:N1} MB)" -f $zipPath, ($len / 1MB))
            return $zipPath
        }
        Write-Warn "Кэш повреждён/неполный ($len байт) — скачаю заново"
        Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue
    }

    Write-Info "Скачиваю в кэш: $FileName"
    Write-Info "URL: $Url"
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        if (Test-Path -LiteralPath $partialPath) {
            Remove-Item -LiteralPath $partialPath -Force -ErrorAction SilentlyContinue
        }
        Invoke-WebRequest -Uri $Url -OutFile $partialPath -UseBasicParsing
        $len = [long](Get-Item -LiteralPath $partialPath).Length
        if ($len -lt $MinBytes) {
            throw "Скачанный файл слишком маленький ($len байт)"
        }
        Move-Item -LiteralPath $partialPath -Destination $zipPath -Force
        Write-Ok ("Сохранено в кэш: {0} ({1:N1} MB)" -f $FileName, ($len / 1MB))
        return $zipPath
    } catch {
        try { Remove-Item -LiteralPath $partialPath -Force -ErrorAction SilentlyContinue } catch {}
        throw $_
    }
}

function Clear-AndemuSetupCache {
    <#
    .SYNOPSIS
      Удаляет кэш загрузок и .tmp только после успешной установки эмулятора.
    #>
    param([Parameter(Mandatory = $true)][string]$Root)

    $cacheDir = Join-Path $Root 'runtime\cache'
    $tmpDir = Join-Path $Root 'runtime\.tmp'
    if (Test-Path -LiteralPath $cacheDir) {
        Write-Info "Очищаю кэш загрузок: $cacheDir"
        Remove-AndemuTempDir -Path $cacheDir
    }
    if (Test-Path -LiteralPath $tmpDir) {
        Remove-AndemuTempDir -Path $tmpDir
    }
}

function Update-AndemuAvdDisplay {
    <#
    .SYNOPSIS
      Синхронизирует экран/RAM AVD с config.json. Возвращает $true, если что-то изменилось.
    #>
    param(
        [object]$Config,
        [string]$AvdHome
    )

    $configIni = Join-Path $AvdHome ($Config.avdName + '.avd\config.ini')
    if (-not (Test-Path -LiteralPath $configIni)) {
        throw "Не найден config.ini AVD: $configIni"
    }

    $lines = Get-Content -LiteralPath $configIni -Encoding UTF8
    $before = ($lines -join "`n")

    $lines = Set-IniValue -Lines $lines -Key 'hw.lcd.width'    -Value ([string]$Config.screenWidth)
    $lines = Set-IniValue -Lines $lines -Key 'hw.lcd.height'   -Value ([string]$Config.screenHeight)
    $lines = Set-IniValue -Lines $lines -Key 'hw.lcd.density'  -Value ([string]$Config.screenDpi)
    $lines = Set-IniValue -Lines $lines -Key 'hw.ramSize'      -Value ([string]$Config.ramMb)
    $lines = Set-IniValue -Lines $lines -Key 'hw.keyboard'     -Value 'yes'
    $lines = Set-IniValue -Lines $lines -Key 'hw.mainKeys'     -Value 'no'
    $lines = Set-IniValue -Lines $lines -Key 'hw.gps'          -Value 'no'
    $lines = Set-IniValue -Lines $lines -Key 'ShowDeviceFrame' -Value 'no'

    $after = ($lines -join "`n")
    $changed = ($before -ne $after)
    if ($changed) {
        Set-Content -LiteralPath $configIni -Value $lines -Encoding UTF8
        Write-Ok ("AVD экран обновлён: {0}x{1} @ {2} dpi, RAM={3} MB" -f $Config.screenWidth, $Config.screenHeight, $Config.screenDpi, $Config.ramMb)
    } else {
        Write-Info ("AVD экран уже актуальный: {0}x{1} @ {2} dpi" -f $Config.screenWidth, $Config.screenHeight, $Config.screenDpi)
    }
    return $changed
}

