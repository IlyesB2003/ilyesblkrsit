# Shared helpers for the Windows installer test (GitHub Actions).
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

function Save-Screenshot {
    param([string]$Path)
    try {
        $b = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
        $bmp = New-Object System.Drawing.Bitmap $b.Width, $b.Height
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $g.CopyFromScreen($b.Location, [System.Drawing.Point]::Empty, $b.Size)
        $bmp.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
        $g.Dispose(); $bmp.Dispose()
        Write-Host "screenshot: $Path"
    } catch { Write-Host "screenshot failed: $($_.Exception.Message)" }
}

function Ensure-Winget {
    if (Get-Command winget -ErrorAction SilentlyContinue) { Write-Host "winget: $(winget --version)"; return }
    Write-Host 'winget missing on runner; installing it with Microsoft.WinGet.Client'
    Install-PackageProvider -Name NuGet -Force -Scope CurrentUser | Out-Null
    Install-Module Microsoft.WinGet.Client -Force -Scope CurrentUser -AllowClobber
    Repair-WinGetPackageManager -AllUsers -Latest
    Write-Host "winget: $(winget --version)"
}
