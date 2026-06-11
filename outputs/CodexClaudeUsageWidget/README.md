# CodeQuotaWidget

Small Windows desktop widget for Codex and Claude Code usage.

## What it shows

- Codex current-window and weekly usage from `%USERPROFILE%\.codex\sessions`.
- Claude Code plan usage from Claude's official OAuth usage endpoint.
- Current-window reset countdown.
- Weekly reset time, including Chinese weekday labels such as `下周二 10:00`.

The window is transparent, borderless, hidden from the taskbar, and not topmost by default, so it behaves like a desktop widget and does not sit over other apps.

## Controls

- Click the lock icon to unlock or lock dragging.
- When unlocked, drag any empty part of the widget to move it.
- Click the settings icon to show the opacity slider and Claude login button.
- Position, opacity, and lock state are saved in `config.json`.

## Run once

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Run-UsageWidget.ps1
```

## Install autostart

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Install-Autostart.ps1
```

## Uninstall autostart and stop

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Uninstall-Autostart.ps1
```

## Notes

- The widget reads Claude's local credential file to use the current access token, but no token value is stored in this repository.
- `config.json` is local machine state and is ignored by git.
- The Claude OAuth client id in the script is a public application identifier, not a client secret.
- Pass `-Topmost` to `Run-UsageWidget.ps1` if you want it visible over normal windows.
