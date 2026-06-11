$startup = [Environment]::GetFolderPath("Startup")
$shortcutPath = Join-Path $startup "Codex Claude Usage Widget.lnk"
if (Test-Path $shortcutPath) {
    Remove-Item -LiteralPath $shortcutPath -Force
    Write-Host "Removed startup shortcut: $shortcutPath"
} else {
    Write-Host "Startup shortcut was not installed."
}

Get-CimInstance Win32_Process -Filter "name = 'powershell.exe'" |
    Where-Object { $_.CommandLine -like "*Run-UsageWidget.ps1*" } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force }

Write-Host "Stopped running widget instances."
