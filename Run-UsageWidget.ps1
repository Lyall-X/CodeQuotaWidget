param(
    [int]$RefreshSeconds = 3,
    [switch]$Once,
    [switch]$Topmost
)

$ErrorActionPreference = "SilentlyContinue"

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Windows.Forms

Add-Type @"
using System;
using System.Runtime.InteropServices;

public static class Win32WindowTools {
    public const int GWL_EXSTYLE = -20;
    public const int WS_EX_TOOLWINDOW = 0x00000080;
    public const uint SWP_NOSIZE = 0x0001;
    public const uint SWP_NOMOVE = 0x0002;
    public const uint SWP_NOACTIVATE = 0x0010;
    public static readonly IntPtr HWND_BOTTOM = new IntPtr(1);

    [DllImport("user32.dll")]
    public static extern int GetWindowLong(IntPtr hWnd, int nIndex);

    [DllImport("user32.dll")]
    public static extern int SetWindowLong(IntPtr hWnd, int nIndex, int dwNewLong);

    [DllImport("user32.dll")]
    public static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter, int X, int Y, int cx, int cy, uint uFlags);
}
"@

$script:AppDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:ConfigPath = Join-Path $script:AppDir "config.json"
$script:IsLocked = $true
$script:IconLock = [string][char]0xE72E
$script:IconUnlock = [string][char]0xE785
$script:IconSettings = [string][char]0xE713
$script:ClaudeClientId = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
$script:ClaudeCredentialsPath = Join-Path $env:USERPROFILE ".claude\.credentials.json"
$script:ClaudeLastError = ""
$script:ClaudeForceRefresh = $false
$script:ClaudeOfficialCache = $null
$script:ClaudeNextFetch = [DateTime]::MinValue
$script:ClaudeBackoffSeconds = 300
$script:CodexLastLimits = $null
$script:GeminiUsageScript = Join-Path $script:AppDir "Get-GeminiUsage.cjs"
$script:GeminiUsageCache = $null
$script:GeminiNextFetch = [DateTime]::MinValue
$script:GeminiBackoffSeconds = 180

function Convert-TokenCount {
    param([double]$Value)
    if ($Value -ge 1000000) { return ("{0:N1}M" -f ($Value / 1000000)) }
    if ($Value -ge 1000) { return ("{0:N1}K" -f ($Value / 1000)) }
    return ("{0:N0}" -f $Value)
}

function Get-Number {
    param($Value)
    if ($null -eq $Value) { return 0.0 }
    try { return [double]$Value } catch { return 0.0 }
}

function Convert-ResetDelta {
    param($Date)
    if (-not $Date) { return "n/a" }
    $span = $Date - (Get-Date)
    if ($span.TotalSeconds -le 0) { return "soon" }
    $hours = [Math]::Floor($span.TotalHours)
    $minutes = [Math]::Max(0, [Math]::Floor($span.TotalMinutes % 60))
    return ("{0}h{1}min" -f $hours, $minutes)
}

function Convert-ResetClock {
    param($Date)
    if (-not $Date) { return "n/a" }
    $zhou = [string][char]0x5468
    $next = [string][char]0x4E0B
    $days = @(
        ($zhou + [string][char]0x65E5),
        ($zhou + [string][char]0x4E00),
        ($zhou + [string][char]0x4E8C),
        ($zhou + [string][char]0x4E09),
        ($zhou + [string][char]0x56DB),
        ($zhou + [string][char]0x4E94),
        ($zhou + [string][char]0x516D)
    )
    $today = (Get-Date).Date
    $daysSinceMonday = ([int]$today.DayOfWeek + 6) % 7
    $nextWeekStart = $today.AddDays(7 - $daysSinceMonday)
    $followingWeekStart = $nextWeekStart.AddDays(7)
    $dayText = $days[[int]$Date.DayOfWeek]
    if ($Date.Date -ge $nextWeekStart -and $Date.Date -lt $followingWeekStart) {
        $dayText = $next + $dayText
    }
    return ("{0} {1}" -f $dayText, $Date.ToString("HH:mm"))
}

function Convert-AnyResetTime {
    param($Value)
    if ($null -eq $Value) { return $null }
    try {
        if ($Value -is [ValueType]) {
            $number = [double]$Value
            if ($number -gt 999999999999) { return [DateTimeOffset]::FromUnixTimeMilliseconds([int64]$number).LocalDateTime }
            if ($number -gt 999999999) { return [DateTimeOffset]::FromUnixTimeSeconds([int64]$number).LocalDateTime }
        }
        return [DateTime]::Parse([string]$Value).ToLocalTime()
    } catch {
        return $null
    }
}

function Read-WidgetConfig {
    $defaults = [ordered]@{
        left = $null
        top = $null
        opacity = 0.82
        locked = $true
    }
    if (Test-Path $script:ConfigPath) {
        try {
            $cfg = Get-Content $script:ConfigPath -Raw | ConvertFrom-Json
            foreach ($key in @("left", "top", "opacity", "locked")) {
                if ($null -ne $cfg.$key) { $defaults[$key] = $cfg.$key }
            }
        } catch {}
    }
    return [pscustomobject]$defaults
}

function Save-WidgetConfig {
    param($Window, [double]$Opacity, [bool]$Locked)
    [pscustomobject]@{
        left = [Math]::Round($Window.Left)
        top = [Math]::Round($Window.Top)
        opacity = [Math]::Round($Opacity, 2)
        locked = $Locked
    } | ConvertTo-Json | Set-Content -Path $script:ConfigPath -Encoding UTF8
}

function Get-JsonLines {
    param([string]$Path)
    try {
        $stream = New-Object System.IO.FileStream($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        $reader = New-Object System.IO.StreamReader($stream)
        try {
            while (($line = $reader.ReadLine()) -ne $null) {
                if ($line.Length -gt 1) {
                    try { $line | ConvertFrom-Json -ErrorAction Stop } catch {}
                }
            }
        } finally {
            $reader.Dispose()
            $stream.Dispose()
        }
    } catch {}
}

function New-LimitInfo {
    param($Limit)
    if (-not $Limit) {
        return [pscustomobject]@{
            UsedPercent = $null
            WindowMinutes = $null
            ResetsAt = $null
            ResetIn = "n/a"
            ResetClock = "n/a"
        }
    }
    $reset = $null
    if ($Limit.resets_at) {
        $reset = [DateTimeOffset]::FromUnixTimeSeconds([int64]$Limit.resets_at).LocalDateTime
    }
    return [pscustomobject]@{
        UsedPercent = Get-Number $Limit.used_percent
        WindowMinutes = [int](Get-Number $Limit.window_minutes)
        ResetsAt = $reset
        ResetIn = Convert-ResetDelta $reset
        ResetClock = Convert-ResetClock $reset
    }
}

function Get-CodexUsage {
    $root = Join-Path $env:USERPROFILE ".codex\sessions"
    $now = Get-Date
    $today = [DateTime]::Today
    $scanStart = $today.AddDays(-8)
    $events = @()
    $latestLimits = $null
    $latestContextWindow = $null
    $latestEventTime = $null

    if (Test-Path $root) {
        $files = Get-ChildItem -Path $root -Recurse -Filter "*.jsonl" -File |
            Where-Object { $_.LastWriteTime -ge $scanStart } |
            Sort-Object LastWriteTime

        foreach ($file in $files) {
            foreach ($obj in Get-JsonLines $file.FullName) {
                if ($obj.timestamp) {
                    try { $eventTime = [DateTime]::Parse($obj.timestamp).ToLocalTime() } catch { $eventTime = $file.LastWriteTime }
                } else {
                    $eventTime = $file.LastWriteTime
                }
                if ($eventTime -lt $scanStart) { continue }

                if ($obj.payload.rate_limits) {
                    $latestLimits = $obj.payload.rate_limits
                }

                if ($obj.type -eq "event_msg" -and $obj.payload.type -eq "token_count") {
                    $usage = $obj.payload.info.last_token_usage
                    if (-not $usage) { $usage = $obj.payload.info.total_token_usage }
                    $tokens = Get-Number $usage.total_tokens
                    if ($tokens -le 0) {
                        $tokens = (Get-Number $usage.input_tokens) + (Get-Number $usage.output_tokens)
                    }
                    $events += [pscustomobject]@{ Time = $eventTime; Tokens = $tokens }

                    if ($obj.payload.info.model_context_window) { $latestContextWindow = [int](Get-Number $obj.payload.info.model_context_window) }
                    $latestEventTime = $eventTime
                }
            }
        }
    }

    if ($latestLimits) {
        $script:CodexLastLimits = $latestLimits
    } elseif ($script:CodexLastLimits) {
        $latestLimits = $script:CodexLastLimits
    }

    $primary = New-LimitInfo $latestLimits.primary
    $secondary = New-LimitInfo $latestLimits.secondary

    $primaryStart = if ($primary.ResetsAt -and $primary.WindowMinutes) { $primary.ResetsAt.AddMinutes(-$primary.WindowMinutes) } else { $today }
    $secondaryStart = if ($secondary.ResetsAt -and $secondary.WindowMinutes) { $secondary.ResetsAt.AddMinutes(-$secondary.WindowMinutes) } else { $today.AddDays(-6) }

    $currentTokens = ($events | Where-Object { $_.Time -ge $primaryStart -and $_.Time -le $now } | Measure-Object -Property Tokens -Sum).Sum
    $weekTokens = ($events | Where-Object { $_.Time -ge $secondaryStart -and $_.Time -le $now } | Measure-Object -Property Tokens -Sum).Sum
    $todayTokens = ($events | Where-Object { $_.Time.Date -eq $today } | Measure-Object -Property Tokens -Sum).Sum

    if ($null -eq $currentTokens) { $currentTokens = 0 }
    if ($null -eq $weekTokens) { $weekTokens = 0 }
    if ($null -eq $todayTokens) { $todayTokens = 0 }

    return [pscustomobject]@{
        CurrentTokens = [double]$currentTokens
        WeekTokens = [double]$weekTokens
        TodayTokens = [double]$todayTokens
        CurrentTurns = @($events | Where-Object { $_.Time -ge $primaryStart -and $_.Time -le $now }).Count
        WeekTurns = @($events | Where-Object { $_.Time -ge $secondaryStart -and $_.Time -le $now }).Count
        Primary = $primary
        Secondary = $secondary
        LimitId = $latestLimits.limit_id
        LimitName = $latestLimits.limit_name
        PlanType = $latestLimits.plan_type
        Credits = $latestLimits.credits
        IndividualLimit = $latestLimits.individual_limit
        RateLimitReachedType = $latestLimits.rate_limit_reached_type
        ContextWindow = $latestContextWindow
        LastSeen = $latestEventTime
        Status = if ($events.Count -gt 0) { "ok" } else { "no data" }
    }
}

function Get-ClaudeUsage {
    $root = Join-Path $env:USERPROFILE ".claude\projects"
    $today = [DateTime]::Today
    $weekStart = $today.AddDays(-6)
    $result = [ordered]@{
        TodayTokens = 0
        WeekTokens = 0
        TodayTurns = 0
        WeekTurns = 0
        CacheTokensToday = 0
        ServiceTier = $null
        LastSeen = $null
        Status = "no data"
    }
    if (-not (Test-Path $root)) { return [pscustomobject]$result }

    $seen = New-Object "System.Collections.Generic.HashSet[string]"
    $files = Get-ChildItem -Path $root -Recurse -Filter "*.jsonl" -File |
        Where-Object { $_.LastWriteTime -ge $weekStart } |
        Sort-Object LastWriteTime

    foreach ($file in $files) {
        foreach ($obj in Get-JsonLines $file.FullName) {
            $usage = $obj.message.usage
            if (-not $usage) { continue }

            if ($obj.timestamp) {
                try { $eventTime = [DateTime]::Parse($obj.timestamp).ToLocalTime() } catch { $eventTime = $file.LastWriteTime }
            } else {
                $eventTime = $file.LastWriteTime
            }
            if ($eventTime -lt $weekStart) { continue }

            $dedupeKey = $obj.requestId
            if (-not $dedupeKey) { $dedupeKey = $obj.message.id }
            if (-not $dedupeKey) { $dedupeKey = "{0}:{1}" -f $file.FullName, $obj.uuid }
            if (-not $seen.Add([string]$dedupeKey)) { continue }

            $input = Get-Number $usage.input_tokens
            $output = Get-Number $usage.output_tokens
            $cacheRead = Get-Number $usage.cache_read_input_tokens
            $cacheCreate = Get-Number $usage.cache_creation_input_tokens
            $tokens = $input + $output + $cacheRead + $cacheCreate

            $result.WeekTokens += $tokens
            $result.WeekTurns += 1
            if ($eventTime.Date -eq $today) {
                $result.TodayTokens += $tokens
                $result.CacheTokensToday += $cacheRead + $cacheCreate
                $result.TodayTurns += 1
            }
            if ($usage.service_tier) { $result.ServiceTier = $usage.service_tier }
            $result.LastSeen = $eventTime
            $result.Status = "ok"
        }
    }

    return [pscustomobject]$result
}

function Read-ClaudeCredentials {
    if (-not (Test-Path $script:ClaudeCredentialsPath)) { return $null }
    try { return Get-Content $script:ClaudeCredentialsPath -Raw | ConvertFrom-Json } catch { return $null }
}

function Save-ClaudeCredentials {
    param($Credentials)
    $backup = "$script:ClaudeCredentialsPath.bak-usage-widget"
    if (-not (Test-Path $backup)) {
        Copy-Item -LiteralPath $script:ClaudeCredentialsPath -Destination $backup -Force
    }
    $json = $Credentials | ConvertTo-Json -Depth 12 -Compress
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($script:ClaudeCredentialsPath, $json, $utf8NoBom)
}

function Refresh-ClaudeAccessToken {
    $cred = Read-ClaudeCredentials
    if (-not $cred -or -not $cred.claudeAiOauth.refreshToken) {
        throw "missing refresh token"
    }

    $body = @{
        grant_type = "refresh_token"
        refresh_token = $cred.claudeAiOauth.refreshToken
        client_id = $script:ClaudeClientId
        scope = ($cred.claudeAiOauth.scopes -join " ")
    } | ConvertTo-Json

    $tokenResp = Invoke-RestMethod -Uri "https://platform.claude.com/v1/oauth/token" -Method Post -ContentType "application/json" -Body $body
    if ($tokenResp.access_token) { $cred.claudeAiOauth.accessToken = $tokenResp.access_token }
    if ($tokenResp.refresh_token) { $cred.claudeAiOauth.refreshToken = $tokenResp.refresh_token }
    if ($tokenResp.expires_in) {
        $nowMs = [DateTimeOffset]::Now.ToUnixTimeMilliseconds()
        $cred.claudeAiOauth.expiresAt = [int64]($nowMs + ([int64]$tokenResp.expires_in * 1000))
    }
    Save-ClaudeCredentials $cred
    return $cred
}

function Get-ClaudeValidCredentials {
    param([switch]$ForceRefresh)
    $cred = Read-ClaudeCredentials
    if (-not $cred -or -not $cred.claudeAiOauth.accessToken) {
        if ($ForceRefresh) { return (Refresh-ClaudeAccessToken) }
        throw "login required"
    }
    $expiresAt = [int64](Get-Number $cred.claudeAiOauth.expiresAt)
    $nowMs = [DateTimeOffset]::Now.ToUnixTimeMilliseconds()
    if ($ForceRefresh -or $expiresAt -lt ($nowMs + 60000)) {
        if ($ForceRefresh) { return (Refresh-ClaudeAccessToken) }
        throw "login required"
    }
    return $cred
}

function Get-ObjectProperty {
    param($Object, [string[]]$Names)
    if ($null -eq $Object) { return $null }
    foreach ($name in $Names) {
        try {
            if ($Object.PSObject.Properties.Name -contains $name) {
                return $Object.$name
            }
        } catch {}
    }
    return $null
}

function Get-UsagePercent {
    param($Node)
    $direct = Get-ObjectProperty $Node @("utilization", "used_percent", "usedPercent", "percent_used", "percentUsed", "usage_percent", "usagePercent", "percentage", "percent")
    if ($null -ne $direct) {
        $n = Get-Number $direct
        if ($n -gt 0 -and $n -le 1) { return $n * 100 }
        return $n
    }
    $used = Get-ObjectProperty $Node @("used", "usage", "current")
    $limit = Get-ObjectProperty $Node @("limit", "max", "quota", "total")
    if ($null -ne $used -and $null -ne $limit -and (Get-Number $limit) -gt 0) {
        return ((Get-Number $used) / (Get-Number $limit)) * 100
    }
    return $null
}

function Get-UsageReset {
    param($Node)
    $value = Get-ObjectProperty $Node @("resets_at", "resetsAt", "reset_at", "resetAt", "next_reset_at", "nextResetAt", "reset_time", "resetTime")
    return Convert-AnyResetTime $value
}

function Find-UsageNode {
    param($Object, [string]$Pattern)
    $queue = New-Object System.Collections.Queue
    $queue.Enqueue([pscustomobject]@{ Path = ""; Value = $Object })
    while ($queue.Count -gt 0) {
        $item = $queue.Dequeue()
        $value = $item.Value
        $path = $item.Path
        if ($path -match $Pattern -and $null -ne (Get-UsagePercent $value)) {
            return $value
        }
        if ($null -eq $value) { continue }
        if ($value -is [string] -or $value -is [ValueType]) { continue }
        if ($value -is [System.Collections.IEnumerable] -and -not ($value -is [string]) -and -not ($value.PSObject.Properties.Count -gt 0)) {
            $idx = 0
            foreach ($child in $value) {
                $queue.Enqueue([pscustomobject]@{ Path = "$path.$idx"; Value = $child })
                $idx++
            }
        } else {
            foreach ($prop in $value.PSObject.Properties) {
                $queue.Enqueue([pscustomobject]@{ Path = "$path.$($prop.Name)"; Value = $prop.Value })
            }
        }
    }
    return $null
}

function New-ClaudeLimit {
    param($Node)
    $percent = Get-UsagePercent $Node
    $reset = Get-UsageReset $Node
    return [pscustomobject]@{
        UsedPercent = $percent
        ResetsAt = $reset
        ResetIn = Convert-ResetDelta $reset
        ResetClock = Convert-ResetClock $reset
    }
}

function Convert-ClaudeOfficialUsage {
    param($Response)
    $currentNode = Get-ObjectProperty $Response @("five_hour", "current_session", "currentSession")
    $weeklyNode = Get-ObjectProperty $Response @("seven_day", "weekly", "all_models", "allModels")
    $sonnetNode = Get-ObjectProperty $Response @("seven_day_sonnet", "sonnet")
    if (-not $currentNode) { $currentNode = Find-UsageNode $Response "(current|session|five.?hour|five_hour)" }
    if (-not $weeklyNode) { $weeklyNode = Find-UsageNode $Response "(weekly|week|seven.?day|seven_day|all.?models|all_models)" }
    if (-not $sonnetNode) { $sonnetNode = Find-UsageNode $Response "sonnet" }
    return [pscustomobject]@{
        Current = New-ClaudeLimit $currentNode
        Weekly = New-ClaudeLimit $weeklyNode
        Sonnet = New-ClaudeLimit $sonnetNode
        Raw = $Response
        Status = if ($currentNode -or $weeklyNode -or $sonnetNode) { "ok" } else { "unparsed" }
        Error = $null
    }
}

function Get-ClaudeOfficialUsage {
    param([switch]$ForceRefresh)
    try {
        $cred = Get-ClaudeValidCredentials -ForceRefresh:($ForceRefresh -or $script:ClaudeForceRefresh)
        $headers = @{
            Authorization = "Bearer $($cred.claudeAiOauth.accessToken)"
            "User-Agent" = "Claude-Code/2.1.172"
        }
        try {
            $response = Invoke-RestMethod -Uri "https://api.anthropic.com/api/oauth/usage" -Headers $headers -Method Get
        } catch {
            if ($_.Exception.Response.StatusCode.value__ -eq 401 -and ($ForceRefresh -or $script:ClaudeForceRefresh)) {
                $cred = Refresh-ClaudeAccessToken
                $headers.Authorization = "Bearer $($cred.claudeAiOauth.accessToken)"
                $response = Invoke-RestMethod -Uri "https://api.anthropic.com/api/oauth/usage" -Headers $headers -Method Get
            } else {
                throw
            }
        }
        $script:ClaudeForceRefresh = $false
        $script:ClaudeLastError = ""
        return Convert-ClaudeOfficialUsage $response
    } catch {
        $message = $_.Exception.Message
        if ($message -match "rate_limit|429|Too Many Requests") { $message = "OAuth 429" }
        $script:ClaudeLastError = $message
        return [pscustomobject]@{
            Current = New-ClaudeLimit $null
            Weekly = New-ClaudeLimit $null
            Sonnet = New-ClaudeLimit $null
            Raw = $null
            Status = "error"
            Error = $message
        }
    }
}

function Get-ClaudeOfficialUsageCached {
    if ($script:ClaudeForceRefresh -or $null -eq $script:ClaudeOfficialCache -or (Get-Date) -ge $script:ClaudeNextFetch) {
        $fresh = Get-ClaudeOfficialUsage -ForceRefresh:$script:ClaudeForceRefresh
        if ($fresh.Status -eq "ok") {
            $script:ClaudeOfficialCache = $fresh
            $script:ClaudeNextFetch = (Get-Date).AddSeconds(60)
        } elseif ($script:ClaudeOfficialCache -and $script:ClaudeOfficialCache.Status -eq "ok") {
            $script:ClaudeNextFetch = (Get-Date).AddSeconds($script:ClaudeBackoffSeconds)
        } else {
            $script:ClaudeOfficialCache = $fresh
            $script:ClaudeNextFetch = (Get-Date).AddSeconds($script:ClaudeBackoffSeconds)
        }
    }
    return $script:ClaudeOfficialCache
}

function Invoke-GeminiBrowserUsage {
    param([string]$Command = "read")
    if (-not (Test-Path $script:GeminiUsageScript)) {
        return [pscustomobject]@{ Status = "error"; Error = "missing helper" }
    }
    $node = Get-Command node.exe -ErrorAction SilentlyContinue
    if (-not $node) { $node = Get-Command node -ErrorAction SilentlyContinue }
    if (-not $node) {
        return [pscustomobject]@{ Status = "error"; Error = "missing node" }
    }
    try {
        $output = & $node.Source $script:GeminiUsageScript $Command 2>$null
        if (-not $output) {
            return [pscustomobject]@{ Status = "error"; Error = "empty response" }
        }
        $json = ($output | Select-Object -Last 1) | ConvertFrom-Json
        return [pscustomobject]@{
            Status = $json.status
            CurrentPercent = $json.currentPercent
            WeeklyPercent = $json.weeklyPercent
            CurrentLabel = $json.currentLabel
            WeeklyLabel = $json.weeklyLabel
            ResetText = $json.resetText
            Error = $json.error
            Url = $json.url
            Title = $json.title
        }
    } catch {
        return [pscustomobject]@{ Status = "error"; Error = $_.Exception.Message }
    }
}

function Get-GeminiBrowserUsageCached {
    if ($null -eq $script:GeminiUsageCache -or (Get-Date) -ge $script:GeminiNextFetch) {
        $fresh = Invoke-GeminiBrowserUsage "read"
        if ($fresh.Status -eq "ok") {
            $script:GeminiUsageCache = $fresh
            $script:GeminiNextFetch = (Get-Date).AddSeconds(60)
        } elseif ($script:GeminiUsageCache -and $script:GeminiUsageCache.Status -eq "ok") {
            $script:GeminiNextFetch = (Get-Date).AddSeconds($script:GeminiBackoffSeconds)
        } else {
            $script:GeminiUsageCache = $fresh
            $script:GeminiNextFetch = (Get-Date).AddSeconds($script:GeminiBackoffSeconds)
        }
    }
    return $script:GeminiUsageCache
}

function New-TextBlock {
    param(
        [string]$Text,
        [double]$Size,
        [string]$Color,
        [string]$Weight = "Normal"
    )
    $block = New-Object System.Windows.Controls.TextBlock
    $block.Text = $Text
    $block.FontFamily = "Segoe UI"
    $block.FontSize = $Size
    $block.FontWeight = $Weight
    $block.Foreground = $Color
    $block.TextWrapping = "NoWrap"
    $block.TextTrimming = "CharacterEllipsis"
    return $block
}

function New-IconButton {
    param([string]$Text, [string]$Tip)
    $button = New-Object System.Windows.Controls.Button
    $button.Content = $Text
    $button.Width = 28
$button.Height = 26
    $button.Margin = "4,0,0,0"
    $button.Padding = "0"
    $button.FontFamily = "Segoe MDL2 Assets"
    $button.FontSize = 14
    $button.ToolTip = $Tip
    $button.Foreground = "#EEF5FF"
    $button.Background = "#243242"
    $button.BorderBrush = "#52677E"
    return $button
}

function New-ActionButton {
    param([string]$Text, [string]$Tip)
    $button = New-Object System.Windows.Controls.Button
    $button.Content = $Text
    $button.Width = 58
    $button.Height = 24
    $button.Margin = "12,0,0,0"
    $button.Padding = "0"
    $button.FontFamily = "Segoe UI"
    $button.FontSize = 12
    $button.ToolTip = $Tip
    $button.Foreground = "#EEF5FF"
    $button.Background = "#243242"
    $button.BorderBrush = "#52677E"
    return $button
}

function New-UsageCell {
    param(
        [double]$Tokens,
        $Percent,
        [string]$ResetText,
        [string]$DisplayText = ""
    )
    $outer = New-Object System.Windows.Controls.StackPanel
    $outer.Orientation = "Vertical"
    $outer.Margin = "0,0,18,6"

    $labelText = if ($DisplayText) { $DisplayText } else { Format-UsageRatio $Tokens $Percent }

    $label = New-TextBlock $labelText 11 "#A9BCD2"
    $label.Margin = "0,0,0,2"
    $outer.Children.Add($label) | Out-Null

    $panel = New-Object System.Windows.Controls.DockPanel
    $panel.LastChildFill = $true

    $reset = New-TextBlock $ResetText 11 "#91A5BE"
    $reset.MinWidth = 62
    $reset.TextAlignment = "Right"
    [System.Windows.Controls.DockPanel]::SetDock($reset, "Right")
    $panel.Children.Add($reset) | Out-Null

    $bar = New-Object System.Windows.Controls.ProgressBar
    $bar.Height = 7
    $bar.Minimum = 0
    $bar.Maximum = 100
    $bar.Margin = "0,7,8,0"
    $bar.Foreground = "#4B7DE8"
    $bar.Background = "#314052"
    $bar.Value = if ($null -eq $Percent) { 0 } else { [Math]::Max(0, [Math]::Min(100, [double]$Percent)) }
    $panel.Children.Add($bar) | Out-Null

    $outer.Children.Add($panel) | Out-Null
    return $outer
}

function New-PlainCell {
    param(
        [string]$Caption,
        [string]$Value
    )
    $outer = New-Object System.Windows.Controls.StackPanel
    $outer.Orientation = "Vertical"
    $outer.Margin = "0,2,18,8"
    $captionBlock = New-TextBlock $Caption 11 "#91A5BE" "SemiBold"
    $captionBlock.Margin = "0,0,0,3"
    $outer.Children.Add($captionBlock) | Out-Null
    $valueBlock = New-TextBlock $Value 12 "#A9BCD2"
    $valueBlock.Margin = "0,4,0,0"
    $outer.Children.Add($valueBlock) | Out-Null
    return $outer
}

function Add-UsageRow {
    param(
        [System.Windows.Controls.Grid]$Grid,
        [string]$Name,
        $Current,
        $Week
    )
    $row = $Grid.RowDefinitions.Count
    $Grid.RowDefinitions.Add((New-Object System.Windows.Controls.RowDefinition -Property @{ Height = "Auto" }))
    $nameBlock = New-TextBlock $Name 13 "#C7D4E6" "SemiBold"
    $nameBlock.VerticalAlignment = "Bottom"
    $nameBlock.Margin = "0,0,12,8"
    $values = @(
        $nameBlock,
        $Current,
        $Week
    )
    for ($i = 0; $i -lt $values.Count; $i++) {
        [System.Windows.Controls.Grid]::SetRow($values[$i], $row)
        [System.Windows.Controls.Grid]::SetColumn($values[$i], $i)
        $Grid.Children.Add($values[$i]) | Out-Null
    }
}

if ($Once) {
    [pscustomobject]@{
        generated_at = (Get-Date).ToString("s")
        codex = Get-CodexUsage
        claude = Get-ClaudeOfficialUsage -ForceRefresh:$false
    } | ConvertTo-Json -Depth 8
    exit 0
}

$config = Read-WidgetConfig
$script:IsLocked = [bool]$config.locked

$window = New-Object System.Windows.Window
$window.Title = "CodeQuotaWidget"
$window.Width = 650
$window.SizeToContent = "Height"
$window.WindowStyle = "None"
$window.ResizeMode = "NoResize"
$window.AllowsTransparency = $true
$window.Background = "Transparent"
$window.ShowInTaskbar = $false
$window.Topmost = [bool]$Topmost
$window.Opacity = [double]$config.opacity

$screen = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
if ($null -ne $config.left -and $null -ne $config.top) {
    $window.Left = [double]$config.left
    $window.Top = [double]$config.top
} else {
    $window.Left = $screen.Right - $window.Width - 22
    $window.Top = $screen.Top + 48
}

$border = New-Object System.Windows.Controls.Border
$border.CornerRadius = 8
$border.Padding = "14"
$border.Background = "#E018202B"
$border.BorderBrush = "#4A5E758E"
$border.BorderThickness = 1

$stack = New-Object System.Windows.Controls.StackPanel
$stack.Orientation = "Vertical"

$titleRow = New-Object System.Windows.Controls.DockPanel
$title = New-TextBlock "CodeQuotaWidget" 14 "#D5E2F2" "SemiBold"
$updated = New-TextBlock "loading" 11 "#8190A5"
$lockButton = New-IconButton $script:IconLock "Lock / unlock dragging"
$settingsButton = New-IconButton $script:IconSettings "Opacity settings"

[System.Windows.Controls.DockPanel]::SetDock($settingsButton, "Right")
[System.Windows.Controls.DockPanel]::SetDock($lockButton, "Right")
[System.Windows.Controls.DockPanel]::SetDock($updated, "Right")
$titleRow.Children.Add($settingsButton) | Out-Null
$titleRow.Children.Add($lockButton) | Out-Null
$titleRow.Children.Add($updated) | Out-Null
$titleRow.Children.Add($title) | Out-Null
$stack.Children.Add($titleRow) | Out-Null

$settingsPanel = New-Object System.Windows.Controls.StackPanel
$settingsPanel.Orientation = "Horizontal"
$settingsPanel.Margin = "0,10,0,0"
$settingsPanel.Visibility = "Collapsed"
$settingsPanel.Children.Add((New-TextBlock "Opacity" 12 "#AAB8CA")) | Out-Null
$opacitySlider = New-Object System.Windows.Controls.Slider
$opacitySlider.Width = 250
$opacitySlider.Minimum = 35
$opacitySlider.Maximum = 100
$opacitySlider.Value = [Math]::Round($window.Opacity * 100)
$opacitySlider.Margin = "12,0,0,0"
$settingsPanel.Children.Add($opacitySlider) | Out-Null
$opacityValue = New-TextBlock ("{0:N0}%" -f $opacitySlider.Value) 12 "#EAF2FF"
$opacityValue.Margin = "10,0,0,0"
$settingsPanel.Children.Add($opacityValue) | Out-Null
$loginButton = New-ActionButton "Login" "Run claude auth login, then refresh Claude usage"
$settingsPanel.Children.Add($loginButton) | Out-Null
$geminiButton = New-ActionButton "Gemini" "Open Gemini in a browser profile for login and usage scraping"
$settingsPanel.Children.Add($geminiButton) | Out-Null
$stack.Children.Add($settingsPanel) | Out-Null

$usageGrid = New-Object System.Windows.Controls.Grid
$usageGrid.Margin = "0,10,0,0"
foreach ($width in @("72", "270", "270")) {
    $usageGrid.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition -Property @{ Width = $width }))
}
$stack.Children.Add($usageGrid) | Out-Null

$border.Child = $stack
$window.Content = $border

function Set-LockState {
    param([bool]$Locked)
    $script:IsLocked = $Locked
    $lockButton.Content = if ($script:IsLocked) { $script:IconLock } else { $script:IconUnlock }
    $border.BorderBrush = if ($script:IsLocked) { "#4A5E758E" } else { "#84B7FF" }
    Save-WidgetConfig $window $window.Opacity $script:IsLocked
}

function Format-LimitPercent {
    param($Value)
    if ($null -eq $Value) { return "n/a" }
    return ("{0:N1}%" -f [double]$Value)
}

function Format-UsageRatio {
    param([double]$Tokens, $Percent)
    if ($null -eq $Percent) { return "n/a" }
    $openParen = [string][char]0xFF08
    $closeParen = [string][char]0xFF09
    $percentNumber = [double]$Percent
    $percentText = if ([Math]::Abs($percentNumber - [Math]::Round($percentNumber)) -lt 0.05) {
        "{0:N0}%" -f $percentNumber
    } else {
        "{0:N1}%" -f $percentNumber
    }
    if ($Tokens -gt 0 -and $percentNumber -gt 0) {
        $total = $Tokens * 100.0 / $percentNumber
        return ("{0}/{1} {2}{3}{4}" -f (Convert-TokenCount $Tokens), (Convert-TokenCount $total), $openParen, $percentText, $closeParen)
    }
    return ("{0:N0}/100 {1}{2}{3}" -f $percentNumber, $openParen, $percentText, $closeParen)
}

function Format-NullableValue {
    param($Value, [string]$Fallback = "n/a")
    if ($null -eq $Value) { return $Fallback }
    if ([string]::IsNullOrWhiteSpace([string]$Value)) { return $Fallback }
    return [string]$Value
}

function Update-Widget {
    $usageGrid.Children.Clear()
    $usageGrid.RowDefinitions.Clear()

    $codex = Get-CodexUsage
    $claude = Get-ClaudeOfficialUsageCached
    $gemini = Get-GeminiBrowserUsageCached

    $codexNow = New-UsageCell $codex.CurrentTokens $codex.Primary.UsedPercent $codex.Primary.ResetIn
    $codexWeek = New-UsageCell $codex.WeekTokens $codex.Secondary.UsedPercent $codex.Secondary.ResetClock
    Add-UsageRow $usageGrid "Codex" $codexNow $codexWeek

    if ($claude.Status -eq "ok") {
        $claudeNow = New-UsageCell 0 $claude.Current.UsedPercent $claude.Current.ResetIn
        $claudeWeek = New-UsageCell 0 $claude.Weekly.UsedPercent $claude.Weekly.ResetClock
        Add-UsageRow $usageGrid "Claude" $claudeNow $claudeWeek
    } else {
        $claudeNow = New-PlainCell "Claude official" $claude.Error
        $claudeWeek = New-PlainCell "Manual" "open settings"
        Add-UsageRow $usageGrid "Claude" $claudeNow $claudeWeek
    }

    if ($gemini.Status -eq "ok") {
        $geminiReset = if ($gemini.ResetText) { [string]$gemini.ResetText } else { "browser" }
        $geminiNow = New-UsageCell 0 $gemini.CurrentPercent $geminiReset $gemini.CurrentLabel
        if ($null -ne $gemini.WeeklyPercent) {
            $geminiWeek = New-UsageCell 0 $gemini.WeeklyPercent "weekly" $gemini.WeeklyLabel
        } else {
            $geminiWeek = New-PlainCell "Gemini App" "usage page"
        }
        Add-UsageRow $usageGrid "Gemini" $geminiNow $geminiWeek
    } else {
        $geminiError = if ($gemini.Error) { [string]$gemini.Error } else { "open usage" }
        if ($gemini.Status -eq "unparsed") { $geminiError = "open usage" }
        $geminiNow = New-PlainCell "Gemini browser" $geminiError
        $geminiWeek = New-PlainCell "Experimental" "settings login"
        Add-UsageRow $usageGrid "Gemini" $geminiNow $geminiWeek
    }

    $updated.Text = (Get-Date).ToString("HH:mm")
}

$border.Add_MouseLeftButtonDown({
    if (-not $script:IsLocked) {
        try { $window.DragMove() } catch {}
    }
})

$lockButton.Add_Click({
    Set-LockState (-not $script:IsLocked)
})

$settingsButton.Add_Click({
    $settingsPanel.Visibility = if ($settingsPanel.Visibility -eq "Visible") { "Collapsed" } else { "Visible" }
})

$loginButton.Add_Click({
    $updated.Text = "login"
    $loginCommand = "claude auth login; Write-Host ''; Write-Host 'Login finished. Press Enter to close this window.'; Read-Host"
    $encoded = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($loginCommand))
    Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -ArgumentList "-NoProfile -ExecutionPolicy Bypass -EncodedCommand $encoded" -Wait | Out-Null
    $script:ClaudeForceRefresh = $false
    $script:ClaudeNextFetch = [DateTime]::MinValue
    Update-Widget
})

$geminiButton.Add_Click({
    $updated.Text = "gemini"
    Invoke-GeminiBrowserUsage "login" | Out-Null
    $script:GeminiNextFetch = [DateTime]::MinValue
    Update-Widget
})

$opacitySlider.Add_ValueChanged({
    $window.Opacity = [Math]::Max(0.35, [Math]::Min(1.0, $opacitySlider.Value / 100.0))
    $opacityValue.Text = "{0:N0}%" -f $opacitySlider.Value
    Save-WidgetConfig $window $window.Opacity $script:IsLocked
})

$window.Add_LocationChanged({
    Save-WidgetConfig $window $window.Opacity $script:IsLocked
})

$window.Add_SourceInitialized({
    $helper = New-Object System.Windows.Interop.WindowInteropHelper($window)
    $hwnd = $helper.Handle
    $style = [Win32WindowTools]::GetWindowLong($hwnd, [Win32WindowTools]::GWL_EXSTYLE)
    $style = $style -bor [Win32WindowTools]::WS_EX_TOOLWINDOW
    [Win32WindowTools]::SetWindowLong($hwnd, [Win32WindowTools]::GWL_EXSTYLE, $style) | Out-Null
    if (-not $Topmost) {
        [Win32WindowTools]::SetWindowPos($hwnd, [Win32WindowTools]::HWND_BOTTOM, 0, 0, 0, 0, [Win32WindowTools]::SWP_NOMOVE -bor [Win32WindowTools]::SWP_NOSIZE -bor [Win32WindowTools]::SWP_NOACTIVATE) | Out-Null
    }
})

$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromSeconds([Math]::Max(2, $RefreshSeconds))
$timer.Add_Tick({ Update-Widget })

Set-LockState $script:IsLocked
Update-Widget
$timer.Start()
$window.ShowDialog() | Out-Null
