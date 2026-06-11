$ErrorActionPreference = "Stop"

$appDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$runner = Join-Path $appDir "Run-UsageWidget.ps1"
if (-not (Test-Path $runner)) {
    throw "Run-UsageWidget.ps1 was not found next to this installer."
}

$startup = [Environment]::GetFolderPath("Startup")
$shortcutPath = Join-Path $startup "Codex Claude Usage Widget.lnk"
$target = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
$arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$runner`""

$shell = New-Object -ComObject WScript.Shell
$shortcut = $shell.CreateShortcut($shortcutPath)
$shortcut.TargetPath = $target
$shortcut.Arguments = $arguments
$shortcut.WorkingDirectory = $appDir
$shortcut.WindowStyle = 7
$shortcut.Description = "Desktop widget for Codex and Claude Code usage."
$shortcut.Save()

Write-Host "Installed startup shortcut: $shortcutPath"
Start-Process -WindowStyle Hidden -FilePath $target -ArgumentList $arguments
Write-Host "Widget started."
