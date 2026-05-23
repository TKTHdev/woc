#!/bin/bash
# Generate YCSB workload traces (.dat) consumed by the woc MongoDB layer.
#
# Uses the prebuilt YCSB release + a direct `java` invocation of the BasicDB
# binding. This deliberately avoids YCSB's bin/ycsb launcher (Python 2 only)
# and Maven (needs a JDK), neither of which work on modern Ubuntu / Python 3.
#
# BasicDB prints each operation to stdout in exactly the format the woc parser
# expects (see mongodb/mgdb_leader.go: lineToQuery).
#
# Output: ycsb/workData/  -- where start_mongodb_hetero.sh and the woc
# client/server look for the files:
#     workload.dat            (load phase  -> server seeds MongoDB)
#     run_workload{a..f}.dat  (run phase   -> client replays as the benchmark)
#
# Optional overrides:
#     RECORDCOUNT=100000 OPERATIONCOUNT=100000 bash genData.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

YCSB_VERSION="0.17.0"
YCSB_DIR="${SCRIPT_DIR}/ycsb-${YCSB_VERSION}"
WORKDATA_DIR="${SCRIPT_DIR}/../workData"   # -> ycsb/workData

RECORDCOUNT="${RECORDCOUNT:-}"
OPERATIONCOUNT="${OPERATIONCOUNT:-}"

mkdir -p "$WORKDATA_DIR"

# --- prerequisites ---------------------------------------------------------
if ! command -v java >/dev/null 2>&1; then
    echo "ERROR: 'java' not found. Install a JRE, e.g.:" >&2
    echo "       sudo apt-get install -y openjdk-11-jre-headless" >&2
    exit 1
fi

# --- fetch prebuilt YCSB release (no Maven build required) -----------------
if [ ! -d "${YCSB_DIR}/lib" ]; then
    echo ">> prebuilt YCSB ${YCSB_VERSION} not found, downloading..."
    tarball="${SCRIPT_DIR}/ycsb-${YCSB_VERSION}.tar.gz"
    url="https://github.com/brianfrankcooper/YCSB/releases/download/${YCSB_VERSION}/ycsb-${YCSB_VERSION}.tar.gz"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL -o "$tarball" "$url"
    else
        wget --no-check-certificate -O "$tarball" "$url"
    fi
    tar xzf "$tarball" -C "$SCRIPT_DIR"
    rm -f "$tarball"
fi

classpath="${YCSB_DIR}/lib/*"
workloads="${YCSB_DIR}/workloads"

# Optional per-run sizing, appended only when the env vars are set.
extra_props=()
[ -n "$RECORDCOUNT" ]    && extra_props+=(-p "recordcount=${RECORDCOUNT}")
[ -n "$OPERATIONCOUNT" ] && extra_props+=(-p "operationcount=${OPERATIONCOUNT}")

# gen <phase> <workload-file> <output-file>
#   phase: -load (insert trace) | -t (transaction/run trace)
gen() {
    local phase="$1" workload="$2" outfile="$3"
    java -cp "$classpath" site.ycsb.Client "$phase" \
        -db site.ycsb.BasicDB \
        -P "$workload" \
        -p basicdb.verbose=true \
        "${extra_props[@]}" \
        > "$outfile" 2>/dev/null

    if [ ! -s "$outfile" ] || ! grep -qE '^(INSERT|READ|UPDATE|SCAN|DELETE) ' "$outfile"; then
        echo "ERROR: $outfile has no parseable YCSB operations." >&2
        echo "       Check the java classpath: ls ${YCSB_DIR}/lib | grep core" >&2
        exit 1
    fi
}

echo ">> generating load trace        -> workload.dat"
gen -load "${workloads}/workloada" "${WORKDATA_DIR}/workload.dat"

for w in a b c d e f; do
    echo ">> generating run trace ($w)      -> run_workload${w}.dat"
    gen -t "${workloads}/workload${w}" "${WORKDATA_DIR}/run_workload${w}.dat"
done

echo ">> done."
wc -l "${WORKDATA_DIR}"/*.dat
