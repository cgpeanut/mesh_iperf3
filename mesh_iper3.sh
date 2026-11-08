#!/usr/bin/env bash
#
# mesh_iperf3.sh — Bidirectional full-mesh iperf3 benchmark → Prometheus/Grafana
#
#   * Tests EVERY ordered pair (A->B and B->A) so asymmetric routing/ARP/NIC
#     issues are visible. N nodes => N*(N-1) tests per protocol.
#   * Every node is resolved to an IP address; the test uses the IP, never a
#     hostname, so DNS can't silently skew or fail a run.
#   * TCP and UDP (UDP adds jitter/loss). -R pulls the reverse direction from
#     the SAME connection pair as an extra sanity check on top of A<->B roleswap.
#   * Output is JSON (-J), parsed with jq, written to:
#       - node_exporter textfile collector  (*.prom, atomic rename)
#       - append-only structured log (.jsonl, for Loki/CloudWatch)
#       - CSV (for ad-hoc analysis / pandas)
#   * Safe: per-port servers, PID files, flock, timeouts, retries, EXIT trap.
#
# Usage:  ./mesh_iperf3.sh [options]
#         --tcp-only | --udp-only | --dur=10 | --par=4 | --nodes="a b c"
# Exit:   0 ok | 2 config error | 3 missing dep | 4 unreachable node | 5 test failure
#
set -Eeuo pipefail

# ───────────────────────────── CONFIG (env-overridable) ─────────────────────────────
SCRIPT_NAME="${0##*/}"
CONFIG_FILE="${IPERF_MESH_CONFIG:-/etc/iperf-mesh/mesh.conf}"   # sourced if present
[[ -r "$CONFIG_FILE" ]] && { # shellcheck disable=SC1090
  set -a; source "$CONFIG_FILE"; set +a; }

# name|ip pairs. Leave ip empty to auto-resolve at runtime.
NODES=(
  "qubit|1192.168.8.73"
  "manager|192.168.8.10"
  "agent1|192.168.8.11"
  "agent2|192.168.8.12"
  "agent3|192.168.8.13"
  "agent4|192.168.8.14"
  "agent5|192.168.8.15"
  "agent6|192.168.8.16"
  "agent7|192.168.8.17"
  "agent8|192.168.8.18"
)

: "${SSH_USER:=root}"                 # key-based auth only, no password prompts
: "${SSH_OPTS=-o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new -o ServerAliveInterval=5}"
: "${IPERF_BIN:=iperf3}"
: "${DURATION:=10}"                   # seconds per test
: "${PARALLEL_STREAMS:=4}"            # -P
: "${PROTOCOLS:=tcp udp}"             # "tcp", "udp", or "tcp udp"
: "${UDP_BITRATE:=0}"                 # 0 = iperf3 default (1 Mbit!) — see note below
: "${PORT_BASE:=5201}"                # one port per destination node
: "${REVERSE_TESTS:=1}"               # also run -R on each pair (cheap extra signal)
: "${SSH_PARALLEL:=4}"                # concurrent ssh workers
: "${MAX_RETRIES:=2}"                 # retry a failed pair once or twice
: "${METRIC_DIR:=/var/lib/node_exporter/textfile_collector}"
: "${LOG_DIR:=/var/log/iperf-mesh}"
: "${PROM_JOB_LABEL:=iperf_mesh}"
: "${SITE:=dc1}"

# ───────────────────────────── BOOTSTRAP ─────────────────────────────
mkdir -p "$LOG_DIR"
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
JSONL_LOG="$LOG_DIR/results-$RUN_ID.jsonl"
CSV_LOG="$LOG_DIR/results.csv"
RUN_LOG="$LOG_DIR/run-$RUN_ID.log"
LOCK_FILE="/run/iperf-mesh.lock"
PROM_TMP="$(mktemp -d /tmp/iperf-prom.XXXXXX)"

# Rotate: keep last 20 run logs
ls -1t "$LOG_DIR"/run-*.log 2>/dev/null | tail -n +21 | xargs -r rm -f

exec > >(tee -a "$RUN_LOG") 2>&1

log()  { printf '%s [%s] %s\n' "$(date -u +%FT%TZ)" "${1:-INFO}" "${*:2}"; }
die()  { log FATAL "$*"; exit "${2:-2}"; }
err()  { log ERROR "$*"; }

need() { command -v "$1" >/dev/null 2>&1 || die "required command not found: $1" 3; }

# ───────────────────────────── ARG PARSING ─────────────────────────────
for arg in "$@"; do
  case "$arg" in
    --tcp-only) PROTOCOLS="tcp" ;;
    --udp-only) PROTOCOLS="udp" ;;
    --dur=*)    DURATION="${arg#*=}" ;;
    --par=*)    PARALLEL_STREAMS="${arg#*=}" ;;
    --port=*)   PORT_BASE="${arg#*=}" ;;
    --nodes=*)  IFS=' ' read -r -a _n <<<"${arg#*=}"; NODES=("${_n[@]}") ;;
    -h|--help)  sed -n '2,30p' "$0"; exit 0 ;;
    *)          die "unknown argument: $arg" ;;
  esac
done

[[ ${#NODES[@]} -ge 2 ]]        || die "need at least 2 nodes in NODES[]"
[[ "$DURATION" =~ ^[0-9]+$ ]]   || die "DURATION must be an integer"
for d in need jq ssh date mktemp; do need "$d"; done

if [[ ! -w "$METRIC_DIR" ]]; then
  log WARN "$METRIC_DIR not writable — metrics will go to $PROM_TMP only."
  log WARN "Enable node_exporter with: --collector.textfile.directory=$METRIC_DIR"
fi

# ───────────────────────────── IP RESOLUTION ─────────────────────────────
declare -A NAME2IP IP2NAME ORDER=()

resolve_ip() {           # $1 = host/ip → echoes IPv4 (or IPv6) or nothing
  local h="$1"
  if [[ "$h" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then echo "$h"; return 0; fi
  if [[ "$h" == *:* ]]; then echo "$h"; return 0; fi
  getent ahostsv4 "$h" 2>/dev/null | awk 'NR==1{print $1; exit}' \
    || getent ahostsv6 "$h" 2>/dev/null | awk 'NR==1{print $1; exit}'
}

for entry in "${NODES[@]}"; do
  name="${entry%%|*}"; ip="${entry#*|}"; [[ "$ip" == "$name" ]] && ip=""
  [[ -n "$ip" ]] || ip="$(resolve_ip "$name")"
  [[ -n "$ip" ]] || die "cannot resolve '$name' to an IP address" 4
  NAME2IP["$name"]="$ip"; IP2NAME["$ip"]="$name"; ORDER+=("$name")
done

log INFO "Resolved ${#ORDER[@]} nodes: $(printf '%s=%s ' "${!NAME2IP[@]}" | fold -sw 100)"
TOTAL_PAIRS=$(( ${#ORDER[@]} * (${#ORDER[@]} - 1) ))
log INFO "Plan: $TOTAL_PAIRS directed tests per protocol × [${PROTOCOLS}] = $(( TOTAL_PAIRS * $(wc -w <<<"$PROTOCOLS") )) total"

# ───────────────────────────── SSH WRAPPER ─────────────────────────────
sr() {   # sr <ip> <cmd...>  — single, non-interactive ssh with hard timeout
  local ip="$1"; shift
  timeout $(( DURATION + 60 )) ssh $SSH_OPTS "$SSH_USER@$ip" -- "$@"
}

check_node() {          # reachable + has iperf3?
  local ip="$1" n="$2"
  sr "$ip" "command -v $IPERF_BIN >/dev/null && echo OK" 2>/dev/null | grep -q OK \
    || { err "$n ($ip): unreachable or iperf3 not installed"; return 1; }
}

# ───────────────────────────── SERVER LIFECYCLE ─────────────────────────────
port_for() { echo $(( PORT_BASE + ${ORDER[$1]} )); }   # deterministic per node index

start_servers() {
  log INFO "Starting iperf3 servers (one port per node)…"
  local i name ip port
  for i in "${!ORDER[@]}"; do
    name="${ORDER[$i]}"; ip="${NAME2IP[$name]}"; port="$(port_for "$i")"
    # --logfile keeps daemons from spamming ssh; -1 = serve forever.
    sr "$ip" "pgrep -f 'iperf3 -s.*-p $port' >/dev/null || \
      (mkdir -p $LOG_DIR && $IPERF_BIN -s -D -1 -p $port --logfile $LOG_DIR/server-$port.log)" \
      || { err "$name ($ip): failed to start iperf3 server on :$port"; FAILED_NODES+=("$name"); }
  done
  sleep 2
}

stop_servers() {        # only OUR ports — never a blanket pkill
  local i port
  for i in "${!ORDER[@]}"; do
    port="$(port_for "$i")"
    sr "${NAME2IP[${ORDER[$i]}]}" "pkill -f 'iperf3 -s.*-p $port' || true" 2>/dev/null || true
  done
}

cleanup() {
  local rc=$?
  stop_servers
  # publish whatever metrics we collected, even on abort
  shopt -s nullglob; local files=("$PROM_TMP"/*.prom)
  if [[ ${#files[@]} -gt 0 && -w "$METRIC_DIR" ]]; then
    for f in "${files[@]}"; do install -m 0644 "$f" "$METRIC_DIR/$(basename "$f").tmp" \
      && mv -f "$METRIC_DIR/$(basename "$f").tmp" "$METRIC_DIR/$(basename "$f")"; done
  fi
  rm -rf "$PROM_TMP"
  log INFO "Cleanup done (rc=$rc). Logs: $RUN_LOG | $JSONL_LOG | $CSV_LOG"
  exit $rc
}
trap cleanup EXIT INT TERM

# ───────────────────────────── jq EXTRACTOR ─────────────────────────────
# Emits one TSV row: ts send_bps recv_bps rtx jitter_s lost pkts duration_s
read -r -d '' JQ_PROG <<'JQ' || true
  ((.start.test_start.timesecs // .start.timestamp.timesecs // 0)) as $ts |
  (.end.sum_sent     // {}) as $ss |
  (.end.sum_received // {}) as $sr |
  ([ .end.streams[]? | (.tcp // .udp // .sctp // {}) ]) as $st |
  ([$st[] | .retransmits   // 0] | add // 0) as $rtx |
  ([$st[] | select(.jitter != null) | .jitter] | max // 0) as $jit |
  ([$st[] | .lost_packets  // 0] | add // 0) as $lost |
  ([$st[] | .packets       // 0] | add // 0) as $pkts |
  [$ts,
   ($ss.bits_per_second // 0),
   ($sr.bits_per_second // 0),
   $rtx, $jit, $lost, $pkts,
   (.intervals | length // 0)]
  | map(tostring) | join("\t")
JQ

# ───────────────────────────── ONE DIRECTED TEST ─────────────────────────────
FAILED_PAIRS=0; FAILED_NODES=(); declare -A METRICS   # key → "value labels"

run_test() {   # run_test <src_name> <dst_name> <tcp|udp> [reverse]
  local src="$1" dst="$2" proto="$3" rev="${4:-}"
  local sip="${NAME2IP[$src]}" dip="${NAME2IP[$dst]}"
  local dport; dport="$(port_for "$(echo "${ORDER[*]}" | tr ' ' '\n' | grep -nx "$dst" | cut -d: -f1)")"
  local dir="forward"; [[ "$rev" == "-R" ]] && dir="reverse"
  local af=4; [[ "$dip" == *:* ]] && { af=6; dip="[$dip]"; }

  local flags=(-c "$dip" -p "$dport" -t "$DURATION" -P "$PARALLEL_STREAMS" -J --get-server-output)
  [[ "$proto" == "udp" ]] && { flags+=(-u); [[ "$UDP_BITRATE" != 0 ]] && flags+=(-b "$UDP_BITRATE"); }
  [[ -n "$rev" ]] && flags+=("$rev")

  local attempt out rc label="$src->$dst/$proto/$dir"
  for (( attempt=1; attempt<=MAX_RETRIES+1; attempt++ )); do
    log INFO "TEST $label (attempt $((attempt-1))/$(MAX_RETRIES+1)) : $sip -> $dip:$dport"
    out="$(sr "$sip" "$IPERF_BIN ${flags[*]}" 2>/dev/null)"; rc=$?
    [[ $rc -eq 0 && -n "$out" ]] && break
    sleep 3
  done

  if [[ $rc -ne 0 || -z "$out" ]]; then
    err "FAILED $label (rc=$rc)"; (( FAILED_PAIRS++ )) || true
    METRICS["iperf3_test_success{src=\"$src\",dst=\"$dst\",proto=\"$proto\",dir=\"$dir\"}"]=0
    return 1
  fi

  local row; row="$(jq -r "$JQ_PROG" <<<"$out")" || { err "bad JSON for $label"; return 1; }
  IFS=$'\t' read -r ts send recv rtx jit lost pkts dur <<<"$row"
  # iperf3 reports sender/receiver from the client's view; with -R they swap.
  local tx rx
  if [[ "$dir" == "reverse" ]]; then tx="$recv"; rx="$send"; else tx="$send"; rx="$recv"; fi

  log INFO "  → $label  TX=$(awk -v b="$tx" 'BEGIN{printf "%.2f Gbit/s", b/1e9}') RX=$(awk -v b="$rx" 'BEGIN{printf "%.2f Gbit/s", b/1e9}') rtx=$rtx jitter=${jit}s lost=$lost/$pkts"

  # structured log line (Loki / ES / ClickHouse)
  jq -nc --arg run "$RUN_ID" --arg site "$SITE" --arg src "$src" --arg dst "$dst" \
         --arg sip "$sip" --arg dip "$dip" --arg p "$proto" --arg d "$dir" \
         --argjson ts "${ts:-0}" --argjson tx "${tx:-0}" --argjson rx "${rx:-0}" \
         --argjson rtx "$rtx" --argjson jit "${jit:-0}" --argjson lost "$lost" \
         --argjson pkts "$pkts" --argjson dur "${dur:-0}" --argjson port "$dport" \
    '{run_id:$run,site:$site,src:$src,dst:$dst,src_ip:$sip,dst_ip:$dip,proto:$p,direction:$d,
      server_port:$port,port:$port,timestamp:$ts,bits_per_second_tx:$tx,bits_per_second_rx:$rx,
      retransmits:$rtx,jitter_seconds:$jit,lost_packets:$lost,packets:$pkts,duration_seconds:$dur}' \
    >> "$JSONL_LOG"

  printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' "$(date -u +%FT%TZ)" "$src" "$dst" "$proto" "$dir" \
    "$tx" "$rx" "$rtx" "$jit" "$lost" "$pkts" >> "$CSV_LOG"

  local L="site=\"$SITE\",src=\"$src\",dst=\"$dst\",src_ip=\"$sip\",dst_ip=\"$dip\",proto=\"$proto\",dir=\"$dir\",af=\"$af\""
  METRICS["iperf3_bits_per_second_tx{$L}"]=$tx
  METRICS["iperf3_bits_per_second_rx{$L}"]=$rx
  METRICS["iperf3_retransmits_total{$L}"]=$rtx
  METRICS["iperf3_jitter_seconds{$L}"]=$jit
  METRICS["iperf3_lost_packets_total{$L}"]=$lost
  METRICS["iperf3_packets_total{$L}"]=$pkts
  METRICS["iperf3_test_duration_seconds{$L}"]=$dur
  METRICS["iperf3_test_success{$L}"]=1
}

# ───────────────────────────── SCHEDULER (bounded parallelism) ─────────────────────
write_metrics_shard() {   # $1 = shard file; called by each worker via a temp file
  local f="$1"; shift
  : > "$f"
  printf '# TYPE iperf3_bits_per_second_tx gauge\n# HELP iperf3_bits_per_second_tx Client-side TX throughput\n' >> "$f"
  for k in "${!METRICS[@]}"; do printf '%s %s\n' "$k" "${METRICS[$k]}" >> "$f"; done
  printf 'iperf3_mesh_run_timestamp_seconds %s\n' "$(date +%s)" >> "$f"
}

main() {
  log INFO "=== iperf3 full-mesh run $RUN_ID ==="
  mapfile -t REACH < <(for n in "${ORDER[@]}"; do check_node "${NAME2IP[$n]}" "$n" && echo "$n"; done)
  [[ ${#REACH[@]} -ge 2 ]] || die "fewer than 2 nodes reachable" 4
  ((${#REACH[@]} < ${#ORDER[@]})) && log WARN "skipping unreachable: $(comm -13 <(printf '%s\n' "${REACH[@]}" | sort) <(printf '%s\n' "${ORDER[@]}" | sort) | tr '\n' ' ')"
  ORDER=("${REACH[@]}")

  start_servers
  : > "$CSV_LOG"; echo "timestamp,src,dst,proto,dir,tx_bps,rx_bps,retransmits,jitter_s,lost,pkts" >> "$CSV_LOG"

  local i j proto
  for proto in $PROTOCOLS; do
    log INFO "--- protocol: $proto ---"
    for i in "${!ORDER[@]}"; do
      for j in "${!ORDER[@]}"; do
        [[ $i -eq $j ]] && continue
        run_test "${ORDER[$i]}" "${ORDER[$j]}" "$proto" &
        while (( $(jobs -rp | wc -l) >= SSH_PARALLEL )); do wait -n; done
        if [[ "$REVERSE_TESTS" == 1 ]]; then   # extra: same socket pair, flipped flow
          run_test "${ORDER[$i]}" "${ORDER[$j]}" "$proto" "-R" &
          while (( $(jobs -rp | wc -l) >= SSH_PARALLEL )); do wait -n; done
        fi
      done
    done
    wait
  done

  # ── publish metrics ──
  local shard="$PROM_TMP/iperf_mesh.prom" tmpm
  : > "$shard"
  { echo "# HELP iperf3_bits_per_second_tx Client-view transmit throughput (bits/s)"
    echo "# TYPE iperf3_bits_per_second_tx gauge"
    for k in "${!METRICS[@]}"; do printf '%s %s\n' "$k" "${METRICS[$k]}"; done; } >
$$
