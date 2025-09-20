#!/usr/bin/env bash
#
# numa_map_gpu.sh
# Run a command pinned to the NUMA node that matches a chosen GPU.
#
# Usage:
#   ./numa_map_gpu.sh <gpu_id> <command> [args...]
#
# Example:
#   ./numa_map_gpu.sh 0 python train.py
#   ./numa_map_gpu.sh 5 ./inference_server
#

set -euo pipefail

if [ "$#" -lt 2 ]; then
    echo "Usage: $0 <gpu_id> <command> [args...]"
    exit 1
fi

GPU_ID=$1
shift

# Lookup NUMA node for this GPU from sysfs
PCI_BUS_ID=$(nvidia-smi --query-gpu=pci.bus_id --format=csv,noheader -i "$GPU_ID" | tr -d ' ')
NUMA_NODE=$(cat "/sys/bus/pci/devices/0000:${PCI_BUS_ID}/numa_node")

if [ "$NUMA_NODE" -lt 0 ]; then
    echo "Warning: NUMA node not reported for GPU $GPU_ID (bus ${PCI_BUS_ID}), defaulting to node 0"
    NUMA_NODE=0
fi

export CUDA_VISIBLE_DEVICES=$GPU_ID

echo "GPU $GPU_ID (bus $PCI_BUS_ID) → NUMA node $NUMA_NODE"
echo "CUDA_VISIBLE_DEVICES=$CUDA_VISIBLE_DEVICES"

exec numactl --cpunodebind="$NUMA_NODE" --membind="$NUMA_NODE" "$@"

