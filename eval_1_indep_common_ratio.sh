#!/bin/bash
# ================================================================
# EVAL 1: Independent vs Common Ratio Evaluation
# Tests various workload compositions: 100/0, 90/10, 80/20, 60/40, 40/60, 20/80, 10/90, 0/100
# Each configuration runs for 30 seconds
# ================================================================

set -u

SSH_USER="${SSH_USER:-ubuntu}"
SSH_KEY="${SSH_KEY:-${HOME}/.ssh/tani.pem}"
CONTROLLER="${CONTROLLER:-auto}"
REMOTE_DIR="/home/ubuntu/woc"
BINARY="woc"
CONFIG_PATH="${REMOTE_DIR}/config/cluster_hetero_5n_2s3w.conf"
LOG_DIR="${REMOTE_DIR}/logs"
EVAL_DIR="${REMOTE_DIR}/eval"
RUNTIME=30  # 30 seconds per test
NUM_SERVERS=5
NUM_CLIENTS=2
THRESHOLD=1
BATCHSIZE=1
PIPELINE_MODE=true
MONGO_CLIENT_POOL=16
LOG_LEVEL="info"

# 5-Node Cluster: 2 Strong (c32) + 2 Medium + 1 Weak (c8)
SERVER_IPS=(
"192.168.73.93"
"192.168.73.107"
"192.168.73.79"
"192.168.73.183"
"192.168.73.211"
)

CLIENT_HOST_IPS=(
"192.168.73.11"
"192.168.73.234"
)

WORKLOAD="a"

# Bastion: cora-c32-1 (internal 192.168.73.93 / public 134.87.11.79).
# CONTROLLER=laptop: internal IPs are reached through it via ProxyCommand.
# CONTROLLER=bastion: run this script on the bastion and use internal IPs directly.
BASTION_PUBLIC_IP="134.87.11.79"
BASTION_INTERNAL_IP="192.168.73.93"

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

SSH_BASE_OPTS=(-i "$SSH_KEY" -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new -o ServerAliveInterval=15 -o ServerAliveCountMax=8)
PROXY_CMD="ssh -i '$SSH_KEY' -o BatchMode=yes -o StrictHostKeyChecking=accept-new -W %h:%p ${SSH_USER}@${BASTION_PUBLIC_IP}"

# Resolve SSH options + target for a given host.
# Sets SSH_OPTS, SSH_TARGET, and SSH_IS_LOCAL.
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

# Test cases: INDEP_RATIO/COMMON_RATIO pairs
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

echo "=============================================="
echo "EVAL 1: Independent vs Common Ratio"
echo "=============================================="
echo "Controller: ${CONTROLLER_MODE}"
echo "SSH user:   ${SSH_USER}"
echo "SSH key:    ${SSH_KEY}"
echo "Test cases: ${#TEST_CASES[@]}"
echo "Runtime per test: ${RUNTIME}s"
echo ""

remote_exec() {
    local host=$1
    shift
    ssh_opts_for "$host"
    if [ "$SSH_IS_LOCAL" = true ]; then
        bash -lc "$*"
    else
        ssh "${SSH_OPTS[@]}" "$SSH_USER@$SSH_TARGET" "$*"
    fi
}

copy_file_to_host() {
    local src=$1
    local host=$2
    local dest_dir=$3

    ssh_opts_for "$host"
    if [ "$SSH_IS_LOCAL" = true ]; then
        mkdir -p "$dest_dir"
        local src_abs
        local dest_abs
        src_abs="$(cd "$(dirname "$src")" && pwd -P)/$(basename "$src")"
        dest_abs="$(cd "$dest_dir" && pwd -P)/$(basename "$src")"
        if [ "$src_abs" != "$dest_abs" ]; then
            cp "$src" "$dest_abs"
        fi
    else
        scp "${SSH_OPTS[@]}" "$src" "$SSH_USER@$SSH_TARGET:$dest_dir/" 2>/dev/null
    fi
}

create_remote_dirs() {
    for ip in "${SERVER_IPS[@]}" "${CLIENT_HOST_IPS[@]}"; do
        remote_exec "$ip" "mkdir -p '$REMOTE_DIR' '$LOG_DIR' '$EVAL_DIR' '$REMOTE_DIR/mongodb_data'"
    done
}

wait_for_mongo_ready() {
    local host=$1
    local label=$2
    local attempt

    for attempt in $(seq 1 30); do
        if remote_exec "$host" "mongosh --quiet --eval 'db.adminCommand({ ping: 1 })' >/dev/null 2>&1"; then
            return 0
        fi
        sleep 1
    done

    echo "  Warning: MongoDB readiness timed out on $label ($host)"
    return 1
}

start_mongo_cluster() {
    echo "  Creating remote directories..."
    create_remote_dirs

    echo "  Starting MongoDB on all servers..."
    for i in "${!SERVER_IPS[@]}"; do
        ip="${SERVER_IPS[$i]}"
        remote_exec "$ip" "pkill -x mongod 2>/dev/null || true; for _ in \$(seq 1 20); do ss -ltn 2>/dev/null | grep -q ':27017 ' || break; sleep 1; done; rm -f '$REMOTE_DIR/mongodb_data/mongod.lock' '$REMOTE_DIR/mongodb_data/WiredTiger.lock' '$LOG_DIR/mongod.log' 2>/dev/null || true; mkdir -p '$REMOTE_DIR/mongodb_data' '$LOG_DIR'; nohup mongod --port 27017 --replSet wocrs --dbpath '$REMOTE_DIR/mongodb_data' --bind_ip 0.0.0.0 --logpath '$LOG_DIR/mongod.log' --logappend > '$LOG_DIR/mongod.out' 2>&1 &"
    done

    for i in "${!SERVER_IPS[@]}"; do
        wait_for_mongo_ready "${SERVER_IPS[$i]}" "server${i}" || true
    done
}

init_replica_set() {
    echo "  Initializing MongoDB replica set..."
    remote_exec "${SERVER_IPS[0]}" "mongosh --eval \"rs.initiate({ _id: 'wocrs', members: [ {_id: 0, host: '${SERVER_IPS[0]}:27017'}, {_id: 1, host: '${SERVER_IPS[1]}:27017'}, {_id: 2, host: '${SERVER_IPS[2]}:27017'}, {_id: 3, host: '${SERVER_IPS[3]}:27017'}, {_id: 4, host: '${SERVER_IPS[4]}:27017'} ] })\" >/dev/null 2>&1 || true"

    for attempt in $(seq 1 30); do
        if remote_exec "${SERVER_IPS[0]}" "mongosh --quiet --eval 'db.adminCommand({ ping: 1 })' >/dev/null 2>&1"; then
            return 0
        fi
        sleep 1
    done

    echo "  Warning: replica set readiness timed out"
    return 1
}

build_and_distribute() {
    echo "  Building WOC binary..."
    go build -o "$BINARY"
    
    echo "  Distributing to all nodes..."
    for ip in "${SERVER_IPS[@]}" "${CLIENT_HOST_IPS[@]}"; do
        (
            copy_file_to_host "$BINARY" "$ip" "$REMOTE_DIR"
        ) &
    done
    wait
    echo "  ✓ Distribution complete"
}

start_workload_nodes() {
    local indep=$1
    local common=$2

    echo "  Starting WOC servers..."
    for i in "${!SERVER_IPS[@]}"; do
        ip="${SERVER_IPS[$i]}"
        remote_exec "$ip" "pkill -x woc 2>/dev/null || true; cd '$REMOTE_DIR'; nohup '$REMOTE_DIR/$BINARY' -id=$i -path='$CONFIG_PATH' -et=1 -n=$NUM_SERVERS -t=$THRESHOLD -b=$BATCHSIZE -mode=1 -mcli=$MONGO_CLIENT_POOL -mload='$WORKLOAD' -bcomp=object-specific -indep=$indep -common=$common -pipeline=$PIPELINE_MODE -log=$LOG_LEVEL -ep=true -role=0 > '$LOG_DIR/server_${i}_indep_${indep}_common_${common}.log' 2>&1 &"
    done

    echo "  Starting WOC clients..."
    for i in "${!CLIENT_HOST_IPS[@]}"; do
        ip="${CLIENT_HOST_IPS[$i]}"
        client_id=$((NUM_SERVERS + i))
        remote_exec "$ip" "pkill -x woc 2>/dev/null || true; cd '$REMOTE_DIR'; nohup '$REMOTE_DIR/$BINARY' -id=$client_id -path='$CONFIG_PATH' -et=1 -n=$NUM_SERVERS -t=$THRESHOLD -b=$BATCHSIZE -mode=1 -mload='$WORKLOAD' -bcomp=object-specific -indep=$indep -common=$common -pipeline=$PIPELINE_MODE -log=$LOG_LEVEL -ops=0 -role=1 > '$LOG_DIR/client_${i}_indep_${indep}_common_${common}.log' 2>&1 &"
    done
}

stop_workload_nodes() {
    for ip in "${SERVER_IPS[@]}" "${CLIENT_HOST_IPS[@]}"; do
        remote_exec "$ip" "pkill -TERM -x woc 2>/dev/null || true"
    done
    sleep 3
    for ip in "${SERVER_IPS[@]}" "${CLIENT_HOST_IPS[@]}"; do
        remote_exec "$ip" "pkill -9 -x woc 2>/dev/null || true"
    done
}

cleanup() {
    stop_workload_nodes || true
    for ip in "${SERVER_IPS[@]}"; do
        remote_exec "$ip" "pkill -x mongod 2>/dev/null || true" || true
    done
}

trap cleanup EXIT

start_cluster() {
    local indep=$1
    local common=$2
    local test_num=$3
    
    echo ""
    echo "--- Test $test_num: INDEP=$indep, COMMON=$common ---"
    
    start_workload_nodes "$indep" "$common"
    
    echo "  Cluster started. Running for ${RUNTIME}s..."
    sleep $RUNTIME
    
    # Stop only workload processes between cases; MongoDB stays up for the full sweep.
    echo "  Stopping workload processes..."
    stop_workload_nodes
    sleep 2
}

# Run tests
build_and_distribute

start_mongo_cluster
init_replica_set

test_num=1
for case in "${TEST_CASES[@]}"; do
    indep=${case%/*}
    common=${case#*/}
    start_cluster "$indep" "$common" "$test_num"
    test_num=$((test_num + 1))
done

echo ""
echo "=============================================="
echo "✓ EVAL 1 COMPLETE"
echo "=============================================="
echo ""
echo "Results stored in:"
echo "  Server logs: $LOG_DIR/server_*_indep_*_common_*.log"
echo "  Client logs: $LOG_DIR/client_*_indep_*_common_*.log"
echo "  Eval data:   $EVAL_DIR/test_*.csv"
echo ""
echo "Retrieve results with:"
if [ "$CONTROLLER_MODE" = "bastion" ]; then
    echo "  ls -lah $EVAL_DIR/"
    echo "  bash retrieve_eval1.sh"
else
    echo "  ssh -i $SSH_KEY $SSH_USER@$BASTION_PUBLIC_IP 'ls -lah $EVAL_DIR/'"
    echo "  bash retrieve_eval1.sh"
fi
