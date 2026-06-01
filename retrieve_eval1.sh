#!/bin/bash
# ================================================================
# Retrieve + merge EVAL 1 results from the remote cluster.
#
# The eval_1 script runs the 8 workload-composition cases back to
# back without archiving. Each client writes one timestamped CSV per
# case into eval/client<ID>/, so the 8 newest CSVs (oldest-first) map
# to test cases 1..8. This script pulls those, lays them out per case,
# and runs merge_eval.py just like the old in-script archive/merge.
# ================================================================

set -u

SSH_USER="${SSH_USER:-ubuntu}"
SSH_KEY="${SSH_KEY:-${HOME}/.ssh/tani.pem}"
CONTROLLER="${CONTROLLER:-auto}"
REMOTE_DIR="/home/ubuntu/woc"
EVAL_DIR="${REMOTE_DIR}/eval"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MERGE_SCRIPT="${SCRIPT_DIR}/merge_eval.py"
RESULT_ROOT="${SCRIPT_DIR}/results/eval1_indep_common_ratio"
RUN_TS="$(date +%Y%m%d_%H%M%S)"
RUN_DIR="${RESULT_ROOT}/${RUN_TS}"

BASTION_PUBLIC_IP="134.87.11.79"
BASTION_INTERNAL_IP="192.168.73.93"

# Client hosts -> client id (must match eval_1: id = NUM_SERVERS + index = 5,6)
CLIENT_IPS=("192.168.73.11" "192.168.73.234")
CLIENT_IDS=(5 6)

# Test cases in run order (index 0 = oldest of the 8 newest CSVs)
TEST_CASES=(
"100.0/0.0"
"90.0/10.0"
"80.0/20.0"
"60.0/40.0"
"40.0/60.0"
"20.0/80.0"
"10.0/90.0"
"0.0/100.0"
)

detect_controller_mode() {
    case "$CONTROLLER" in
        laptop|bastion)
            echo "$CONTROLLER"
            ;;
        auto)
            local ips
            ips="$(hostname -I 2>/dev/null || true)"
            if [[ " ${ips} " == *" ${BASTION_INTERNAL_IP} "* ]]; then
                echo "bastion"
            else
                echo "laptop"
            fi
            ;;
        *)
            echo "ERROR: CONTROLLER must be auto, laptop, or bastion (got: $CONTROLLER)" >&2
            exit 1
            ;;
    esac
}

CONTROLLER_MODE="$(detect_controller_mode)"

if [ ! -f "$SSH_KEY" ]; then
    echo "ERROR: SSH key not found: $SSH_KEY" >&2
    echo "Set SSH_KEY=/path/to/key if it is stored elsewhere." >&2
    exit 1
fi

SSH_BASE_OPTS=(-i "$SSH_KEY" -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new)
PROXY_CMD="ssh -i '$SSH_KEY' -o BatchMode=yes -o StrictHostKeyChecking=accept-new -W %h:%p ${SSH_USER}@${BASTION_PUBLIC_IP}"

ssh_opts_for() {
    local host=$1
    SSH_OPTS=("${SSH_BASE_OPTS[@]}")
    SSH_IS_LOCAL=false

    if [ "$CONTROLLER_MODE" = "bastion" ] && [ "$host" = "$BASTION_INTERNAL_IP" ]; then
        SSH_IS_LOCAL=true
        SSH_TARGET="localhost"
    elif [ "$CONTROLLER_MODE" = "bastion" ]; then
        SSH_TARGET="$host"
    elif [ "$host" = "$BASTION_INTERNAL_IP" ]; then
        SSH_TARGET="$BASTION_PUBLIC_IP"
    else
        SSH_OPTS+=(-o "ProxyCommand=$PROXY_CMD")
        SSH_TARGET="$host"
    fi
}

remote_exec() {
    local host=$1; shift
    ssh_opts_for "$host"
    if [ "$SSH_IS_LOCAL" = true ]; then
        bash -lc "$*"
    else
        ssh "${SSH_OPTS[@]}" "$SSH_USER@$SSH_TARGET" "$*"
    fi
}

NCASES=${#TEST_CASES[@]}

echo "=============================================="
echo "EVAL 1: retrieve + merge"
echo "  Controller: $CONTROLLER_MODE"
echo "  SSH user:   $SSH_USER"
echo "  SSH key:    $SSH_KEY"
echo "  Cases: $NCASES   Run dir: $RUN_DIR"
echo "=============================================="

mkdir -p "$RUN_DIR"

# Download: for each client, tar the $NCASES newest CSVs over a single SSH
# connection into a staging dir, then distribute them (oldest-first = case 1..N)
# into per-case eval/<clientID>/ folders.
STAGE="${RUN_DIR}/.stage"
for ci in "${!CLIENT_IPS[@]}"; do
    ip="${CLIENT_IPS[$ci]}"
    cid="${CLIENT_IDS[$ci]}"
    cdir="client${cid}"
    stage_dir="${STAGE}/${cdir}"
    mkdir -p "$stage_dir"

    echo ""
    echo "Client ${cid} (${ip}): streaming ${NCASES} newest CSVs..."
    # One SSH session: list the N newest, tar them to stdout, extract locally.
    remote_exec "$ip" "cd '${EVAL_DIR}/${cdir}' && ls -t *.csv | head -${NCASES} | tar -czf - -T -" \
        | tar -xzf - -C "$stage_dir"

    # Order oldest-first by filename timestamp (matches run order 1..N).
    mapfile -t files < <(cd "$stage_dir" && ls -1 *.csv | sort)
    if [ "${#files[@]}" -ne "$NCASES" ]; then
        echo "  WARNING: expected ${NCASES} CSVs, got ${#files[@]} for ${cdir}"
    fi

    for idx in "${!files[@]}"; do
        case="${TEST_CASES[$idx]}"
        indep="${case%/*}"; common="${case#*/}"
        label="indep_${indep}_common_${common}"
        dest="${RUN_DIR}/${label}/eval/${cdir}"
        mkdir -p "$dest"
        mv "${stage_dir}/${files[$idx]}" "$dest/"
        echo "  case $((idx+1)) ${label}: ${files[$idx]}"
    done
done
rm -rf "$STAGE"

# Merge each case with merge_eval.py (clients only; servers emit no eval data).
client_id_filter="${CLIENT_IDS[0]}-${CLIENT_IDS[${#CLIENT_IDS[@]}-1]}"
echo ""
echo "Merging per case (client ids ${client_id_filter})..."
for case in "${TEST_CASES[@]}"; do
    indep="${case%/*}"; common="${case#*/}"
    label="indep_${indep}_common_${common}"
    case_eval_dir="${RUN_DIR}/${label}/eval"
    case_merged_dir="${RUN_DIR}/${label}/merged"
    mkdir -p "$case_merged_dir"
    echo ""
    echo "--- ${label} ---"
    python3 "$MERGE_SCRIPT" "$case_eval_dir" "$case_merged_dir/" --ids "$client_id_filter"
done

echo ""
echo "=============================================="
echo "Done. Results under: $RUN_DIR"
echo "=============================================="
