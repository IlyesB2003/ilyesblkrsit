$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'common.ps1')
$root = Split-Path $PSScriptRoot -Parent
$res = Join-Path $root 'results\static'
New-Item -ItemType Directory -Path $res -Force | Out-Null
$lines = New-Object System.Collections.ArrayList
function Out-Line([string]$s) { [void]$lines.Add($s); Write-Host $s }

Out-Line "# Static checks on $([Environment]::OSVersion.VersionString), PowerShell $($PSVersionTable.PSVersion)"
$ps1 = Join-Path $root 'installer\install.ps1'
$tokens = $null; $errs = $null
[void][System.Management.Automation.Language.Parser]::ParseFile($ps1, [ref]$tokens, [ref]$errs)
Out-Line ("PARSE install.ps1 (Windows PowerShell 5.1): {0} errors" -f $errs.Count)
foreach ($e in $errs) { Out-Line ("  line {0}: {1}" -f $e.Extent.StartLineNumber, $e.Message) }

$m = Get-Content (Join-Path $root 'installer\manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json
Out-Line ("MANIFEST: {0} tools, {1} models" -f $m.tools.Count, $m.models.Count)

Ensure-Winget
$bad = 0; $good = 0
foreach ($t in $m.tools) {
    foreach ($id in @($t.winget)) {
        if ([string]::IsNullOrWhiteSpace([string]$id)) { continue }
        $null = winget show --id $id -e --accept-source-agreements --disable-interactivity 2>&1
        if ($LASTEXITCODE -eq 0) { $good++; Out-Line "WINGET OK      $id" } else { $bad++; Out-Line "WINGET MISSING $id (exit $LASTEXITCODE)" }
    }
}
Out-Line ("WINGET: {0} found, {1} missing" -f $good, $bad)

# Run the real setup exe the way a user does, and confirm the wizard window opens.
$exe = Join-Path $root 'installer\AI-Dev-Transfer-Setup.exe'
$sp = Start-Process -FilePath $exe -PassThru; $null = $sp.WaitForExit(120000); Write-Host "Setup.exe exit code: $($sp.ExitCode)"
Start-Sleep -Seconds 8
$boot = Join-Path $env:LOCALAPPDATA 'AI-Dev-Transfer\bootstrap'
foreach ($f in @('wizard.hta', 'install.ps1', 'manifest.json', 'assets\app.ico', 'docs\README_AR.txt')) {
    Out-Line ("EXTRACTED {0}: {1}" -f $f, (Test-Path (Join-Path $boot $f)))
}
$mshta = @(Get-Process mshta -ErrorAction SilentlyContinue)
Out-Line ("WIZARD WINDOW OPEN: {0}" -f ($mshta.Count -gt 0))
Save-Screenshot (Join-Path $res 'wizard-page1.png')
$mshta | Stop-Process -Force -ErrorAction SilentlyContinue

[System.IO.File]::WriteAllText((Join-Path $res 'static.md'), ($lines -join "`r`n"))
if ($errs.Count -gt 0) { exit 1 }
exit 0
