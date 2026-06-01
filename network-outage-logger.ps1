param(
    [string[]]$RouterTargets = @(),
    [string[]]$InternetTargets = @("1.1.1.1", "8.8.8.8", "9.9.9.9"),
    [int]$ThresholdSeconds = 10,
    [int]$IntervalSeconds = 2,
    [int]$TimeoutMilliseconds = 1000,
    [string]$LogFile = "$env:USERPROFILE\network-outages.csv",

    [string]$DiagnosticDirectory = "$env:USERPROFILE\network-outage-diagnostics",
    [ValidateSet("auto", "pathping", "tracert", "none")]
    [string]$TraceTool = "auto",
    [string]$DiagnosticTarget = "",
    [int]$PathPingQueries = 5,
    [int]$MaxHops = 30
)

# network-outage-logger.ps1
#
# Windows PowerShell script to monitor:
#   1. Router/local gateway reachability
#   2. Internet reachability
#
# Optional diagnostics:
#   - On internet outage, runs pathping if available.
#   - Falls back to tracert if pathping is unavailable or fails.
#   - Diagnostic output is saved to a separate text file.
#
# Examples:
#   .\network-outage-logger.ps1
#   .\network-outage-logger.ps1 -RouterTargets 192.168.1.1
#   .\network-outage-logger.ps1 -InternetTargets 1.1.1.1,8.8.8.8
#   .\network-outage-logger.ps1 -TraceTool pathping -PathPingQueries 5
#   .\network-outage-logger.ps1 -TraceTool tracert
#   .\network-outage-logger.ps1 -TraceTool none

function Convert-ToTargetList {
    param(
        [string[]]$InputTargets
    )

    $list = @()

    foreach ($entry in $InputTargets) {
        if ([string]::IsNullOrWhiteSpace($entry)) {
            continue
        }

        foreach ($part in ($entry -split ",")) {
            $target = $part.Trim()

            if (-not [string]::IsNullOrWhiteSpace($target)) {
                $list += $target
            }
        }
    }

    return $list
}

function Get-DefaultGateway {
    try {
        $route = Get-NetRoute -DestinationPrefix "0.0.0.0/0" -ErrorAction Stop |
            Where-Object {
                $_.NextHop -and
                $_.NextHop -ne "0.0.0.0"
            } |
            Sort-Object RouteMetric, InterfaceMetric |
            Select-Object -First 1

        if ($route) {
            return $route.NextHop
        }
    }
    catch {
        # Fall back to route.exe below.
    }

    try {
        $routeOutput = route print 0.0.0.0 2>$null

        foreach ($line in $routeOutput) {
            if ($line -match '^\s*0\.0\.0\.0\s+0\.0\.0\.0\s+(\S+)\s+') {
                return $matches[1]
            }
        }
    }
    catch {
        return $null
    }

    return $null
}

function Test-OneTarget {
    param(
        [string]$Target,
        [int]$TimeoutMilliseconds
    )

    $pinger = $null

    try {
        $pinger = New-Object System.Net.NetworkInformation.Ping
        $reply = $pinger.Send($Target, $TimeoutMilliseconds)

        return $reply.Status -eq [System.Net.NetworkInformation.IPStatus]::Success
    }
    catch {
        return $false
    }
    finally {
        if ($pinger -ne $null) {
            $pinger.Dispose()
        }
    }
}

function Test-AnyTarget {
    param(
        [string[]]$Targets,
        [int]$TimeoutMilliseconds
    )

    foreach ($target in $Targets) {
        if (Test-OneTarget -Target $target -TimeoutMilliseconds $TimeoutMilliseconds) {
            return $true
        }
    }

    return $false
}

function Get-NetworkStatus {
    param(
        [string[]]$RouterTargets,
        [string[]]$InternetTargets,
        [int]$TimeoutMilliseconds
    )

    $routerOnline = Test-AnyTarget -Targets $RouterTargets -TimeoutMilliseconds $TimeoutMilliseconds
    $internetOnline = Test-AnyTarget -Targets $InternetTargets -TimeoutMilliseconds $TimeoutMilliseconds

    if ($routerOnline -and $internetOnline) {
        return "OK"
    }
    elseif ($routerOnline -and -not $internetOnline) {
        return "INTERNET_DOWN_ROUTER_UP"
    }
    elseif (-not $routerOnline -and $internetOnline) {
        return "ROUTER_UNREACHABLE_INTERNET_UP"
    }
    else {
        return "ROUTER_AND_INTERNET_DOWN"
    }
}

function Test-ShouldRunDiagnostic {
    param(
        [string]$Status
    )

    return $Status -in @("INTERNET_DOWN_ROUTER_UP", "ROUTER_AND_INTERNET_DOWN")
}

function Get-SafeFilePart {
    param(
        [string]$Value
    )

    return ($Value -replace '[^A-Za-z0-9_.-]', '_')
}

function Invoke-CommandToFile {
    param(
        [string]$Command,
        [string[]]$Arguments,
        [string]$OutputFile
    )

    Add-Content -Path $OutputFile -Value ""
    Add-Content -Path $OutputFile -Value ("Command: {0} {1}" -f $Command, ($Arguments -join " "))
    Add-Content -Path $OutputFile -Value ""

    try {
        & $Command @Arguments 2>&1 | Out-File -FilePath $OutputFile -Append -Encoding utf8
        return $LASTEXITCODE
    }
    catch {
        Add-Content -Path $OutputFile -Value "Command failed: $($_.Exception.Message)"
        return 1
    }
}

function Invoke-PathPingDiagnostic {
    param(
        [string]$Target,
        [string]$OutputFile,
        [int]$PathPingQueries,
        [int]$TimeoutMilliseconds
    )

    $cmd = Get-Command pathping.exe -ErrorAction SilentlyContinue

    if (-not $cmd) {
        return 127
    }

    $args = @(
        "-n",
        "-q", "$PathPingQueries",
        "-w", "$TimeoutMilliseconds",
        "$Target"
    )

    return Invoke-CommandToFile -Command $cmd.Source -Arguments $args -OutputFile $OutputFile
}

function Invoke-TracertDiagnostic {
    param(
        [string]$Target,
        [string]$OutputFile,
        [int]$MaxHops,
        [int]$TimeoutMilliseconds
    )

    $cmd = Get-Command tracert.exe -ErrorAction SilentlyContinue

    if (-not $cmd) {
        return 127
    }

    $args = @(
        "-d",
        "-h", "$MaxHops",
        "-w", "$TimeoutMilliseconds",
        "$Target"
    )

    return Invoke-CommandToFile -Command $cmd.Source -Arguments $args -OutputFile $OutputFile
}

function Invoke-InternetDiagnostic {
    param(
        [string]$Status,
        [string]$Target,
        [string[]]$RouterTargets,
        [string[]]$InternetTargets,
        [string]$DiagnosticDirectory,
        [string]$TraceTool,
        [int]$PathPingQueries,
        [int]$TimeoutMilliseconds,
        [int]$MaxHops
    )

    if ($TraceTool -eq "none") {
        return ""
    }

    if ([string]::IsNullOrWhiteSpace($Target)) {
        return ""
    }

    if (-not (Test-Path $DiagnosticDirectory)) {
        New-Item -ItemType Directory -Path $DiagnosticDirectory | Out-Null
    }

    $stamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $safeStatus = Get-SafeFilePart -Value $Status
    $safeTarget = Get-SafeFilePart -Value $Target

    $outputFile = Join-Path $DiagnosticDirectory "diagnostic_${stamp}_${safeStatus}_${safeTarget}.txt"

    @(
        "Network outage diagnostic",
        "==========================",
        "",
        "Start time:        $((Get-Date).ToString('yyyy-MM-dd HH:mm:ss zzz'))",
        "OS:                Windows",
        "Outage status:     $Status",
        "Diagnostic target: $Target",
        "Router targets:    $($RouterTargets -join ',')",
        "Internet targets:  $($InternetTargets -join ',')",
        "Diagnostic tool:   $TraceTool",
        "PathPing queries:  $PathPingQueries",
        "Max hops:          $MaxHops",
        ""
    ) | Out-File -FilePath $outputFile -Encoding utf8

    $exitCode = 0

    switch ($TraceTool) {
        "pathping" {
            $exitCode = Invoke-PathPingDiagnostic `
                -Target $Target `
                -OutputFile $outputFile `
                -PathPingQueries $PathPingQueries `
                -TimeoutMilliseconds $TimeoutMilliseconds
        }

        "tracert" {
            $exitCode = Invoke-TracertDiagnostic `
                -Target $Target `
                -OutputFile $outputFile `
                -MaxHops $MaxHops `
                -TimeoutMilliseconds $TimeoutMilliseconds
        }

        "auto" {
            $exitCode = Invoke-PathPingDiagnostic `
                -Target $Target `
                -OutputFile $outputFile `
                -PathPingQueries $PathPingQueries `
                -TimeoutMilliseconds $TimeoutMilliseconds

            if ($exitCode -ne 0) {
                Add-Content -Path $outputFile -Value ""
                Add-Content -Path $outputFile -Value "pathping failed or is unavailable, falling back to tracert."
                Add-Content -Path $outputFile -Value "pathping exit code: $exitCode"
                Add-Content -Path $outputFile -Value ""

                $exitCode = Invoke-TracertDiagnostic `
                    -Target $Target `
                    -OutputFile $outputFile `
                    -MaxHops $MaxHops `
                    -TimeoutMilliseconds $TimeoutMilliseconds
            }
        }
    }

    Add-Content -Path $outputFile -Value ""
    Add-Content -Path $outputFile -Value "Diagnostic finished: $((Get-Date).ToString('yyyy-MM-dd HH:mm:ss zzz'))"
    Add-Content -Path $outputFile -Value "Final diagnostic exit code: $exitCode"

    return $outputFile
}

function Write-OutageLog {
    param(
        [string]$StartTime,
        [string]$EndTime,
        [int]$DurationSeconds,
        [string]$Status,
        [string[]]$RouterTargets,
        [string[]]$InternetTargets,
        [string]$LogFile,
        [string]$DiagnosticFile
    )

    $entry = [PSCustomObject]@{
        start_time       = $StartTime
        end_time         = $EndTime
        duration_seconds = $DurationSeconds
        status           = $Status
        router_targets   = ($RouterTargets -join ",")
        internet_targets = ($InternetTargets -join ",")
        os               = "Windows"
        diagnostic_file  = $DiagnosticFile
    }

    $directory = Split-Path -Parent $LogFile

    if (-not [string]::IsNullOrWhiteSpace($directory)) {
        if (-not (Test-Path $directory)) {
            New-Item -ItemType Directory -Path $directory | Out-Null
        }
    }

    if (Test-Path $LogFile) {
        $entry | Export-Csv -Path $LogFile -Append -NoTypeInformation
    }
    else {
        $entry | Export-Csv -Path $LogFile -NoTypeInformation
    }
}

$RouterTargets = Convert-ToTargetList -InputTargets $RouterTargets
$InternetTargets = Convert-ToTargetList -InputTargets $InternetTargets

if ($RouterTargets.Count -eq 0) {
    $gateway = Get-DefaultGateway

    if (-not [string]::IsNullOrWhiteSpace($gateway)) {
        $RouterTargets = @($gateway)
    }
}

if ($RouterTargets.Count -eq 0) {
    Write-Host "Error: could not auto-detect the default gateway/router." -ForegroundColor Red
    Write-Host "Please specify it manually, for example:"
    Write-Host "  .\network-outage-logger.ps1 -RouterTargets 192.168.1.1"
    exit 1
}

if ($InternetTargets.Count -eq 0) {
    Write-Host "Error: no internet targets specified." -ForegroundColor Red
    exit 1
}

if ([string]::IsNullOrWhiteSpace($DiagnosticTarget)) {
    $DiagnosticTarget = $InternetTargets[0]
}

Write-Host "Monitoring network connection..."
Write-Host "Router target(s):    $($RouterTargets -join ', ')"
Write-Host "Internet target(s):  $($InternetTargets -join ', ')"
Write-Host "Threshold:           $ThresholdSeconds seconds"
Write-Host "Interval:            $IntervalSeconds seconds"
Write-Host "Ping timeout:        $TimeoutMilliseconds ms"
Write-Host "Log file:            $LogFile"
Write-Host "Diagnostic tool:     $TraceTool"
Write-Host "Diagnostic target:   $DiagnosticTarget"
Write-Host "Diagnostic dir:      $DiagnosticDirectory"
Write-Host "PathPing queries:    $PathPingQueries"
Write-Host "Traceroute max hops: $MaxHops"
Write-Host ""
Write-Host "Press Ctrl+C to stop."
Write-Host ""

$activeStatus = "OK"
$activeStartTime = $null
$activeStartEpoch = $null
$activeDiagnosticFile = ""

while ($true) {
    $currentStatus = Get-NetworkStatus `
        -RouterTargets $RouterTargets `
        -InternetTargets $InternetTargets `
        -TimeoutMilliseconds $TimeoutMilliseconds

    if ($currentStatus -ne $activeStatus) {

        if ($activeStatus -ne "OK") {
            $end = Get-Date
            $duration = [int]($end - $activeStartEpoch).TotalSeconds

            if ($duration -ge $ThresholdSeconds) {
                Write-OutageLog `
                    -StartTime $activeStartTime.ToString("yyyy-MM-dd HH:mm:ss zzz") `
                    -EndTime $end.ToString("yyyy-MM-dd HH:mm:ss zzz") `
                    -DurationSeconds $duration `
                    -Status $activeStatus `
                    -RouterTargets $RouterTargets `
                    -InternetTargets $InternetTargets `
                    -LogFile $LogFile `
                    -DiagnosticFile $activeDiagnosticFile

                Write-Host "Logged outage: $activeStatus, $duration seconds"

                if (-not [string]::IsNullOrWhiteSpace($activeDiagnosticFile)) {
                    Write-Host "Diagnostic file: $activeDiagnosticFile"
                }
            }
            else {
                Write-Host "Ignored brief event: $activeStatus, $duration seconds"
            }
        }

        if ($currentStatus -ne "OK") {
            $activeStartEpoch = Get-Date
            $activeStartTime = $activeStartEpoch
            $activeDiagnosticFile = ""

            Write-Host "Detected issue: $currentStatus at $($activeStartTime.ToString('yyyy-MM-dd HH:mm:ss zzz'))"

            if (Test-ShouldRunDiagnostic -Status $currentStatus) {
                $activeDiagnosticFile = Invoke-InternetDiagnostic `
                    -Status $currentStatus `
                    -Target $DiagnosticTarget `
                    -RouterTargets $RouterTargets `
                    -InternetTargets $InternetTargets `
                    -DiagnosticDirectory $DiagnosticDirectory `
                    -TraceTool $TraceTool `
                    -PathPingQueries $PathPingQueries `
                    -TimeoutMilliseconds $TimeoutMilliseconds `
                    -MaxHops $MaxHops

                if (-not [string]::IsNullOrWhiteSpace($activeDiagnosticFile)) {
                    Write-Host "Diagnostic captured: $activeDiagnosticFile"
                }
            }
        }
        else {
            $activeDiagnosticFile = ""
            Write-Host "Connection restored at $((Get-Date).ToString('yyyy-MM-dd HH:mm:ss zzz'))"
        }

        $activeStatus = $currentStatus
    }

    Start-Sleep -Seconds $IntervalSeconds
}
