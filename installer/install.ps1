param(
    [string]$PlanPath = "$env:LOCALAPPDATA\AI-Dev-Transfer\plan.json",
    [string]$StatusPath = "$env:LOCALAPPDATA\AI-Dev-Transfer\status.json",
    [string]$LogPath = ""
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Add-Type -AssemblyName System.Net.Http | Out-Null

$script:Root = Join-Path $env:LOCALAPPDATA 'AI-Dev-Transfer'
$script:Tools = Join-Path $script:Root 'tools'
$script:Cache = Join-Path $script:Root 'cache'
$script:Logs = Join-Path $script:Root 'logs'
$script:McpDir = Join-Path $script:Root 'mcp'
$script:StatusPath = $StatusPath
$script:PlanPath = $PlanPath
$script:LogPath = $LogPath
$script:State = 'running'
$script:Percent = 0
$script:Stage = 'start'
$script:Message = 'Preparing installer'
$script:Detail = ''
$script:ErrText = ''
$script:Summary = [ordered]@{}
$script:LogTail = New-Object System.Collections.ArrayList
$script:Warnings = New-Object System.Collections.ArrayList
$script:Tasks = @{}
$script:TaskOrder = New-Object System.Collections.ArrayList
$script:TaskWeight = @{}
$script:TaskFraction = @{}
$script:TaskDone = @{}
$script:OllamaExe = $null
$script:WingetPath = $null
$script:Manifest = $null

foreach ($d in @($script:Root, $script:Tools, $script:Cache, $script:Logs, $script:McpDir)) {
    if (-not (Test-Path -LiteralPath $d)) {
        New-Item -ItemType Directory -Path $d -Force | Out-Null
    }
}
if ([string]::IsNullOrWhiteSpace($script:LogPath)) {
    $script:LogPath = Join-Path $script:Logs ("install-" + (Get-Date -Format 'yyyyMMdd-HHmmss') + ".log")
}

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $line = "[{0}] [{1}] {2}" -f (Get-Date -Format 'HH:mm:ss'), $Level, $Message
    Add-Content -LiteralPath $script:LogPath -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue
    [void]$script:LogTail.Add($line)
    while ($script:LogTail.Count -gt 10) { $script:LogTail.RemoveAt(0) }
    Write-Status
}

function Write-Status {
    $taskList = @()
    foreach ($id in $script:TaskOrder) {
        $t = $script:Tasks[$id]
        $taskList += [ordered]@{
            id = $t.id
            label = $t.label
            status = $t.status
            detail = $t.detail
        }
    }
    $obj = [ordered]@{
        state = $script:State
        percent = [math]::Round([double]$script:Percent, 1)
        stage = $script:Stage
        message = $script:Message
        detail = $script:Detail
        error = $script:ErrText
        tasks = $taskList
        log = @($script:LogTail)
        summary = $script:Summary
        logPath = $script:LogPath
        root = $script:Root
        updated = (Get-Date).ToString('o')
    }
    $json = $obj | ConvertTo-Json -Depth 8 -Compress
    try {
        $enc = New-Object System.Text.UnicodeEncoding($false, $true)
        [System.IO.File]::WriteAllText($script:StatusPath, $json, $enc)
    } catch {
    }
}

function Add-Task {
    param([string]$Id, [string]$Label, [double]$Weight)
    if ($script:Tasks.ContainsKey($Id)) { return }
    $script:Tasks[$Id] = [ordered]@{ id = $Id; label = $Label; status = 'pending'; detail = '' }
    [void]$script:TaskOrder.Add($Id)
    $script:TaskWeight[$Id] = $Weight
    $script:TaskFraction[$Id] = 0.0
    $script:TaskDone[$Id] = $false
}

function Start-Task {
    param([string]$Id)
    if (-not $script:Tasks.ContainsKey($Id)) { return }
    $script:Tasks[$Id].status = 'running'
    $script:Tasks[$Id].detail = ''
    $script:TaskFraction[$Id] = 0.0
    Update-Percent
}

function Complete-Task {
    param([string]$Id, [string]$Detail = '')
    if (-not $script:Tasks.ContainsKey($Id)) { return }
    $script:Tasks[$Id].status = 'done'
    $script:Tasks[$Id].detail = $Detail
    $script:TaskDone[$Id] = $true
    $script:TaskFraction[$Id] = 1.0
    Update-Percent
}

function Fail-Task {
    param([string]$Id, [string]$Detail = '')
    if (-not $script:Tasks.ContainsKey($Id)) { return }
    $script:Tasks[$Id].status = 'error'
    $script:Tasks[$Id].detail = $Detail
    Update-Percent
}

function Set-TaskFraction {
    param([string]$Id, [double]$Fraction, [string]$Detail = '')
    if (-not $script:Tasks.ContainsKey($Id)) { return }
    if ($Fraction -lt 0) { $Fraction = 0 }
    if ($Fraction -gt 0.99) { $Fraction = 0.99 }
    $script:TaskFraction[$Id] = $Fraction
    if ($Detail -ne '') { $script:Tasks[$Id].detail = $Detail }
    Update-Percent
}

function Update-Percent {
    $total = 0.0
    $done = 0.0
    foreach ($id in $script:TaskOrder) {
        $w = [double]$script:TaskWeight[$id]
        $total += $w
        if ($script:TaskDone[$id]) {
            $done += $w
        } else {
            $done += $w * [double]$script:TaskFraction[$id]
        }
    }
    if ($total -gt 0) {
        $script:Percent = [math]::Min(99.0, [math]::Round(100.0 * $done / $total, 2))
    }
    Write-Status
}

function Test-Cancelled {
    if (Test-Path -LiteralPath (Join-Path $script:Root 'cancel.flag')) {
        throw 'Cancelled by user.'
    }
}

function Refresh-Path {
    $machine = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $user = [Environment]::GetEnvironmentVariable('Path', 'User')
    $parts = @()
    foreach ($p in @($machine, $user)) {
        if (-not [string]::IsNullOrWhiteSpace($p)) {
            foreach ($x in ($p -split ';')) {
                if (-not [string]::IsNullOrWhiteSpace($x) -and ($parts -notcontains $x)) { $parts += $x }
            }
        }
    }
    $env:Path = ($parts -join ';')
}

function Add-UserPath {
    param([string]$Dir)
    if ([string]::IsNullOrWhiteSpace($Dir)) { return }
    if (-not (Test-Path -LiteralPath $Dir)) { return }
    $key = 'HKCU:\Environment'
    $cur = (Get-ItemProperty -Path $key -Name Path -ErrorAction SilentlyContinue).Path
    if ($null -eq $cur) { $cur = '' }
    $parts = @()
    foreach ($x in ($cur -split ';')) {
        if (-not [string]::IsNullOrWhiteSpace($x) -and ($parts -notcontains $x)) { $parts += $x }
    }
    if ($parts -notcontains $Dir) {
        $parts += $Dir
        Set-ItemProperty -Path $key -Name Path -Value ($parts -join ';') -Type ExpandString
        Write-Log "Added to PATH: $Dir"
    }
    if (($env:Path -split ';') -notcontains $Dir) {
        $env:Path = $env:Path + ';' + $Dir
    }
}

function Find-Exe {
    param([string]$RootDir, [string]$Name)
    if (-not (Test-Path -LiteralPath $RootDir)) { return $null }
    $f = Get-ChildItem -LiteralPath $RootDir -Filter $Name -Recurse -File -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($f) { return $f.FullName }
    return $null
}

function Download-File {
    param([string]$Url, [string]$Dest, [string]$TaskId, [string]$Label)
    $attempt = 0
    while ($attempt -lt 3) {
        $attempt++
        try {
            Write-Log "Downloading $Label (attempt $attempt): $Url"
            $handler = New-Object System.Net.Http.HttpClientHandler
            $client = New-Object System.Net.Http.HttpClient($handler)
            $client.Timeout = [TimeSpan]::FromHours(3)
            $resp = $client.GetAsync($Url, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).Result
            $resp.EnsureSuccessStatusCode() | Out-Null
            $total = $resp.Content.Headers.ContentLength
            $in = $resp.Content.ReadAsStreamAsync().Result
            $out = [System.IO.File]::Create($Dest)
            $buf = New-Object byte[] 1048576
            $read = 0L
            $last = Get-Date
            try {
                while (($n = $in.Read($buf, 0, $buf.Length)) -gt 0) {
                    Test-Cancelled
                    $out.Write($buf, 0, $n)
                    $read += $n
                    if (((Get-Date) - $last).TotalMilliseconds -gt 900) {
                        if ($total -and $total -gt 0) {
                            $frac = [double]$read / [double]$total
                            $mb = [math]::Round($read / 1MB, 1)
                            $tmb = [math]::Round($total / 1MB, 1)
                            Set-TaskFraction -Id $TaskId -Fraction $frac -Detail "$mb / $tmb MB"
                        } else {
                            $script:Tasks[$TaskId].detail = ("{0} MB" -f [math]::Round($read / 1MB, 1))
                            Write-Status
                        }
                        $last = Get-Date
                    }
                }
            } finally {
                $out.Close()
                $in.Close()
                $client.Dispose()
            }
            if ((Get-Item -LiteralPath $Dest).Length -le 0) { throw 'Downloaded file is empty.' }
            Set-TaskFraction -Id $TaskId -Fraction 0.99 -Detail 'Download complete'
            Write-Log "Downloaded $Label to $Dest"
            return
        } catch {
            if ($_.Exception.Message -like '*Cancelled by user*') { throw }
            Write-Log "Download failed ($attempt/3): $($_.Exception.Message)" 'WARN'
            if (Test-Path -LiteralPath $Dest) { Remove-Item -LiteralPath $Dest -Force -ErrorAction SilentlyContinue }
            if ($attempt -ge 3) { throw }
            Start-Sleep -Seconds 3
        }
    }
}

function Expand-Zip {
    param([string]$Zip, [string]$Dest)
    if (-not (Test-Path -LiteralPath $Dest)) { New-Item -ItemType Directory -Path $Dest -Force | Out-Null }
    $tar = Get-Command tar.exe -ErrorAction SilentlyContinue
    if ($tar) {
        & { $ErrorActionPreference = 'Continue'; & $tar.Source -xf $Zip -C $Dest 2>&1 } | ForEach-Object { Write-Log "tar: $_" }
        if ($LASTEXITCODE -eq 0) { return }
    }
    Expand-Archive -LiteralPath $Zip -DestinationPath $Dest -Force
}

function Install-WingetPackage {
    param([string]$Id, [string]$Override = '')
    if (-not $script:WingetPath) { return $false }
    if ([string]::IsNullOrWhiteSpace($Id)) { return $false }
    Write-Log "winget install $Id"
    $wargs = @('install', '--id', $Id, '-e', '--silent', '--accept-package-agreements', '--accept-source-agreements')
    if (-not [string]::IsNullOrWhiteSpace($Override)) { $wargs += @('--override', $Override) }
    $ErrorActionPreference = 'Continue'
    $out = & $script:WingetPath @wargs 2>&1
    $code = $LASTEXITCODE
    foreach ($line in $out) {
        if (-not [string]::IsNullOrWhiteSpace([string]$line)) { Write-Log ("winget: " + [string]$line) }
    }
    Write-Log "winget exit code: $code"
    if ($code -eq 0 -or $code -eq -1978335189) { return $true }
    return $false
}

function Install-OllamaFallback {
    param([string]$TaskId)
    $url = 'https://ollama.com/download/OllamaSetup.exe'
    $setup = Join-Path $script:Cache 'OllamaSetup.exe'
    Download-File -Url $url -Dest $setup -TaskId $TaskId -Label 'Ollama setup'
    $p = Start-Process -FilePath $setup -ArgumentList '/VERYSILENT', '/NORESTART', '/SUPPRESSMSGBOXES' -Wait -PassThru -ErrorAction SilentlyContinue
    if ($p -and $p.ExitCode -eq 0) { return $true }
    $p = Start-Process -FilePath $setup -ArgumentList '/S' -Wait -PassThru -ErrorAction SilentlyContinue
    if ($p -and $p.ExitCode -eq 0) { return $true }
    Write-Log 'Silent Ollama install failed; starting interactive installer.' 'WARN'
    Start-Process -FilePath $setup -Wait
    return $true
}

function Install-PythonFallback {
    param([string]$TaskId)
    $url = 'https://www.python.org/ftp/python/3.14.7/python-3.14.7-amd64.exe'
    $setup = Join-Path $script:Cache 'python-3.14.7-amd64.exe'
    Download-File -Url $url -Dest $setup -TaskId $TaskId -Label 'Python 3.14'
    $p = Start-Process -FilePath $setup -ArgumentList '/quiet', 'InstallAllUsers=1', 'PrependPath=1', 'Include_pip=1', 'Include_test=0' -Wait -PassThru
    if ($p.ExitCode -ne 0) { throw "Python installer exited with $($p.ExitCode)." }
    return $true
}

function Install-NodeFallback {
    param([string]$TaskId)
    $url = 'https://nodejs.org/dist/v26.13.1/node-v26.13.1-win-x64.zip'
    $zip = Join-Path $script:Cache 'node-win-x64.zip'
    Download-File -Url $url -Dest $zip -TaskId $TaskId -Label 'Node.js 26'
    $dest = Join-Path $script:Tools 'node'
    Expand-Zip -Zip $zip -Dest $dest
    $node = Find-Exe -RootDir $dest -Name 'node.exe'
    if (-not $node) { throw 'node.exe was not found after extraction.' }
    Add-UserPath (Split-Path $node -Parent)
    return $true
}

function Install-UvFallback {
    param([string]$TaskId)
    $url = 'https://github.com/astral-sh/uv/releases/latest/download/uv-x86_64-pc-windows-msvc.zip'
    $zip = Join-Path $script:Cache 'uv-win.zip'
    Download-File -Url $url -Dest $zip -TaskId $TaskId -Label 'uv'
    $dest = Join-Path $script:Tools 'uv'
    Expand-Zip -Zip $zip -Dest $dest
    $uv = Find-Exe -RootDir $dest -Name 'uv.exe'
    if (-not $uv) { throw 'uv.exe was not found after extraction.' }
    Add-UserPath (Split-Path $uv -Parent)
    return $true
}

function Install-JavaFallback {
    param([string]$TaskId)
    $url = 'https://api.adoptium.net/v3/binary/latest/25/ga/windows/x64/jdk/hotspot/normal/eclipse?project=jdk'
    $zip = Join-Path $script:Cache 'temurin-jdk.zip'
    Download-File -Url $url -Dest $zip -TaskId $TaskId -Label 'Temurin JDK 25'
    $dest = Join-Path $script:Tools 'java'
    Expand-Zip -Zip $zip -Dest $dest
    $java = Find-Exe -RootDir $dest -Name 'java.exe'
    if (-not $java) { throw 'java.exe was not found after extraction.' }
    $homeDir = Split-Path (Split-Path $java -Parent) -Parent
    [Environment]::SetEnvironmentVariable('JAVA_HOME', $homeDir, 'User')
    $env:JAVA_HOME = $homeDir
    Add-UserPath (Split-Path $java -Parent)
    return $true
}

function Install-FlutterFallback {
    param([string]$TaskId)
    $base = 'https://storage.googleapis.com/flutter_infra_release/releases'
    $url = $base + '/stable/windows/flutter_windows_3.47.8-stable.zip'
    $zip = Join-Path $script:Cache 'flutter-win.zip'
    try {
        Download-File -Url $url -Dest $zip -TaskId $TaskId -Label 'Flutter 3.47.8 (same as your Mac)'
    } catch {
        if ($_.Exception.Message -like '*Cancelled by user*') { throw }
        Write-Log 'Pinned Flutter 3.47.8 download failed; looking up the latest stable release.' 'WARN'
        $rel = Invoke-RestMethod -Uri ($base + '/releases_windows.json') -TimeoutSec 60
        $hash = [string]$rel.current_release.stable
        $item = @($rel.releases | Where-Object { $_.hash -eq $hash -and $_.channel -eq 'stable' }) | Select-Object -First 1
        if (-not $item) { throw 'Could not find the latest stable Flutter release.' }
        Download-File -Url ($base + '/' + $item.archive) -Dest $zip -TaskId $TaskId -Label ('Flutter ' + $item.version)
    }
    Set-TaskFraction -Id $TaskId -Fraction 0.9 -Detail 'Extracting Flutter SDK'
    $dest = Join-Path $script:Tools 'flutter-sdk'
    Expand-Zip -Zip $zip -Dest $dest
    $flutter = Find-Exe -RootDir $dest -Name 'flutter.bat'
    if (-not $flutter) { throw 'flutter.bat was not found after extraction.' }
    Add-UserPath (Split-Path $flutter -Parent)
    return $true
}

function Invoke-Logged {
    param([string]$Exe, [string[]]$ArgList)
    Write-Log ("run: {0} {1}" -f $Exe, ($ArgList -join ' '))
    $ErrorActionPreference = 'Continue'
    $out = & $Exe @ArgList 2>&1
    $code = $LASTEXITCODE
    foreach ($line in $out) {
        if (-not [string]::IsNullOrWhiteSpace([string]$line)) { Write-Log ("  " + [string]$line) }
    }
    Write-Log "exit code: $code"
    return $code
}

function Install-NpmPack {
    param($Tool)
    Refresh-Path
    $npm = Get-Command npm.cmd -ErrorAction SilentlyContinue
    if (-not $npm) {
        $cand = Join-Path $env:ProgramFiles 'nodejs\npm.cmd'
        if (Test-Path -LiteralPath $cand) { $npm = Get-Item -LiteralPath $cand }
    }
    if (-not $npm) { Write-Log 'npm was not found. Select Node.js as well.' 'WARN'; return $false }
    $exe = $(if ($npm.Source) { $npm.Source } else { $npm.FullName })
    $argList = @('install', '-g') + @($Tool.packages)
    return ((Invoke-Logged -Exe $exe -ArgList $argList) -eq 0)
}

function Find-Python {
    Refresh-Path
    $py = Get-Command py.exe -ErrorAction SilentlyContinue
    if ($py) { return ,@($py.Source, '-3') }
    $cands = @(Get-Command python.exe -All -ErrorAction SilentlyContinue | Where-Object { $_.Source -notlike '*WindowsApps*' })
    if ($cands.Count -gt 0) { return ,@($cands[0].Source) }
    return $null
}

function Install-PipPack {
    param($Tool)
    $py = Find-Python
    if (-not $py) { Write-Log 'Python was not found. Select Python as well.' 'WARN'; return $false }
    $exe = $py[0]
    $pre = @()
    if ($py.Count -gt 1) { $pre = @($py[1]) }
    [void](Invoke-Logged -Exe $exe -ArgList ($pre + @('-m', 'pip', 'install', '--upgrade', 'pip')))
    $argList = $pre + @('-m', 'pip', 'install', '--upgrade') + @($Tool.packages)
    return ((Invoke-Logged -Exe $exe -ArgList $argList) -eq 0)
}

function Install-GithubZip {
    param($Tool, [string]$TaskId)
    $api = "https://api.github.com/repos/$($Tool.github_repo)/releases/latest"
    $url = $null
    $name = $null
    try {
        Write-Log "Looking up latest release: $api"
        $rel = Invoke-RestMethod -Uri $api -Headers @{ 'User-Agent' = 'AI-Dev-Transfer' } -TimeoutSec 60
        $asset = @($rel.assets | Where-Object { $_.name -like [string]$Tool.asset_pattern }) | Select-Object -First 1
        if ($asset) { $url = [string]$asset.browser_download_url; $name = [string]$asset.name }
    } catch {
        Write-Log "GitHub lookup failed: $($_.Exception.Message)" 'WARN'
    }
    if (-not $url -and $Tool.fallback_url) {
        $url = [string]$Tool.fallback_url
        $name = Split-Path $url -Leaf
        Write-Log "Using pinned download instead: $url" 'WARN'
    }
    if (-not $url) { throw "No release file matching $($Tool.asset_pattern) in $($Tool.github_repo)." }
    $zip = Join-Path $script:Cache $name
    Download-File -Url $url -Dest $zip -TaskId $TaskId -Label $Tool.name
    $dest = Join-Path $script:Tools $Tool.id
    Expand-Zip -Zip $zip -Dest $dest
    $exe = Find-Exe -RootDir $dest -Name ([string]$Tool.bin)
    if (-not $exe) { throw "$($Tool.bin) was not found after extraction." }
    Add-UserPath (Split-Path $exe -Parent)
    return $true
}

function Install-VSCodeExtensions {
    param($Tool, [string]$TaskId)
    Refresh-Path
    $code = Get-Command code.cmd -ErrorAction SilentlyContinue
    $exe = $null
    if ($code) { $exe = $code.Source }
    foreach ($c in @((Join-Path $env:LOCALAPPDATA 'Programs\Microsoft VS Code\bin\code.cmd'), (Join-Path $env:ProgramFiles 'Microsoft VS Code\bin\code.cmd'))) {
        if (-not $exe -and (Test-Path -LiteralPath $c)) { $exe = $c }
    }
    if (-not $exe) { Write-Log 'VS Code command line was not found; extensions skipped.' 'WARN'; return }
    $list = @($Tool.extensions)
    $i = 0
    $failed = 0
    foreach ($ext in $list) {
        Test-Cancelled
        $i++
        Set-TaskFraction -Id $TaskId -Fraction (0.5 + 0.49 * $i / [math]::Max(1, $list.Count)) -Detail ("Extension {0}/{1}: {2}" -f $i, $list.Count, $ext)
        if ((Invoke-Logged -Exe $exe -ArgList @('--install-extension', $ext, '--force')) -ne 0) { $failed++ }
    }
    if ($failed -gt 0) { [void]$script:Warnings.Add("$failed VS Code extensions could not be installed.") }
}

function Test-Msvc {
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    if (-not (Test-Path -LiteralPath $vswhere)) { return $false }
    $p = & { $ErrorActionPreference = 'Continue'; & $vswhere -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath 2>$null }
    return (-not [string]::IsNullOrWhiteSpace([string]$p))
}

function Install-Rustup {
    param($Tool, [string]$TaskId)
    $exe = Join-Path $script:Cache 'rustup-init.exe'
    Download-File -Url 'https://static.rust-lang.org/rustup/dist/x86_64-pc-windows-msvc/rustup-init.exe' -Dest $exe -TaskId $TaskId -Label 'rustup-init'
    $argList = @('-y', '--profile', 'default', '--default-toolchain', 'stable')
    if (Test-Msvc) {
        Write-Log 'MSVC Build Tools found: using the MSVC Rust toolchain.'
    } else {
        Write-Log 'MSVC Build Tools not found: using the GNU Rust toolchain (no Visual Studio needed).'
        $argList += @('--default-host', 'x86_64-pc-windows-gnu')
    }
    Set-TaskFraction -Id $TaskId -Fraction 0.5 -Detail 'Installing Rust toolchain'
    $code = Invoke-Logged -Exe $exe -ArgList $argList
    Add-UserPath (Join-Path $env:USERPROFILE '.cargo\bin')
    return ($code -eq 0)
}

function Install-ZipTool {
    param([string]$Url, [string]$ZipName, [string]$DestName, [string]$Bin, [string]$TaskId, [string]$Label)
    $zip = Join-Path $script:Cache $ZipName
    Download-File -Url $Url -Dest $zip -TaskId $TaskId -Label $Label
    $dest = Join-Path $script:Tools $DestName
    Expand-Zip -Zip $zip -Dest $dest
    $exe = Find-Exe -RootDir $dest -Name $Bin
    if (-not $exe) { throw "$Bin was not found after extraction." }
    Add-UserPath (Split-Path $exe -Parent)
    return $true
}

function Install-Gradle {
    param($Tool, [string]$TaskId)
    $cur = Invoke-RestMethod -Uri 'https://services.gradle.org/versions/current' -TimeoutSec 60
    Write-Log "Latest Gradle: $($cur.version)"
    return (Install-ZipTool -Url ([string]$cur.downloadUrl) -ZipName ("gradle-" + $cur.version + "-bin.zip") -DestName 'gradle' -Bin 'gradle.bat' -TaskId $TaskId -Label ("Gradle " + $cur.version))
}

function Install-Maven {
    param($Tool, [string]$TaskId)
    $base = 'https://repo.maven.apache.org/maven2/org/apache/maven/apache-maven'
    $meta = Invoke-WebRequest -Uri ($base + '/maven-metadata.xml') -UseBasicParsing -TimeoutSec 60
    [xml]$x = $meta.Content
    $stable = @($x.metadata.versioning.versions.version | Where-Object { $_ -match '^\d+\.\d+\.\d+$' } | Sort-Object { [version]$_ } -Descending)
    if ($stable.Count -eq 0) { throw 'No stable Maven version was found.' }
    $v = [string]$stable[0]
    Write-Log "Latest stable Maven: $v"
    return (Install-ZipTool -Url ("$base/$v/apache-maven-$v-bin.zip") -ZipName "apache-maven-$v-bin.zip" -DestName 'maven' -Bin 'mvn.cmd' -TaskId $TaskId -Label "Maven $v")
}

function Install-Clojure {
    param($Tool, [string]$TaskId)
    $bbOk = $false
    foreach ($wid in @($Tool.winget)) { if (Install-WingetPackage -Id $wid) { $bbOk = $true; break } }
    $cljOk = $false
    try {
        $zip = Join-Path $script:Cache 'clojure-tools.zip'
        Download-File -Url 'https://github.com/clojure/brew-install/releases/latest/download/clojure-tools.zip' -Dest $zip -TaskId $TaskId -Label 'Clojure CLI tools'
        $tmp = Join-Path $script:Cache 'clojure-tools'
        Expand-Zip -Zip $zip -Dest $tmp
        $psd = Get-ChildItem -LiteralPath $tmp -Filter 'ClojureTools.psd1' -Recurse -File -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $psd) { throw 'ClojureTools module was not found in the download.' }
        $docs = [Environment]::GetFolderPath('MyDocuments')
        foreach ($modRoot in @((Join-Path $docs 'WindowsPowerShell\Modules'), (Join-Path $docs 'PowerShell\Modules'))) {
            $dst = Join-Path $modRoot 'ClojureTools'
            if (-not (Test-Path -LiteralPath $dst)) { New-Item -ItemType Directory -Path $dst -Force | Out-Null }
            Copy-Item -Path (Join-Path $psd.Directory.FullName '*') -Destination $dst -Recurse -Force
        }
        Write-Log 'Clojure CLI installed as a PowerShell module (use clj / clojure in PowerShell).'
        $cljOk = $true
    } catch {
        if ($_.Exception.Message -like '*Cancelled by user*') { throw }
        Write-Log "Clojure CLI failed: $($_.Exception.Message)" 'WARN'
    }
    return ($bbOk -or $cljOk)
}

function Find-ToolCommand {
    param($Tool)
    $c = $Tool.check
    if (-not $c) { return $null }
    Refresh-Path
    foreach ($n in @($c.exe)) {
        if ([string]::IsNullOrWhiteSpace([string]$n)) { continue }
        $g = @(Get-Command $n -All -ErrorAction SilentlyContinue | Where-Object { $_.Source -and $_.Source -notlike '*\WindowsApps\*' }) | Select-Object -First 1
        if ($g) { return $g.Source }
    }
    foreach ($pat in @($c.find)) {
        if ([string]::IsNullOrWhiteSpace([string]$pat)) { continue }
        $exp = [Environment]::ExpandEnvironmentVariables([string]$pat)
        $hit = Get-ChildItem -Path $exp -File -ErrorAction SilentlyContinue | Sort-Object FullName -Descending | Select-Object -First 1
        if ($hit) {
            Add-UserPath (Split-Path $hit.FullName -Parent)
            Write-Log "PATH repaired for $($Tool.name): $($hit.DirectoryName)"
            return $hit.FullName
        }
    }
    return $null
}

function Invoke-PostSteps {
    param($Tool, [string]$TaskId)
    foreach ($step in @($Tool.post)) {
        if (-not $step) { continue }
        Test-Cancelled
        $parts = @($step)
        $null = Find-ToolCommand -Tool $Tool
        Refresh-Path
        $cmd = Get-Command ([string]$parts[0]) -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $cmd) {
            [void]$script:Warnings.Add("$($Tool.name): could not run '$($parts -join ' ')' (command not found).")
            Write-Log "Post step skipped, $($parts[0]) not found." 'WARN'
            continue
        }
        Set-TaskFraction -Id $TaskId -Fraction 0.8 -Detail ("Running: " + ($parts -join ' ') + " (this can take a while)")
        $rest = @()
        if ($parts.Count -gt 1) { $rest = $parts[1..($parts.Count - 1)] }
        if ((Invoke-Logged -Exe $cmd.Source -ArgList $rest) -ne 0) {
            [void]$script:Warnings.Add("$($Tool.name): '$($parts -join ' ')' did not finish successfully. Run it manually.")
        }
    }
}

function Get-VersionLine {
    param([string]$Exe, [string[]]$ArgList)
    $o = Join-Path $script:Cache 'ver-out.txt'
    $e = Join-Path $script:Cache 'ver-err.txt'
    foreach ($f in @($o, $e)) { if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue } }
    $p = Start-Process -FilePath $Exe -ArgumentList $ArgList -NoNewWindow -PassThru -RedirectStandardOutput $o -RedirectStandardError $e
    if (-not $p.WaitForExit(90000)) {
        try { $p.Kill() } catch {}
        return 'responded slowly (timeout)'
    }
    $text = ''
    foreach ($f in @($o, $e)) {
        if (Test-Path -LiteralPath $f) { $text += ' ' + [string](Get-Content -LiteralPath $f -Raw -ErrorAction SilentlyContinue) }
    }
    $line = ($text.Trim() -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 1)
    if (-not $line) { $line = 'ok' }
    return ([string]$line).Trim()
}

function Test-InstalledTools {
    param($Tools)
    Start-Task 'verify-tools'
    $script:Stage = 'verify'
    $script:Message = 'Checking that every language runs'
    $report = New-Object System.Collections.ArrayList
    [void]$report.Add('AI Dev Transfer - verification report ' + (Get-Date).ToString('yyyy-MM-dd HH:mm'))
    [void]$report.Add('')
    $list = @($Tools | Where-Object { $_.check })
    $i = 0
    $okCount = 0
    $missing = 0
    foreach ($tool in $list) {
        Test-Cancelled
        $i++
        Set-TaskFraction -Id 'verify-tools' -Fraction ($i / [math]::Max(1, $list.Count)) -Detail $tool.name
        $exe = Find-ToolCommand -Tool $tool
        if (-not $exe) {
            $missing++
            [void]$report.Add(("MISSING  {0}" -f $tool.name))
            [void]$script:Warnings.Add("$($tool.name) is not available on PATH. See verify-report.txt.")
            continue
        }
        $ver = 'found'
        $vargs = @($tool.check.args)
        if ($vargs.Count -gt 0) {
            try { $ver = Get-VersionLine -Exe $exe -ArgList $vargs } catch { $ver = 'found (version check failed: ' + $_.Exception.Message + ')' }
        }
        $okCount++
        [void]$report.Add(("OK       {0,-34} {1}" -f $tool.name, $ver))
        Write-Log ("Verified {0}: {1}" -f $tool.name, $ver)
    }
    [void]$report.Add('')
    [void]$report.Add(("{0} working, {1} missing." -f $okCount, $missing))
    [void]$report.Add('Restart Windows, then run the installer again to retry anything marked MISSING.')
    $path = Join-Path $script:Root 'verify-report.txt'
    [System.IO.File]::WriteAllText($path, ($report -join "`r`n"), (New-Object System.Text.UTF8Encoding($false)))
    Complete-Task -Id 'verify-tools' -Detail ("{0} OK, {1} missing" -f $okCount, $missing)
    return [ordered]@{ ok = $okCount; missing = $missing; report = $path }
}

function Install-Tool {
    param([string]$Id)
    $tool = $script:Manifest.tools | Where-Object { $_.id -eq $Id } | Select-Object -First 1
    if (-not $tool) { return }
    $taskId = "tool:$Id"
    Start-Task $taskId
    $script:Stage = 'tools'
    $script:Message = "Installing $($tool.name)"
    $script:Detail = ''
    Write-Status
    $ok = $false
    $kind = [string]$tool.kind
    $custom = @('npm', 'pip', 'github', 'rustup', 'gradle', 'maven', 'clojure')
    if ($Id -eq 'vsbuild' -and (Test-Msvc)) {
        Write-Log 'MSVC Build Tools are already installed; skipping the 3.5 GB download.'
        Complete-Task -Id $taskId -Detail 'Already installed'
        return
    }
    if ($tool.check -and -not $tool.extensions -and -not $tool.post) {
        $found = Find-ToolCommand -Tool $tool
        if ($found) {
            Write-Log "$($tool.name) is already installed ($found); skipping."
            Complete-Task -Id $taskId -Detail 'Already installed'
            return
        }
    }
    try {
        switch ($kind) {
            'npm' { $ok = Install-NpmPack -Tool $tool }
            'pip' { $ok = Install-PipPack -Tool $tool }
            'github' { $ok = Install-GithubZip -Tool $tool -TaskId $taskId }
            'rustup' { $ok = Install-Rustup -Tool $tool -TaskId $taskId }
            'gradle' { $ok = Install-Gradle -Tool $tool -TaskId $taskId }
            'maven' { $ok = Install-Maven -Tool $tool -TaskId $taskId }
            'clojure' { $ok = Install-Clojure -Tool $tool -TaskId $taskId }
        }
    } catch {
        if ($_.Exception.Message -like '*Cancelled by user*') { throw }
        Write-Log "$($tool.name) failed: $($_.Exception.Message)" 'WARN'
        $ok = $false
    }
    if (-not $ok -and $custom -notcontains $kind) {
        foreach ($wid in @($tool.winget)) {
            Test-Cancelled
            if (Install-WingetPackage -Id $wid -Override ([string]$tool.override)) { $ok = $true; break }
        }
    }
    if (-not $ok -and -not [string]::IsNullOrWhiteSpace([string]$tool.fallback)) {
        Write-Log "winget failed for $($tool.name); trying official fallback." 'WARN'
        try {
            switch ($Id) {
                'ollama' { $ok = Install-OllamaFallback -TaskId $taskId }
                'python' { $ok = Install-PythonFallback -TaskId $taskId }
                'node' { $ok = Install-NodeFallback -TaskId $taskId }
                'uv' { $ok = Install-UvFallback -TaskId $taskId }
                'java' { $ok = Install-JavaFallback -TaskId $taskId }
                'flutter' { $ok = Install-FlutterFallback -TaskId $taskId }
                default { $ok = $false }
            }
        } catch {
            Write-Log "Fallback failed for $($tool.name): $($_.Exception.Message)" 'WARN'
            $ok = $false
        }
    }
    Refresh-Path
    if ($ok -and $tool.extensions) {
        try { Install-VSCodeExtensions -Tool $tool -TaskId $taskId } catch {
            if ($_.Exception.Message -like '*Cancelled by user*') { throw }
            Write-Log "VS Code extensions failed: $($_.Exception.Message)" 'WARN'
        }
    }
    if ($ok -and $tool.post) {
        try { Invoke-PostSteps -Tool $tool -TaskId $taskId } catch {
            if ($_.Exception.Message -like '*Cancelled by user*') { throw }
            Write-Log "Post-install step failed: $($_.Exception.Message)" 'WARN'
        }
    }
    if ($ok) {
        Complete-Task -Id $taskId -Detail 'Installed'
        Write-Log "$($tool.name) installed."
    } else {
        Fail-Task -Id $taskId -Detail 'Not installed'
        [void]$script:Warnings.Add("$($tool.name) could not be installed automatically.")
        Write-Log "$($tool.name) was not installed." 'WARN'
    }
}

function Ensure-Ollama {
    Refresh-Path
    $cmd = Get-Command ollama.exe -ErrorAction SilentlyContinue
    if (-not $cmd) { $cmd = Get-Command ollama -ErrorAction SilentlyContinue }
    if ($cmd) { $script:OllamaExe = $cmd.Source }
    if (-not $script:OllamaExe) {
        foreach ($p in @(
            (Join-Path $env:LOCALAPPDATA 'Programs\Ollama\ollama.exe'),
            (Join-Path $env:ProgramFiles 'Ollama\ollama.exe')
        )) {
            if (Test-Path -LiteralPath $p) { $script:OllamaExe = $p; break }
        }
    }
    if (-not $script:OllamaExe -or -not (Test-Path -LiteralPath $script:OllamaExe)) {
        throw 'Ollama executable was not found after installation.'
    }
    try {
        $null = Invoke-RestMethod -Uri 'http://127.0.0.1:11434/api/tags' -TimeoutSec 3
        Write-Log 'Ollama API is already running.'
        return
    } catch {
    }
    Write-Log "Starting Ollama: $script:OllamaExe serve"
    Start-Process -FilePath $script:OllamaExe -ArgumentList 'serve' -WindowStyle Hidden -ErrorAction SilentlyContinue
    for ($i = 0; $i -lt 90; $i++) {
        Test-Cancelled
        Start-Sleep -Seconds 1
        try {
            $null = Invoke-RestMethod -Uri 'http://127.0.0.1:11434/api/tags' -TimeoutSec 2
            Write-Log 'Ollama API is ready.'
            return
        } catch {
        }
    }
    throw 'Ollama did not start within 90 seconds.'
}

function Pull-Model {
    param($Model)
    $name = [string]$Model.name
    $taskId = "model:$name"
    Start-Task $taskId
    $script:Stage = 'models'
    $script:Message = "Downloading model $name"
    $script:Detail = ("{0} GB" -f $Model.size_gb)
    Write-Status
    $success = $false
    for ($attempt = 1; $attempt -le 2; $attempt++) {
        try {
            Test-Cancelled
            $body = @{ name = $name; model = $name; stream = $true } | ConvertTo-Json -Compress
            $handler = New-Object System.Net.Http.HttpClientHandler
            $client = New-Object System.Net.Http.HttpClient($handler)
            $client.Timeout = [TimeSpan]::FromHours(12)
            $content = New-Object -TypeName System.Net.Http.StringContent -ArgumentList @($body, [System.Text.Encoding]::UTF8, 'application/json')
            $resp = $client.PostAsync('http://127.0.0.1:11434/api/pull', $content).Result
            if (-not $resp.IsSuccessStatusCode) { throw "Ollama API returned $($resp.StatusCode)." }
            $stream = $resp.Content.ReadAsStreamAsync().Result
            $reader = New-Object System.IO.StreamReader($stream)
            $layers = @{}
            $last = Get-Date
            while (($line = $reader.ReadLine()) -ne $null) {
                Test-Cancelled
                if ([string]::IsNullOrWhiteSpace($line)) { continue }
                try { $obj = $line | ConvertFrom-Json } catch { continue }
                if ($obj.error) { throw ([string]$obj.error) }
                if ($obj.digest) {
                    $layers[[string]$obj.digest] = @{
                        completed = [double]$obj.completed
                        total = [double]$obj.total
                    }
                }
                if (((Get-Date) - $last).TotalMilliseconds -gt 900) {
                    $sc = 0.0
                    $st = 0.0
                    foreach ($k in $layers.Keys) {
                        $sc += [double]$layers[$k].completed
                        $st += [double]$layers[$k].total
                    }
                    if ($st -gt 0) {
                        $frac = $sc / $st
                        $gb = [math]::Round($sc / 1GB, 2)
                        $tgb = [math]::Round($st / 1GB, 2)
                        Set-TaskFraction -Id $taskId -Fraction $frac -Detail "$gb / $tgb GB"
                    }
                    $last = Get-Date
                }
                if ($obj.status -eq 'success') { $success = $true }
            }
            $reader.Close()
            $stream.Close()
            $client.Dispose()
            if ($success) { break }
            throw 'Ollama pull stream ended without success.'
        } catch {
            if ($_.Exception.Message -like '*Cancelled by user*') { throw }
            Write-Log "Model pull failed for $name (attempt $attempt/2): $($_.Exception.Message)" 'WARN'
            if ($attempt -ge 2) { break }
            Start-Sleep -Seconds 4
        }
    }
    if (-not $success) {
        try {
            Write-Log "Trying Ollama CLI pull for $name"
            & { $ErrorActionPreference = 'Continue'; & $script:OllamaExe pull $name 2>&1 } | ForEach-Object { Write-Log ("ollama: " + [string]$_) }
            if ($LASTEXITCODE -eq 0) { $success = $true }
        } catch {
            Write-Log "CLI pull failed: $($_.Exception.Message)" 'WARN'
        }
    }
    if ($success) {
        Complete-Task -Id $taskId -Detail 'Ready'
        Write-Log "Model ready: $name"
    } else {
        Fail-Task -Id $taskId -Detail 'Download failed'
        [void]$script:Warnings.Add("Model $name could not be downloaded.")
        Write-Log "Model failed: $name" 'WARN'
    }
}

function Write-JsonNoBom {
    param([string]$Path, $Object)
    $json = $Object | ConvertTo-Json -Depth 12
    $enc = New-Object System.Text.UTF8Encoding($false)
    $dir = Split-Path $Path -Parent
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [System.IO.File]::WriteAllText($Path, $json, $enc)
}

function Merge-McpConfig {
    param([string]$Path, [hashtable]$Servers)
    $cfg = @{}
    if (Test-Path -LiteralPath $Path) {
        try {
            $existing = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($p in $existing.PSObject.Properties) { $cfg[$p.Name] = $p.Value }
            $backup = "$Path.bak-" + (Get-Date -Format 'yyyyMMdd-HHmmss')
            Copy-Item -LiteralPath $Path -Destination $backup -Force
            Write-Log "Backed up MCP config to $backup"
        } catch {
            $backup = "$Path.broken-" + (Get-Date -Format 'yyyyMMdd-HHmmss')
            Copy-Item -LiteralPath $Path -Destination $backup -Force -ErrorAction SilentlyContinue
            Write-Log "Existing MCP config was invalid; backed up to $backup" 'WARN'
            $cfg = @{}
        }
    }
    $merged = @{}
    if ($cfg.ContainsKey('mcpServers') -and $cfg['mcpServers']) {
        foreach ($p in $cfg['mcpServers'].PSObject.Properties) { $merged[$p.Name] = $p.Value }
    }
    foreach ($k in $Servers.Keys) { $merged[$k] = $Servers[$k] }
    $cfg['mcpServers'] = $merged
    Write-JsonNoBom -Path $Path -Object $cfg
}

function Install-Mcp {
    $taskId = 'mcp'
    Start-Task $taskId
    $script:Stage = 'mcp'
    $script:Message = 'Configuring MCP servers'
    $script:Detail = ''
    Write-Status
    Refresh-Path
    $docs = Join-Path $env:USERPROFILE 'Documents'
    if (-not (Test-Path -LiteralPath $docs)) { New-Item -ItemType Directory -Path $docs -Force | Out-Null }

    $npm = Get-Command npm.cmd -ErrorAction SilentlyContinue
    if (-not $npm) { $npm = Get-Command npm -ErrorAction SilentlyContinue }
    if ($npm) {
        Write-Log 'Prefetching npm MCP servers.'
        & { $ErrorActionPreference = 'Continue'; & $npm.Source install -g --no-fund --no-audit --loglevel=error '@modelcontextprotocol/server-filesystem' '@modelcontextprotocol/server-memory' '@modelcontextprotocol/server-sequential-thinking' 2>&1 } | ForEach-Object { Write-Log ("npm: " + [string]$_) }
        if ($LASTEXITCODE -ne 0) { Write-Log 'npm MCP prefetch returned a non-zero code.' 'WARN' }
    } else {
        Write-Log 'npm was not found; npm MCP servers will be configured but not prefetched.' 'WARN'
    }

    $uv = Get-Command uv.exe -ErrorAction SilentlyContinue
    if (-not $uv) { $uv = Get-Command uv -ErrorAction SilentlyContinue }
    if ($uv) {
        foreach ($pkg in @('mcp-server-fetch', 'mcp-server-git', 'mcp-server-time')) {
            Write-Log "Installing Python MCP package $pkg"
            & { $ErrorActionPreference = 'Continue'; & $uv.Source tool install $pkg 2>&1 } | ForEach-Object { Write-Log ("uv: " + [string]$_) }
            if ($LASTEXITCODE -ne 0) { Write-Log "uv tool install failed for $pkg" 'WARN' }
        }
    } else {
        Write-Log 'uv was not found; Python MCP servers will be configured but not prefetched.' 'WARN'
    }

    $servers = @{}
    $servers['filesystem'] = [ordered]@{ command = 'cmd'; args = @('/c', 'npx', '-y', '@modelcontextprotocol/server-filesystem', $docs) }
    $servers['memory'] = [ordered]@{ command = 'cmd'; args = @('/c', 'npx', '-y', '@modelcontextprotocol/server-memory') }
    $servers['sequential-thinking'] = [ordered]@{ command = 'cmd'; args = @('/c', 'npx', '-y', '@modelcontextprotocol/server-sequential-thinking') }
    $servers['fetch'] = [ordered]@{ command = 'uvx'; args = @('mcp-server-fetch') }
    $servers['git'] = [ordered]@{ command = 'uvx'; args = @('mcp-server-git', '--repository', $docs) }
    $servers['time'] = [ordered]@{ command = 'uvx'; args = @('mcp-server-time') }

    $claude = Join-Path $env:APPDATA 'Claude\claude_desktop_config.json'
    Merge-McpConfig -Path $claude -Servers $servers
    Write-Log "Claude Desktop MCP config written: $claude"

    $cursorDir = Join-Path $env:USERPROFILE '.cursor'
    if (Test-Path -LiteralPath $cursorDir) {
        $cursor = Join-Path $cursorDir 'mcp.json'
        Merge-McpConfig -Path $cursor -Servers $servers
        Write-Log "Cursor MCP config written: $cursor"
    }

    Write-JsonNoBom -Path (Join-Path $script:McpDir 'mcp-config.json') -Object @{ mcpServers = $servers }
    $readme = @(
        'AI Dev Transfer - MCP configuration',
        '',
        'A portable MCP pack was configured for Claude Desktop and Cursor (when present).',
        'Servers: filesystem, memory, sequential-thinking, fetch, git, time.',
        '',
        'Filesystem and Git are scoped to: ' + $docs,
        'The generic config is next to this file: mcp-config.json',
        '',
        'Restart Claude Desktop / Cursor after installation so the servers are loaded.',
        'The servers use npx and uvx; the first launch may download a small package.',
        'No API keys or tokens are stored by this installer.'
    ) -join "`r`n"
    [System.IO.File]::WriteAllText((Join-Path $script:McpDir 'README.txt'), $readme, (New-Object System.Text.UTF8Encoding($false)))
    Complete-Task -Id $taskId -Detail '6 servers configured'
}

try {
    Set-Content -LiteralPath $script:LogPath -Value ("AI Dev Transfer log - " + (Get-Date).ToString('o')) -Encoding UTF8
    if (Test-Path -LiteralPath (Join-Path $script:Root 'cancel.flag')) { Remove-Item -LiteralPath (Join-Path $script:Root 'cancel.flag') -Force }

    Write-Log 'Installer started.'
    if (-not (Test-Path -LiteralPath $script:PlanPath)) { throw "Plan file not found: $script:PlanPath" }
    $plan = Get-Content -LiteralPath $script:PlanPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $components = @($plan.components)
    $selectedModelNames = @($plan.models)

    $manifestPath = Join-Path $PSScriptRoot 'manifest.json'
    $script:Manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $selectedModels = @($script:Manifest.models | Where-Object { $selectedModelNames -contains $_.name })
    $selectedTools = @($script:Manifest.tools | Where-Object { $components -contains $_.id })
    $wantMcp = ($components -contains 'mcp')

    Add-Task -Id 'preflight' -Label 'System check' -Weight 2
    if ($components -contains 'ollama') {
        Add-Task -Id 'tool:ollama' -Label 'Ollama runtime' -Weight 4
        Add-Task -Id 'ollama-start' -Label 'Ollama service' -Weight 1
    }
    foreach ($tool in $selectedTools) {
        if ($tool.id -eq 'ollama') { continue }
        $w = [math]::Max(0.5, ([double]$tool.size_mb / 100.0))
        Add-Task -Id "tool:$($tool.id)" -Label ("{0} - {1}" -f $tool.name, $tool.label_ar) -Weight $w
    }
    foreach ($m in $selectedModels) {
        Add-Task -Id "model:$($m.name)" -Label ("{0}  ({1} GB)" -f $m.name, $m.size_gb) -Weight ([double]$m.size_gb * 10.0)
    }
    if ($wantMcp) { Add-Task -Id 'mcp' -Label 'MCP servers' -Weight 4 }
    if ($selectedTools.Count -gt 0) { Add-Task -Id 'verify-tools' -Label 'Verify languages' -Weight 2 }
    Add-Task -Id 'finalize' -Label 'Finalizing' -Weight 1
    Write-Status

    $script:Stage = 'preflight'
    $script:Message = 'Checking Windows, internet, and disk space'
    Start-Task 'preflight'
    $os = [Environment]::OSVersion.Version
    if (-not [Environment]::Is64BitOperatingSystem) { throw 'A 64-bit version of Windows is required.' }
    if ($os.Major -lt 10) { throw 'Windows 10 or Windows 11 is required.' }
    try {
        $null = Invoke-WebRequest -Uri 'https://ollama.com' -UseBasicParsing -TimeoutSec 20
    } catch {
        throw 'No internet connection. Connect to the internet and run the installer again.'
    }
    $drive = Get-PSDrive -Name C
    $freeGb = [math]::Round($drive.Free / 1GB, 1)
    $requiredGb = 5.0
    foreach ($m in $selectedModels) { $requiredGb += ([double]$m.size_gb * 1.05) }
    if ($wantMcp) { $requiredGb += 0.5 }
    foreach ($tl in $selectedTools) { $requiredGb += ([double]$tl.size_mb / 1024.0) }
    $requiredGb = [math]::Round($requiredGb + 1.5, 1)
    Write-Log ("Preflight: Windows {0}, free {1} GB, required about {2} GB" -f $os, $freeGb, $requiredGb)
    if ($freeGb -lt $requiredGb) {
        throw "Not enough free space on C:. Need about $requiredGb GB, found $freeGb GB. Deselect some models and try again."
    }
    $script:WingetPath = (Get-Command winget -ErrorAction SilentlyContinue).Source
    if ($script:WingetPath) { Write-Log "winget found: $script:WingetPath" } else { Write-Log 'winget was not found; using official fallback downloads where available.' 'WARN' }
    Complete-Task -Id 'preflight' -Detail ("{0} GB free" -f $freeGb)

    if ($components -contains 'ollama') {
        Install-Tool -Id 'ollama'
        Refresh-Path
        $script:Stage = 'ollama'
        $script:Message = 'Starting Ollama'
        Start-Task 'ollama-start'
        try {
            Ensure-Ollama
            Complete-Task -Id 'ollama-start' -Detail 'API ready'
        } catch {
            Fail-Task -Id 'ollama-start' -Detail 'API not ready'
            [void]$script:Warnings.Add($_.Exception.Message)
            Write-Log "Ollama startup failed: $($_.Exception.Message)" 'WARN'
            if ($selectedModels.Count -gt 0) { throw 'Ollama could not start, so model downloads were stopped.' }
        }
    }

    foreach ($tool in $selectedTools) {
        if ($tool.id -eq 'ollama') { continue }
        Test-Cancelled
        Install-Tool -Id $tool.id
    }

    if ($selectedModels.Count -gt 0) {
        if (-not ($components -contains 'ollama')) { throw 'Ollama must be selected to download models.' }
        Ensure-Ollama
        foreach ($m in $selectedModels) {
            Test-Cancelled
            Pull-Model -Model $m
        }
        $script:Stage = 'verify'
        $script:Message = 'Verifying models'
        Write-Status
        try {
            $tags = Invoke-RestMethod -Uri 'http://127.0.0.1:11434/api/tags' -TimeoutSec 20
            $have = @($tags.models | ForEach-Object { $_.name })
            $missing = @()
            foreach ($m in $selectedModels) {
                if ($have -notcontains $m.name) { $missing += $m.name }
            }
            if ($missing.Count -gt 0) {
                throw ("Missing models: " + ($missing -join ', '))
            }
            Write-Log ("Verified {0} models." -f $selectedModels.Count)
        } catch {
            [void]$script:Warnings.Add($_.Exception.Message)
            Write-Log "Model verification warning: $($_.Exception.Message)" 'WARN'
        }
    }

    if ($wantMcp) { Install-Mcp }

    $verify = $null
    $toolsToCheck = @($selectedTools | Where-Object { $_.id -ne 'ollama' -and $script:Tasks["tool:$($_.id)"].status -eq 'done' })
    if ($selectedTools.Count -gt 0) {
        try { $verify = Test-InstalledTools -Tools $toolsToCheck } catch {
            if ($_.Exception.Message -like '*Cancelled by user*') { throw }
            Write-Log "Verification failed: $($_.Exception.Message)" 'WARN'
            Fail-Task -Id 'verify-tools' -Detail 'Check failed'
        }
    }

    $script:Stage = 'finalize'
    $script:Message = 'Finalizing installation'
    Start-Task 'finalize'
    $docsSrc = Join-Path $PSScriptRoot 'docs'
    if (Test-Path -LiteralPath $docsSrc) {
        $docsDst = Join-Path $script:Root 'docs'
        if (-not (Test-Path -LiteralPath $docsDst)) { New-Item -ItemType Directory -Path $docsDst -Force | Out-Null }
        Copy-Item -Path (Join-Path $docsSrc '*') -Destination $docsDst -Recurse -Force
    }
    $readme = @(
        'AI Dev Transfer 1.2.0',
        'Verification report: ' + (Join-Path $script:Root 'verify-report.txt'),
        '',
        'Installed under: ' + $script:Root,
        'Ollama models: ' + $env:USERPROFILE + '\.ollama',
        'Log: ' + $script:LogPath,
        '',
        'Open the wizard again from: ' + (Join-Path $script:Root 'bootstrap\wizard.hta'),
        'MCP config: ' + (Join-Path $script:McpDir 'mcp-config.json'),
        '',
        'Restart Windows after installation so PATH and JAVA_HOME are visible to every app.'
    ) -join "`r`n"
    [System.IO.File]::WriteAllText((Join-Path $script:Root 'README.txt'), $readme, (New-Object System.Text.UTF8Encoding($false)))
    try { Remove-Item -Path (Join-Path $script:Cache '*') -Recurse -Force -ErrorAction SilentlyContinue } catch {}
    $okTools = @($script:TaskOrder | Where-Object { $_ -like 'tool:*' -and $script:Tasks[$_].status -eq 'done' }).Count
    $okModels = @($script:TaskOrder | Where-Object { $_ -like 'model:*' -and $script:Tasks[$_].status -eq 'done' }).Count
    $script:Summary = [ordered]@{
        models = $okModels
        models_requested = $selectedModels.Count
        tools = $okTools
        tools_requested = $selectedTools.Count
        mcp = $(if ($wantMcp) { 6 } else { 0 })
        warnings = $script:Warnings.Count
        verified = $(if ($verify) { $verify.ok } else { 0 })
        missing = $(if ($verify) { $verify.missing } else { 0 })
        report = $(if ($verify) { $verify.report } else { '' })
    }
    Complete-Task -Id 'finalize' -Detail 'Done'
    $script:State = 'done'
    $script:Percent = 100
    $script:Stage = 'complete'
    $script:Message = 'Installation complete'
    $script:Detail = ("{0} models, {1} tools, {2} MCP servers" -f $okModels, $okTools, $script:Summary.mcp)
    Write-Log 'Installation completed successfully.'
    Write-Status
    exit 0
} catch {
    $msg = $_.Exception.Message
    if ($msg -like '*Cancelled by user*') {
        $script:State = 'cancelled'
        $script:Message = 'Installation cancelled'
    } else {
        $script:State = 'error'
        $script:Message = 'Installation failed'
    }
    $script:ErrText = $msg
    $script:Detail = $msg
    Write-Log ("FATAL: " + $msg) 'ERROR'
    Write-Status
    exit 1
}
