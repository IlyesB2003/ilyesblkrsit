param([string]$Name, [string]$Components, [int]$TimeoutMinutes = 30)
# End-to-end test: run the real Setup.exe, let the wizard click through its own pages
# (autotest mode), install the chosen components, then collect logs and screenshots.
$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'common.ps1')
$root = Split-Path $PSScriptRoot -Parent
$res = Join-Path $root "results\$Name"
New-Item -ItemType Directory -Path $res -Force | Out-Null
$appRoot = Join-Path $env:LOCALAPPDATA 'AI-Dev-Transfer'
New-Item -ItemType Directory -Path $appRoot -Force | Out-Null
$disk = Get-PSDrive C
Write-Host ("C: free {0:N1} GB" -f ($disk.Free / 1GB))
Ensure-Winget

[System.IO.File]::WriteAllText((Join-Path $appRoot 'autotest.txt'), $Components)
$exe = Join-Path $root 'installer\AI-Dev-Transfer-Setup.exe'
$start = Get-Date
$sp = Start-Process -FilePath $exe -PassThru; $null = $sp.WaitForExit(120000); Write-Host "Setup.exe exit code: $($sp.ExitCode)"
foreach ($t in @(3, 7, 11, 14, 17, 22, 30, 45)) {
    while (((Get-Date) - $start).TotalSeconds -lt $t) { Start-Sleep -Milliseconds 300 }
    Save-Screenshot (Join-Path $res ("wizard-{0:D2}s.png" -f $t))
}

$statusPath = Join-Path $appRoot 'status.json'
$mode = 'wizard'
if (-not (Test-Path $statusPath)) {
    Start-Sleep -Seconds 60
    if (-not (Test-Path $statusPath)) {
        Write-Host 'WIZARD DID NOT START THE INSTALL - running install.ps1 directly as a fallback test'
        $mode = 'direct (wizard failed)'
        $plan = @{ components = @($Components -split ',' | Where-Object { $_ -and $_ -notlike '*:*' }); models = @($Components -split ',' | Where-Object { $_ -like '*:*' }) }
        [System.IO.File]::WriteAllText((Join-Path $appRoot 'plan.json'), ($plan | ConvertTo-Json))
        Start-Process powershell.exe -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $appRoot 'bootstrap\install.ps1')) -WindowStyle Minimized
    }
}

$state = ''
$nextShot = (Get-Date).AddMinutes(5)
while (((Get-Date) - $start).TotalMinutes -lt $TimeoutMinutes) {
    Start-Sleep -Seconds 20
    try {
        $s = [System.IO.File]::ReadAllText($statusPath, [System.Text.Encoding]::Unicode) | ConvertFrom-Json
        $state = $s.state
        Write-Host ("[{0:N0} min] {1}% {2} - {3}" -f ((Get-Date) - $start).TotalMinutes, $s.percent, $s.message, $s.detail)
        if ($state -eq 'done' -or $state -eq 'error' -or $state -eq 'cancelled') { break }
    } catch {}
    if ((Get-Date) -gt $nextShot) {
        Save-Screenshot (Join-Path $res ("progress-{0:D3}min.png" -f [int]((Get-Date) - $start).TotalMinutes))
        $nextShot = (Get-Date).AddMinutes(10)
    }
}
Start-Sleep -Seconds 6
Save-Screenshot (Join-Path $res 'finish.png')

foreach ($f in @('status.json', 'plan.json', 'verify-report.txt', 'README.txt')) {
    $p = Join-Path $appRoot $f
    if (Test-Path $p) { Copy-Item $p $res -Force }
}
Get-ChildItem (Join-Path $appRoot 'logs') -Filter *.log -ErrorAction SilentlyContinue | Copy-Item -Destination $res -Force

$md = New-Object System.Collections.ArrayList
[void]$md.Add("# Part: $Name")
[void]$md.Add("")
[void]$md.Add("- Mode: $mode")
[void]$md.Add("- Final state: **$state**")
[void]$md.Add(("- Duration: {0:N0} minutes" -f ((Get-Date) - $start).TotalMinutes))
[void]$md.Add("- Components: $Components")
[void]$md.Add("")
try {
    $s = [System.IO.File]::ReadAllText($statusPath, [System.Text.Encoding]::Unicode) | ConvertFrom-Json
    [void]$md.Add("| Task | Status | Detail |")
    [void]$md.Add("|---|---|---|")
    foreach ($t in $s.tasks) { [void]$md.Add("| $($t.label) | $($t.status) | $($t.detail) |") }
    if ($s.error) { [void]$md.Add(""); [void]$md.Add("Error: $($s.error)") }
} catch { [void]$md.Add("status.json could not be read: $($_.Exception.Message)") }
$vr = Join-Path $appRoot 'verify-report.txt'
if (Test-Path $vr) { [void]$md.Add(""); [void]$md.Add('```'); [void]$md.Add((Get-Content $vr -Raw)); [void]$md.Add('```') }
[System.IO.File]::WriteAllText((Join-Path $res 'summary.md'), ($md -join "`r`n"))
Get-Content (Join-Path $res 'summary.md') | Add-Content $env:GITHUB_STEP_SUMMARY
exit 0
