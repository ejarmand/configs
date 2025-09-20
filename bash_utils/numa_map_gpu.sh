#!/usr/bin/env bash
#
# numa_map_gpu.sh
# Run a command pinned to the NUMA node that matches a chosen GPU.
# Uses numactl if available, falls back to taskset for CPU affinity only.
#
# Usage:
#   ./numa_map_gpu.sh <gpu_id> <command> [args...]
#
# Example:
#   ./numa_map_gpu.sh 0 python train.py
#   ./numa_map_gpu.sh 5 ./inference_server
#
# Dependencies:
#   - nvidia-smi (required)
#   - numactl (preferred) or taskset (fallback) or neither (warning)
#

set -euo pipefail

if [ "$#" -lt 2 ]; then
    echo "Usage: $0 <gpu_id> <command> [args...]"
    exit 1
fi

# Function to get CPU list for a NUMA node
get_numa_cpus() {
    local numa_node=$1
    if [ -f "/sys/devices/system/node/node${numa_node}/cpulist" ]; then
        cat "/sys/devices/system/node/node${numa_node}/cpulist"
    else
        # Fallback: assume typical dual-socket system
        # NUMA 0: CPUs 0-N/2-1, NUMA 1: CPUs N/2-N-1
        local total_cpus
        total_cpus=$(nproc)
        local half_cpus=$((total_cpus / 2))
        
        if [ "$numa_node" -eq 0 ]; then
            echo "0-$((half_cpus - 1))"
        else
            echo "${half_cpus}-$((total_cpus - 1))"
        fi
    fi
}

GPU_ID=$1
shift

# Lookup NUMA node for this GPU from sysfs
PCI_BUS_ID=$(nvidia-smi --query-gpu=pci.bus_id --format=csv,noheader -i "$GPU_ID" | tr -d ' ')

# Try to get NUMA node from sysfs
if [ -f "/sys/bus/pci/devices/0000:${PCI_BUS_ID}/numa_node" ]; then
    NUMA_NODE=$(cat "/sys/bus/pci/devices/0000:${PCI_BUS_ID}/numa_node")
else
    NUMA_NODE=-1
fi

# Apply fallback mapping if NUMA node can't be identified
if [ "$NUMA_NODE" -lt 0 ]; then
    echo "Warning: NUMA node not identifiable for GPU $GPU_ID (bus ${PCI_BUS_ID}), using fallback mapping"
    if [ "$GPU_ID" -le 3 ]; then
        NUMA_NODE=0
        echo "Fallback: GPU $GPU_ID mapped to NUMA node 0"
    elif [ "$GPU_ID" -le 7 ]; then
        NUMA_NODE=1
        echo "Fallback: GPU $GPU_ID mapped to NUMA node 1"
    else
        echo "Warning: GPU $GPU_ID is outside fallback range (0-7), defaulting to NUMA node 0"
        NUMA_NODE=0
    fi
fi

export CUDA_VISIBLE_DEVICES=$GPU_ID

echo "GPU $GPU_ID (bus $PCI_BUS_ID) → NUMA node $NUMA_NODE"
echo "CUDA_VISIBLE_DEVICES=$CUDA_VISIBLE_DEVICES"

# Check if numactl is available
if command -v numactl >/dev/null 2>&1; then
    echo "Using numactl for CPU and memory binding"
    exec numactl --cpunodebind="$NUMA_NODE" --membind="$NUMA_NODE" "$@"
elif command -v taskset >/dev/null 2>&1; then
    # Fallback to taskset (CPU binding only, no memory binding)
    CPU_LIST=$(get_numa_cpus "$NUMA_NODE")
    echo "numactl not found, falling back to taskset with CPUs: $CPU_LIST"
    echo "Note: Only CPU affinity will be set (no memory binding)"
    exec taskset -c "$CPU_LIST" "$@"
else
    echo "Warning: Neither numactl nor taskset found, running without CPU affinity"
    exec "$@"
fi

