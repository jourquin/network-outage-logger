#!/usr/bin/env bash

# network-outage-logger.sh
#
# Monitors both:
#   1. Router / local gateway reachability
#   2. Internet reachability
#
# Compatible with:
#   - macOS
#   - Linux
#
# Optional diagnostics:
#   - On internet outage, runs mtr if available.
#   - Falls back to traceroute if mtr is unavailable or fails.
#   - Diagnostic output is saved to a separate text file.
#
# Usage examples:
#   ./network-outage-logger.sh
#   ./network-outage-logger.sh -r 192.168.1.1
#   ./network-outage-logger.sh -i 1.1.1.1,8.8.8.8
#   ./network-outage-logger.sh -r 192.168.1.1 -i 1.1.1.1,8.8.8.8 -t 10
#   ./network-outage-logger.sh -a mtr -c 5
#   ./network-outage-logger.sh -a traceroute
#   ./network-outage-logger.sh -a none

LOGFILE="$HOME/network-outages.csv"
DIAG_DIR="$HOME/network-outage-diagnostics"

THRESHOLD=10
INTERVAL=2
PING_TIMEOUT_MS=1000

DEFAULT_INTERNET_TARGETS="1.1.1.1,8.8.8.8,9.9.9.9"

TRACE_TOOL="auto"       # auto, mtr, traceroute, none
MTR_CYCLES=5
MAX_HOPS=30
DIAGNOSTIC_TARGET=""

OS_NAME="$(uname -s)"
PING_CMD="$(command -v ping 2>/dev/null)"

trim() {
  echo "$1" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
}

timestamp() {
  date "+%Y-%m-%d %H:%M:%S %z"
}

file_timestamp() {
  date "+%Y%m%d_%H%M%S"
}

epoch() {
  date "+%s"
}

csv_escape() {
  local value="$1"
  value="${value//\"/\"\"}"
  printf '"%s"' "$value"
}

find_command() {
  local name="$1"
  local found=""

  found="$(command -v "$name" 2>/dev/null)"
  if [ -n "$found" ]; then
    echo "$found"
    return 0
  fi

  for candidate in \
    "/opt/homebrew/sbin/$name" \
    "/opt/homebrew/bin/$name" \
    "/usr/local/sbin/$name" \
    "/usr/local/bin/$name" \
    "/usr/sbin/$name" \
    "/usr/bin/$name" \
    "/sbin/$name" \
    "/bin/$name"
  do
    if [ -x "$candidate" ]; then
      echo "$candidate"
      return 0
    fi
  done

  return 1
}

first_csv_value() {
  local csv="$1"
  local old_ifs="$IFS"
  local first=""

  IFS=','
  set -- $csv
  IFS="$old_ifs"

  first="$(trim "$1")"
  echo "$first"
}

detect_gateway() {
  local gateway=""

  case "$OS_NAME" in
    Darwin)
      gateway="$(route -n get default 2>/dev/null | awk '/gateway:/ { print $2; exit }')"

      if [ -z "$gateway" ]; then
        gateway="$(netstat -rn 2>/dev/null | awk '$1 == "default" { print $2; exit }')"
      fi
      ;;

    Linux)
      if command -v ip >/dev/null 2>&1; then
        gateway="$(ip -4 route show default 2>/dev/null | awk '{ print $3; exit }')"
      fi

      if [ -z "$gateway" ] && command -v route >/dev/null 2>&1; then
        gateway="$(route -n 2>/dev/null | awk '$1 == "0.0.0.0" { print $2; exit }')"
      fi
      ;;

    *)
      gateway=""
      ;;
  esac

  echo "$gateway"
}

usage() {
  cat <<EOF
Usage: $0 [options]

Connectivity options:
  -r IP[,IP...]   Router/local targets to ping.
                  Default: auto-detected default gateway.

  -i IP[,IP...]   Internet targets to ping.
                  Default: $DEFAULT_INTERNET_TARGETS

  -t SECONDS      Minimum outage duration to log.
                  Default: $THRESHOLD

  -s SECONDS      Check interval.
                  Default: $INTERVAL

  -w MS           Ping timeout in milliseconds.
                  Default: $PING_TIMEOUT_MS

  -l FILE         CSV log file.
                  Default: $LOGFILE

Diagnostic options:
  -d DIR          Directory for diagnostic trace files.
                  Default: $DIAG_DIR

  -a TOOL         Diagnostic tool: auto, mtr, traceroute, none.
                  Default: $TRACE_TOOL

  -c COUNT        MTR report cycles.
                  Default: $MTR_CYCLES

  -T TARGET       Diagnostic target.
                  Default: first internet target.

  -H HOPS         Maximum hops for traceroute.
                  Default: $MAX_HOPS

  -h              Show this help.

Examples:
  $0
  $0 -r 192.168.1.1
  $0 -r 192.168.1.1 -i 1.1.1.1,8.8.8.8
  $0 -a mtr -c 5
  $0 -a traceroute
  $0 -a none
EOF
}

ROUTER_TARGETS="$(detect_gateway)"
INTERNET_TARGETS="$DEFAULT_INTERNET_TARGETS"

while getopts ":r:i:t:s:w:l:d:a:c:T:H:h" opt; do
  case "$opt" in
    r) ROUTER_TARGETS="$OPTARG" ;;
    i) INTERNET_TARGETS="$OPTARG" ;;
    t) THRESHOLD="$OPTARG" ;;
    s) INTERVAL="$OPTARG" ;;
    w) PING_TIMEOUT_MS="$OPTARG" ;;
    l) LOGFILE="$OPTARG" ;;
    d) DIAG_DIR="$OPTARG" ;;
    a) TRACE_TOOL="$OPTARG" ;;
    c) MTR_CYCLES="$OPTARG" ;;
    T) DIAGNOSTIC_TARGET="$OPTARG" ;;
    H) MAX_HOPS="$OPTARG" ;;
    h)
      usage
      exit 0
      ;;
    \?)
      echo "Unknown option: -$OPTARG" >&2
      usage
      exit 1
      ;;
    :)
      echo "Option -$OPTARG requires an argument." >&2
      usage
      exit 1
      ;;
  esac
done

case "$TRACE_TOOL" in
  auto|mtr|traceroute|none)
    ;;
  *)
    echo "Error: invalid diagnostic tool '$TRACE_TOOL'." >&2
    echo "Valid values are: auto, mtr, traceroute, none" >&2
    exit 1
    ;;
esac

if [ -z "$PING_CMD" ]; then
  echo "Error: ping command not found." >&2
  exit 1
fi

if [ -z "$ROUTER_TARGETS" ]; then
  echo "Error: could not auto-detect router/default gateway." >&2
  echo "Please pass one manually, for example:" >&2
  echo "  $0 -r 192.168.1.1" >&2
  exit 1
fi

if [ -z "$DIAGNOSTIC_TARGET" ]; then
  DIAGNOSTIC_TARGET="$(first_csv_value "$INTERNET_TARGETS")"
fi

ping_one() {
  local target="$1"

  case "$OS_NAME" in
    Darwin)
      # macOS/BSD ping: -W is in milliseconds.
      "$PING_CMD" -c 1 -W "$PING_TIMEOUT_MS" "$target" >/dev/null 2>&1
      ;;

    Linux)
      # Linux iputils ping: -W is in seconds.
      local timeout_seconds
      timeout_seconds=$(( (PING_TIMEOUT_MS + 999) / 1000 ))

      if [ "$timeout_seconds" -lt 1 ]; then
        timeout_seconds=1
      fi

      "$PING_CMD" -c 1 -W "$timeout_seconds" "$target" >/dev/null 2>&1
      ;;

    *)
      "$PING_CMD" -c 1 "$target" >/dev/null 2>&1
      ;;
  esac
}

any_target_online() {
  local targets_csv="$1"
  local old_ifs="$IFS"
  local target

  IFS=','
  for target in $targets_csv; do
    IFS="$old_ifs"

    target="$(trim "$target")"

    if [ -n "$target" ]; then
      if ping_one "$target"; then
        return 0
      fi
    fi

    IFS=','
  done

  IFS="$old_ifs"
  return 1
}

get_status() {
  local router_online=0
  local internet_online=0

  if any_target_online "$ROUTER_TARGETS"; then
    router_online=1
  fi

  if any_target_online "$INTERNET_TARGETS"; then
    internet_online=1
  fi

  if [ "$router_online" -eq 1 ] && [ "$internet_online" -eq 1 ]; then
    echo "OK"
  elif [ "$router_online" -eq 1 ] && [ "$internet_online" -eq 0 ]; then
    echo "INTERNET_DOWN_ROUTER_UP"
  elif [ "$router_online" -eq 0 ] && [ "$internet_online" -eq 1 ]; then
    echo "ROUTER_UNREACHABLE_INTERNET_UP"
  else
    echo "ROUTER_AND_INTERNET_DOWN"
  fi
}

should_run_diagnostic() {
  local status="$1"

  case "$status" in
    INTERNET_DOWN_ROUTER_UP|ROUTER_AND_INTERNET_DOWN)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

run_mtr_diagnostic() {
  local target="$1"
  local outfile="$2"
  local mtr_cmd=""

  mtr_cmd="$(find_command mtr)"
  if [ -z "$mtr_cmd" ]; then
    return 127
  fi

  {
    echo "Command: $mtr_cmd -n -r -c $MTR_CYCLES $target"
    echo
  } >> "$outfile"

  "$mtr_cmd" -n -r -c "$MTR_CYCLES" "$target" >> "$outfile" 2>&1
  return $?
}

run_traceroute_diagnostic() {
  local target="$1"
  local outfile="$2"
  local traceroute_cmd=""
  local timeout_seconds

  traceroute_cmd="$(find_command traceroute)"
  if [ -z "$traceroute_cmd" ]; then
    return 127
  fi

  timeout_seconds=$(( (PING_TIMEOUT_MS + 999) / 1000 ))
  if [ "$timeout_seconds" -lt 1 ]; then
    timeout_seconds=1
  fi

  {
    echo "Command: $traceroute_cmd -n -m $MAX_HOPS -w $timeout_seconds $target"
    echo
  } >> "$outfile"

  "$traceroute_cmd" -n -m "$MAX_HOPS" -w "$timeout_seconds" "$target" >> "$outfile" 2>&1
  return $?
}

run_diagnostic() {
  local status="$1"
  local target="$DIAGNOSTIC_TARGET"
  local outfile=""
  local safe_status=""
  local rc=0

  if [ "$TRACE_TOOL" = "none" ]; then
    echo ""
    return 0
  fi

  if [ -z "$target" ]; then
    echo ""
    return 0
  fi

  mkdir -p "$DIAG_DIR"

  safe_status="$(echo "$status" | sed 's/[^A-Za-z0-9_.-]/_/g')"
  outfile="$DIAG_DIR/diagnostic_$(file_timestamp)_${safe_status}_${target}.txt"

  {
    echo "Network outage diagnostic"
    echo "=========================="
    echo
    echo "Start time:        $(timestamp)"
    echo "OS:                $OS_NAME"
    echo "Outage status:     $status"
    echo "Diagnostic target: $target"
    echo "Router targets:    $ROUTER_TARGETS"
    echo "Internet targets:  $INTERNET_TARGETS"
    echo "Diagnostic tool:   $TRACE_TOOL"
    echo
  } > "$outfile"

  case "$TRACE_TOOL" in
    mtr)
      run_mtr_diagnostic "$target" "$outfile"
      rc=$?
      ;;

    traceroute)
      run_traceroute_diagnostic "$target" "$outfile"
      rc=$?
      ;;

    auto)
      run_mtr_diagnostic "$target" "$outfile"
      rc=$?

      if [ "$rc" -ne 0 ]; then
        {
          echo
          echo "mtr failed or is unavailable, falling back to traceroute."
          echo "mtr exit code: $rc"
          echo
        } >> "$outfile"

        run_traceroute_diagnostic "$target" "$outfile"
        rc=$?
      fi
      ;;
  esac

  {
    echo
    echo "Diagnostic finished: $(timestamp)"
    echo "Final diagnostic exit code: $rc"
  } >> "$outfile"

  echo "$outfile"
  return 0
}

log_outage() {
  local start_time="$1"
  local end_time="$2"
  local duration="$3"
  local status="$4"
  local diagnostic_file="$5"

  {
    csv_escape "$start_time"
    printf ','
    csv_escape "$end_time"
    printf ','
    csv_escape "$duration"
    printf ','
    csv_escape "$status"
    printf ','
    csv_escape "$ROUTER_TARGETS"
    printf ','
    csv_escape "$INTERNET_TARGETS"
    printf ','
    csv_escape "$OS_NAME"
    printf ','
    csv_escape "$diagnostic_file"
    printf '\n'
  } >> "$LOGFILE"
}

mkdir -p "$(dirname "$LOGFILE")"

if [ ! -f "$LOGFILE" ]; then
  echo '"start_time","end_time","duration_seconds","status","router_targets","internet_targets","os","diagnostic_file"' > "$LOGFILE"
fi

echo "Monitoring network connection..."
echo "Operating system:    $OS_NAME"
echo "Router target(s):    $ROUTER_TARGETS"
echo "Internet target(s):  $INTERNET_TARGETS"
echo "Threshold:           ${THRESHOLD}s"
echo "Interval:            ${INTERVAL}s"
echo "Ping timeout:        ${PING_TIMEOUT_MS}ms"
echo "Log file:            $LOGFILE"
echo "Diagnostic tool:     $TRACE_TOOL"
echo "Diagnostic target:   $DIAGNOSTIC_TARGET"
echo "Diagnostic dir:      $DIAG_DIR"
echo "MTR cycles:          $MTR_CYCLES"
echo "Traceroute max hops: $MAX_HOPS"
echo
echo "Press Ctrl+C to stop."
echo

active_status="OK"
active_start_epoch=""
active_start_time=""
active_diagnostic_file=""

while true; do
  current_status="$(get_status)"

  if [ "$current_status" != "$active_status" ]; then

    if [ "$active_status" != "OK" ]; then
      end_epoch="$(epoch)"
      end_time="$(timestamp)"
      duration=$((end_epoch - active_start_epoch))

      if [ "$duration" -ge "$THRESHOLD" ]; then
        log_outage "$active_start_time" "$end_time" "$duration" "$active_status" "$active_diagnostic_file"
        echo "Logged outage: $active_status, ${duration}s"
        if [ -n "$active_diagnostic_file" ]; then
          echo "Diagnostic file: $active_diagnostic_file"
        fi
      else
        echo "Ignored brief event: $active_status, ${duration}s"
      fi
    fi

    if [ "$current_status" != "OK" ]; then
      active_start_epoch="$(epoch)"
      active_start_time="$(timestamp)"
      active_diagnostic_file=""

      echo "Detected issue: $current_status at $active_start_time"

      if should_run_diagnostic "$current_status"; then
        active_diagnostic_file="$(run_diagnostic "$current_status")"

        if [ -n "$active_diagnostic_file" ]; then
          echo "Diagnostic captured: $active_diagnostic_file"
        fi
      fi
    else
      active_diagnostic_file=""
      echo "Connection restored at $(timestamp)"
    fi

    active_status="$current_status"
  fi

  sleep "$INTERVAL"
done
