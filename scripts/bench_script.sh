#!/usr/bin/env bash
# Odin vs Lua benchmark (plan.md P2.1). Refuses to measure on a busy machine.
# Runs benchmark, benchmark_lua, benchmark_lua_batch interleaved (per run index),
# for each boats-per-model N, then prints one markdown table.
#
# Env:
#   BIN   app binary (default /tmp/cubes_v; build it first, not done here)
#   N     boats-per-model list (default "100 150 400")
#   RUNS  runs per scene per N (default 3)
#   WAIT  seconds to poll until load1 <= 2.0 before refusing (default 0 = no wait)
set -u
# awk must parse "2.78" as 2.78: pt_BR locale reads "2.78"+0 as 2 (comma decimal).
export LC_ALL=C

BIN=${BIN:-/tmp/cubes_v}
N_LIST=${N:-100 150 400}
RUNS=${RUNS:-3}
WAIT=${WAIT:-0}
DURATION=5
LOAD_MAX=2.0
SCENES="benchmark benchmark_lua benchmark_lua_batch"

[ -x "$BIN" ] || { echo "bench: binary not executable: $BIN" >&2; exit 1; }

# vm.loadavg prints "{ 2,94 3,28 3,93 }" (comma decimal on this machine); field 2 is load1.
load1() {
	set -- $(sysctl -n vm.loadavg)
	echo "$2" | tr ',' '.'
}

over() { awk -v v="$1" -v t="$2" 'BEGIN { exit !(v + 0 > t + 0) }'; }

# Sets LOAD_NOW. Exits 1 when still busy after WAIT seconds (called without $(...) so exit applies).
require_idle() {
	local deadline=$((SECONDS + WAIT))
	while :; do
		LOAD_NOW=$(load1)
		over "$LOAD_NOW" "$LOAD_MAX" || return 0
		if [ "$SECONDS" -ge "$deadline" ]; then
			echo "bench: load average (1 min) $LOAD_NOW > $LOAD_MAX; refusing to run (WAIT=$WAIT)." >&2
			exit 1
		fi
		echo "bench: waiting for idle, load1 $LOAD_NOW > $LOAD_MAX" >&2
		sleep 10
	done
}

RAW=$(mktemp -d /tmp/bench_script.XXXXXX)
ROWS=$RAW/rows.tsv
LOADS=$RAW/loads.txt
: > "$ROWS"
: > "$LOADS"
echo "bench: raw output in $RAW" >&2

# Parses one --bench report into one TSV row:
# N scene run frame_p50 frame_p95 script_avg script_p95 extract_avg extract_p95 draws_avg instances
run_scene() {
	local n=$1 run=$2 scene=$3 out=$RAW/n${1}_r${2}_${3}.txt
	if ! CUBES_BENCH_PER_MODEL=$n "$BIN" "$scene" --bench $DURATION > "$out" 2>&1; then
		echo "bench: $scene N=$n run=$run exited non-zero; see $out" >&2
		exit 1
	fi
	awk -v n="$n" -v run="$run" -v scene="$scene" -v OFS='\t' '
		$1 == "frame" && $2 == "ms"        { p50 = $6; p95 = $8 }
		$1 == "script" && $2 == "ms"       { if ($3 == "n/a") { sa = "n/a"; sp = "n/a" } else { sa = $4; sp = $6 } }
		$1 == "cpu" && $2 == "extract"     { ea = $4; ep = $6 }
		$1 == "draw" && $2 == "calls"      { dr = $4 }
		$1 == "instances"                  { ins = $2 }
		END {
			if (p50 == "") exit 1
			print n, scene, run, p50, p95, sa, sp, ea, ep, dr, ins
		}' "$out" >> "$ROWS" || { echo "bench: no frame report in $out" >&2; exit 1; }
	tail -1 "$ROWS" | awk -F'\t' '{ printf "bench: N=%s run=%s %-18s frame p50 %s p95 %s | script avg %s\n", $1, $3, $2, $4, $5, $6 }' >&2
}

require_idle # once, at start (plan P2.1); load before/after each N is recorded and flagged, not gated
for n in $N_LIST; do
	before=$(load1)
	for run in $(seq 1 "$RUNS"); do
		for scene in $SCENES; do
			run_scene "$n" "$run" "$scene"
		done
	done
	after=$(load1)
	echo "N=$n load1 before $before after $after" >> "$LOADS"
	over "$after" "$LOAD_MAX" && echo "bench: WARNING load1 rose to $after > $LOAD_MAX during N=$n" >&2
done

TABLE=$RAW/table.md
{
	echo "Odin vs Lua benchmark: BIN=$BIN, duration ${DURATION}s, RUNS=$RUNS, N=$N_LIST, windowed."
	echo "Frame ms p50/p95 from \`--bench\`. Script ms: \`--bench\` prints avg/p95/max only (no p50), so avg and p95 are shown. Extract: \`cpu extract\` avg/p95 from \`--bench\` (no p50 either). Spread = (max-min)/median."
	echo
	echo "Load average (1 min, vm.loadavg) per N:"
	echo
	sed 's/^/- /' "$LOADS"
	echo
	echo "| N | scene | run | frame p50 ms | frame p95 ms | script avg ms | script p95 ms | extract avg ms | extract p95 ms | draws avg | instances |"
	echo "|---|---|---|---|---|---|---|---|---|---|---|"
	for n in $N_LIST; do
		for scene in $SCENES; do
			awk -F'\t' -v N="$n" -v S="$scene" '
			function insort(a, cnt,   i, j, t) {
				for (i = 2; i <= cnt; i++) {
					t = a[i]
					for (j = i - 1; j >= 1 && a[j] > t; j--) a[j + 1] = a[j]
					a[j + 1] = t
				}
			}
			function cell(k, x) { return k == 10 ? sprintf("%.1f", x) : k == 11 ? sprintf("%.0f", x) : sprintf("%.3f", x) }
			BEGIN { c = 0 }
			$1 == N && $2 == S {
				c++
				line = "| " $1 " | " $2 " | " $3
				for (k = 4; k <= 11; k++) {
					line = line " | " $k
					val[k, c] = $k
				}
				print line " |"
			}
			END {
				if (c == 0) exit
				med = "| " N " | " S " | **median**"
				spr = "| " N " | " S " | spread"
				for (k = 4; k <= 11; k++) {
					na = 0
					for (r = 1; r <= c; r++) {
						if (val[k, r] == "n/a") na = 1
						s[r] = val[k, r] + 0
					}
					if (na) { med = med " | n/a"; spr = spr " | n/a"; continue }
					insort(s, c)
					m = (c % 2) ? s[(c + 1) / 2] : (s[c / 2] + s[c / 2 + 1]) / 2
					med = med " | " cell(k, m)
					spr = spr " | " (m > 0 ? sprintf("%.1f%%", (s[c] - s[1]) / m * 100) : "n/a")
				}
				print med " |"
				print spr " |"
			}' "$ROWS"
		done
	done
} | tee "$TABLE"
echo "bench: table in $TABLE" >&2
