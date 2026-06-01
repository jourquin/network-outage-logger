# Network Outage Logger

A small cross-platform toolset for logging short or recurring network outages.

The scripts monitor both:

1. **Router / local gateway connectivity**
2. **Internet connectivity**

They can also capture a traceroute-style diagnostic report when an internet outage starts.

This helps distinguish between:

* a local Wi-Fi/Ethernet/router problem,
* an ISP or modem/WAN problem,
* a routing problem further upstream,
* or a router that simply does not respond to ping.

The tools log outages to a CSV file when they last longer than a configurable threshold, for example 10 seconds.

## Scripts

This repository contains two versions:

| Script                      | Platform           |
| --------------------------- | ------------------ |
| `network-outage-logger.sh`  | macOS and Linux    |
| `network-outage-logger.ps1` | Windows PowerShell |

## Features

* Monitors router and internet reachability separately
* Auto-detects the default gateway/router when possible
* Allows custom router targets
* Allows custom internet targets
* Logs only outages longer than a configurable threshold
* Writes results to a CSV file
* Optionally captures traceroute-style diagnostics during internet outages
* Uses `mtr` on macOS/Linux when available
* Falls back to `traceroute` on macOS/Linux
* Uses `pathping` on Windows when available
* Falls back to `tracert` on Windows
* No data collection
* MIT licensed

## Why this exists

Intermittent home internet problems can be difficult to diagnose. A connection may drop for a few seconds or minutes, then come back before the ISP or router logs show anything obvious.

This tool helps build a simple evidence log:

* when the outage started,
* when it ended,
* how long it lasted,
* whether the router was still reachable,
* whether the internet was unreachable,
* and, optionally, what the network path looked like during the outage.

That log can be useful when troubleshooting Wi-Fi, router, modem, or ISP issues.

## Status meanings

The scripts report and log the following statuses:

| Status                           | Meaning                                                                                                                                      |
| -------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------- |
| `INTERNET_DOWN_ROUTER_UP`        | The router/local gateway is reachable, but internet targets are not. This usually points to an ISP, modem, WAN, or upstream issue.           |
| `ROUTER_AND_INTERNET_DOWN`       | Neither the router nor internet targets respond. This may indicate Wi-Fi, Ethernet, router reboot, or a local network issue.                 |
| `ROUTER_UNREACHABLE_INTERNET_UP` | Internet targets respond, but the router target does not. This may happen if the router blocks ICMP/ping or if the wrong router IP was used. |
| `OK`                             | Router and internet targets are reachable. This state is not normally logged as an outage.                                                   |

## Diagnostic capture

When an internet outage starts, the scripts can capture a traceroute-style diagnostic report.

Diagnostics are triggered for:

```text
INTERNET_DOWN_ROUTER_UP
ROUTER_AND_INTERNET_DOWN
```

Diagnostics are not triggered for:

```text
ROUTER_UNREACHABLE_INTERNET_UP
```

because in that case the internet is still reachable.

Each diagnostic is saved as a separate text file. The CSV outage log includes a `diagnostic_file` column pointing to that file.

### macOS and Linux diagnostics

The Bash script supports the following diagnostic modes:

| Mode         | Behavior                                         |
| ------------ | ------------------------------------------------ |
| `auto`       | Try `mtr` first, then fall back to `traceroute`. |
| `mtr`        | Use `mtr` only.                                  |
| `traceroute` | Use `traceroute` only.                           |
| `none`       | Disable diagnostic capture.                      |

Default:

```bash
-a auto
```

The default MTR command is equivalent to:

```bash
mtr -n -r -c 5 1.1.1.1
```

Where:

* `-n` disables DNS lookups,
* `-r` enables report mode,
* `-c 5` runs 5 report cycles.

### Windows diagnostics

The PowerShell script supports the following diagnostic modes:

| Mode       | Behavior                                           |
| ---------- | -------------------------------------------------- |
| `auto`     | Try `pathping` first, then fall back to `tracert`. |
| `pathping` | Use `pathping` only.                               |
| `tracert`  | Use `tracert` only.                                |
| `none`     | Disable diagnostic capture.                        |

Default:

```powershell
-TraceTool auto
```

The default `pathping` behavior uses 5 queries per hop:

```powershell
pathping -n -q 5 -w 1000 1.1.1.1
```

The fallback `tracert` behavior is equivalent to:

```powershell
tracert -d -h 30 -w 1000 1.1.1.1
```

## CSV output

Example CSV output:

```csv
"start_time","end_time","duration_seconds","status","router_targets","internet_targets","os","diagnostic_file"
"2026-05-29 15:04:11 +0200","2026-05-29 15:05:02 +0200","51","INTERNET_DOWN_ROUTER_UP","192.168.1.1","1.1.1.1,8.8.8.8","Darwin","/Users/example/network-outage-diagnostics/diagnostic_20260529_150411_INTERNET_DOWN_ROUTER_UP_1.1.1.1.txt"
```

## macOS and Linux usage

Make the Bash script executable:

```bash
chmod +x network-outage-logger.sh
```

Run it with default settings:

```bash
./network-outage-logger.sh
```

Run it with an explicit router IP:

```bash
./network-outage-logger.sh -r 192.168.1.1
```

Run it with explicit router and internet targets:

```bash
./network-outage-logger.sh -r 192.168.1.1 -i 1.1.1.1,8.8.8.8
```

Use a different outage threshold:

```bash
./network-outage-logger.sh -t 30
```

Write the log to a specific file:

```bash
./network-outage-logger.sh -l ~/Desktop/network-outages.csv
```

Use MTR diagnostics:

```bash
./network-outage-logger.sh -a mtr -c 5
```

Use traceroute diagnostics:

```bash
./network-outage-logger.sh -a traceroute
```

Disable diagnostics:

```bash
./network-outage-logger.sh -a none
```

Choose a specific diagnostic target:

```bash
./network-outage-logger.sh -T 8.8.8.8
```

Choose a diagnostic output directory:

```bash
./network-outage-logger.sh -d ~/Desktop/network-diagnostics
```

### Bash script options

```text
-r IP[,IP...]   Router/local targets to ping.
                Default: auto-detected default gateway.

-i IP[,IP...]   Internet targets to ping.
                Default: 1.1.1.1,8.8.8.8,9.9.9.9

-t SECONDS      Minimum outage duration to log.
                Default: 10

-s SECONDS      Check interval.
                Default: 2

-w MS           Ping timeout in milliseconds.
                Default: 1000

-l FILE         CSV log file.
                Default: ~/network-outages.csv

-d DIR          Directory for diagnostic trace files.
                Default: ~/network-outage-diagnostics

-a TOOL         Diagnostic tool: auto, mtr, traceroute, none.
                Default: auto

-c COUNT        MTR report cycles.
                Default: 5

-T TARGET       Diagnostic target.
                Default: first internet target.

-H HOPS         Maximum hops for traceroute.
                Default: 30

-h              Show help.
```

## Windows usage

Run the PowerShell script with default settings:

```powershell
powershell -ExecutionPolicy Bypass -File .\network-outage-logger.ps1
```

Run it with an explicit router IP:

```powershell
powershell -ExecutionPolicy Bypass -File .\network-outage-logger.ps1 -RouterTargets 192.168.1.1
```

Run it with explicit router and internet targets:

```powershell
powershell -ExecutionPolicy Bypass -File .\network-outage-logger.ps1 `
  -RouterTargets 192.168.1.1 `
  -InternetTargets 1.1.1.1,8.8.8.8
```

Use a different outage threshold:

```powershell
powershell -ExecutionPolicy Bypass -File .\network-outage-logger.ps1 -ThresholdSeconds 30
```

Write the log to a specific file:

```powershell
powershell -ExecutionPolicy Bypass -File .\network-outage-logger.ps1 `
  -LogFile "$env:USERPROFILE\Desktop\network-outages.csv"
```

Use `pathping` diagnostics:

```powershell
powershell -ExecutionPolicy Bypass -File .\network-outage-logger.ps1 `
  -TraceTool pathping `
  -PathPingQueries 5
```

Use `tracert` diagnostics:

```powershell
powershell -ExecutionPolicy Bypass -File .\network-outage-logger.ps1 `
  -TraceTool tracert
```

Disable diagnostics:

```powershell
powershell -ExecutionPolicy Bypass -File .\network-outage-logger.ps1 `
  -TraceTool none
```

Choose a specific diagnostic target:

```powershell
powershell -ExecutionPolicy Bypass -File .\network-outage-logger.ps1 `
  -DiagnosticTarget 8.8.8.8
```

Choose a diagnostic output directory:

```powershell
powershell -ExecutionPolicy Bypass -File .\network-outage-logger.ps1 `
  -DiagnosticDirectory "$env:USERPROFILE\Desktop\network-diagnostics"
```

### PowerShell script parameters

```text
-RouterTargets         Router/local targets to ping.
                       Default: auto-detected default gateway.

-InternetTargets       Internet targets to ping.
                       Default: 1.1.1.1, 8.8.8.8, 9.9.9.9

-ThresholdSeconds      Minimum outage duration to log.
                       Default: 10

-IntervalSeconds       Check interval.
                       Default: 2

-TimeoutMilliseconds   Ping timeout in milliseconds.
                       Default: 1000

-LogFile               CSV log file.
                       Default: %USERPROFILE%\network-outages.csv

-DiagnosticDirectory   Directory for diagnostic trace files.
                       Default: %USERPROFILE%\network-outage-diagnostics

-TraceTool             Diagnostic tool: auto, pathping, tracert, none.
                       Default: auto

-DiagnosticTarget      Diagnostic target.
                       Default: first internet target.

-PathPingQueries       Number of pathping queries per hop.
                       Default: 5

-MaxHops               Maximum hops for tracert.
                       Default: 30
```

## Choosing targets

By default, the scripts try to detect the router/default gateway automatically.

Typical router IP addresses are:

```text
192.168.1.1
192.168.0.1
10.0.0.1
172.16.0.1
```

Default internet targets are:

```text
1.1.1.1
8.8.8.8
9.9.9.9
```

The scripts consider the internet reachable if at least one internet target responds.

Using IP addresses instead of domain names avoids confusing a DNS failure with a complete internet outage.

## Installing optional diagnostic tools

### macOS

The Bash script can use `mtr` if installed.

With Homebrew:

```bash
brew install mtr
```

Depending on how `mtr` is installed, it may require elevated privileges or special permissions to use raw sockets.

The script does not automatically call `sudo`. If `mtr` fails, the failure is written to the diagnostic file and the script falls back to `traceroute` when using `-a auto`.

### Linux

Install `mtr` with your package manager.

Debian/Ubuntu:

```bash
sudo apt install mtr traceroute
```

Fedora:

```bash
sudo dnf install mtr traceroute
```

Arch Linux:

```bash
sudo pacman -S mtr traceroute
```

Depending on distribution and package configuration, `mtr` may already have the required permissions, or it may require elevated privileges.

### Windows

No additional tool is required for the default Windows script.

It uses native Windows tools:

* `pathping`
* `tracert`

`pathping` gives more useful loss and latency information, but it takes longer than `tracert`.

## Notes and limitations

These scripts use ICMP-based checks. Some routers, firewalls, or networks may block ICMP traffic.

If your router blocks ping, the script may report:

```text
ROUTER_UNREACHABLE_INTERNET_UP
```

even though the router is working normally.

In that case, use another stable local device as the router/local target, such as:

* a NAS,
* a managed switch,
* a home server,
* another always-on LAN device.

Traceroute-style diagnostics can be incomplete during a real outage. That is expected. Even a failed or partial diagnostic can be useful, because it shows where packets stopped getting replies at the time of the outage.

The scripts are intended for simple home or small-office diagnostics. They are not a full network monitoring system.


## License

This project is licensed under the MIT License.

See the `LICENSE` file for details.

## Disclaimer

This tool is provided as-is. It is intended to help diagnose intermittent network outages, but it cannot identify every possible cause of a connectivity problem.

Use the logs as supporting evidence when troubleshooting your local network, router, modem, or ISP connection.
