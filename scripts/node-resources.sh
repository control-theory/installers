#!/bin/bash
set -e

# Version
VERSION="v1.2.0"

# Defaults (from k8s-agent-daemonset values.yaml)
KUBECONFIG_PATH="$HOME/.kube/config"
DS_CPU_REQUEST="100m"
DS_MEMORY_REQUEST="500Mi"

usage() {
    cat <<EOF
DaemonSet Placement Analyzer $VERSION

Analyze Kubernetes cluster nodes for DaemonSet placement.
Shows taints, available resources, and generates helm install guidance.

Usage: $0 [options]

Options:
  -k, --kubeconfig <path>   Path to kubeconfig (default: ~/.kube/config)
  -c, --cpu <request>       DaemonSet CPU request (default: 100m)
  -m, --memory <request>    DaemonSet memory request (default: 500Mi)
  -h, --help                Show this help message
  -v, --version             Show version

Examples:
  $0 -k ~/.kube/ctstage
  $0 -k ~/.kube/ctstage -c 250m -m 1Gi
EOF
    exit 0
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -k|--kubeconfig)
            KUBECONFIG_PATH="$2"
            shift 2
            ;;
        -c|--cpu)
            DS_CPU_REQUEST="$2"
            shift 2
            ;;
        -m|--memory)
            DS_MEMORY_REQUEST="$2"
            shift 2
            ;;
        -h|--help)
            usage
            ;;
        -v|--version)
            echo "$VERSION"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

if [[ ! -f "$KUBECONFIG_PATH" ]]; then
    echo "Error: kubeconfig not found at $KUBECONFIG_PATH"
    exit 1
fi

KUBECTL="kubectl --kubeconfig=$KUBECONFIG_PATH"

# Convert CPU to millicores
cpu_to_millicores() {
    local cpu="$1"
    if [[ "$cpu" =~ ^([0-9]+)m$ ]]; then
        echo "${BASH_REMATCH[1]}"
    elif [[ "$cpu" =~ ^([0-9]+)$ ]]; then
        echo "$((${BASH_REMATCH[1]} * 1000))"
    elif [[ "$cpu" =~ ^([0-9]+)\.([0-9]+)$ ]]; then
        # Handle decimals like 0.5, 1.5
        local whole="${BASH_REMATCH[1]}"
        local frac="${BASH_REMATCH[2]}"
        # Pad or truncate fraction to 3 digits for millicores
        frac=$(printf "%-3s" "$frac" | tr ' ' '0' | cut -c1-3)
        echo "$((whole * 1000 + frac))"
    else
        echo "0"
    fi
}

# Convert memory to Mi (mebibytes)
memory_to_mi() {
    local mem="$1"
    if [[ -z "$mem" ]]; then
        echo "0"
        return
    fi

    if [[ "$mem" =~ ^([0-9]+)Ki$ ]]; then
        echo "$((${BASH_REMATCH[1]} / 1024))"
    elif [[ "$mem" =~ ^([0-9]+)Mi$ ]]; then
        echo "${BASH_REMATCH[1]}"
    elif [[ "$mem" =~ ^([0-9]+)Gi$ ]]; then
        echo "$((${BASH_REMATCH[1]} * 1024))"
    elif [[ "$mem" =~ ^([0-9]+)$ ]]; then
        # Bytes
        echo "$((${BASH_REMATCH[1]} / 1024 / 1024))"
    else
        echo "0"
    fi
}

# Sum CPU requests (handles mixed formats: 100m, 1, 0.5)
sum_cpu_requests() {
    local total=0
    for req in $1; do
        local mc=$(cpu_to_millicores "$req")
        total=$((total + mc))
    done
    echo "$total"
}

# Sum memory requests
sum_memory_requests() {
    local total=0
    for req in $1; do
        local mi=$(memory_to_mi "$req")
        total=$((total + mi))
    done
    echo "$total"
}

# Show over-provisioned pods on a node (actual usage < 50% of request)
# Args: node, sort_by (cpu|memory)
show_overprovisioned_pods() {
    local node="$1"
    local sort_by="$2"

    # Get all pod metrics (may fail if metrics-server not available)
    $KUBECTL top pods --all-namespaces --no-headers 2>/dev/null > /tmp/node_metrics_$$ || true

    if [[ ! -s /tmp/node_metrics_$$ ]]; then
        echo "  (metrics-server unavailable - cannot show over-provisioned pods)"
        rm -f /tmp/node_metrics_$$ 2>/dev/null
        return
    fi

    echo ""
    if [[ "$sort_by" == "cpu" ]]; then
        echo "  Over-provisioned pods (using <50% of requested CPU), sorted by REQ CPU:"
    else
        echo "  Over-provisioned pods (using <50% of requested MEM), sorted by REQ MEM:"
    fi
    echo "  -----------------------------------------------------------------------"
    printf "  %-45s %8s %8s %8s %8s\n" "POD" "REQ CPU" "USE CPU" "REQ MEM" "USE MEM"
    printf "  %-45s %8s %8s %8s %8s\n" "---" "-------" "-------" "-------" "-------"

    # Get pods on this node with their requests
    $KUBECTL get pods --all-namespaces --field-selector spec.nodeName="$node" \
        -o jsonpath='{range .items[*]}{.metadata.namespace}{"\t"}{.metadata.name}{"\t"}{range .spec.containers[*]}{.resources.requests.cpu}{" "}{end}{"\t"}{range .spec.containers[*]}{.resources.requests.memory}{" "}{end}{"\n"}{end}' 2>/dev/null | \
    while IFS=$'\t' read -r ns name cpu_reqs mem_reqs; do
        [[ -z "$name" ]] && continue

        # Sum CPU requests
        local pod_cpu_mc=0
        for req in $cpu_reqs; do
            local mc
            if [[ "$req" =~ ^([0-9]+)m$ ]]; then
                mc="${BASH_REMATCH[1]}"
            elif [[ "$req" =~ ^([0-9]+)$ ]]; then
                mc=$((${BASH_REMATCH[1]} * 1000))
            elif [[ "$req" =~ ^([0-9]+)\.([0-9]+)$ ]]; then
                local whole="${BASH_REMATCH[1]}"
                local frac="${BASH_REMATCH[2]}"
                frac=$(printf "%-3s" "$frac" | tr ' ' '0' | cut -c1-3)
                mc=$((whole * 1000 + frac))
            else
                mc=0
            fi
            pod_cpu_mc=$((pod_cpu_mc + mc))
        done

        # Sum memory requests
        local pod_mem_mi=0
        for req in $mem_reqs; do
            local mi
            if [[ "$req" =~ ^([0-9]+)Ki$ ]]; then
                mi=$((${BASH_REMATCH[1]} / 1024))
            elif [[ "$req" =~ ^([0-9]+)Mi$ ]]; then
                mi="${BASH_REMATCH[1]}"
            elif [[ "$req" =~ ^([0-9]+)Gi$ ]]; then
                mi=$((${BASH_REMATCH[1]} * 1024))
            elif [[ "$req" =~ ^([0-9]+)$ ]]; then
                mi=$((${BASH_REMATCH[1]} / 1024 / 1024))
            else
                mi=0
            fi
            pod_mem_mi=$((pod_mem_mi + mi))
        done

        # Get actual usage from metrics file
        local metrics_line=$(grep "^${ns}[[:space:]]" /tmp/node_metrics_$$ | grep "[[:space:]]${name}[[:space:]]" 2>/dev/null | head -1)
        [[ -z "$metrics_line" ]] && continue

        local actual_cpu_raw=$(echo "$metrics_line" | awk '{print $3}')
        local actual_mem_raw=$(echo "$metrics_line" | awk '{print $4}')

        # Convert actual CPU to millicores
        local actual_cpu_mc=0
        if [[ "$actual_cpu_raw" =~ ^([0-9]+)m$ ]]; then
            actual_cpu_mc="${BASH_REMATCH[1]}"
        elif [[ "$actual_cpu_raw" =~ ^([0-9]+)$ ]]; then
            actual_cpu_mc=$((${BASH_REMATCH[1]} * 1000))
        fi

        # Convert actual memory to Mi
        local actual_mem_mi=0
        if [[ "$actual_mem_raw" =~ ^([0-9]+)Mi$ ]]; then
            actual_mem_mi="${BASH_REMATCH[1]}"
        elif [[ "$actual_mem_raw" =~ ^([0-9]+)Gi$ ]]; then
            actual_mem_mi=$((${BASH_REMATCH[1]} * 1024))
        elif [[ "$actual_mem_raw" =~ ^([0-9]+)Ki$ ]]; then
            actual_mem_mi=$((${BASH_REMATCH[1]} / 1024))
        fi

        # Check if over-provisioned (using < 50% of request)
        local is_overprovisioned=false
        if [[ "$sort_by" == "cpu" ]]; then
            if [[ $pod_cpu_mc -gt 0 ]] && [[ $((actual_cpu_mc * 100 / pod_cpu_mc)) -lt 50 ]]; then
                is_overprovisioned=true
            fi
        else
            if [[ $pod_mem_mi -gt 0 ]] && [[ $((actual_mem_mi * 100 / pod_mem_mi)) -lt 50 ]]; then
                is_overprovisioned=true
            fi
        fi

        if $is_overprovisioned; then
            # Output: sortkey (for sorting), pod name, values
            if [[ "$sort_by" == "cpu" ]]; then
                printf "%08d\t%s\t%sm\t%s\t%sMi\t%s\n" "$pod_cpu_mc" "$name" "$pod_cpu_mc" "$actual_cpu_raw" "$pod_mem_mi" "$actual_mem_raw"
            else
                printf "%08d\t%s\t%sm\t%s\t%sMi\t%s\n" "$pod_mem_mi" "$name" "$pod_cpu_mc" "$actual_cpu_raw" "$pod_mem_mi" "$actual_mem_raw"
            fi
        fi
    done | sort -t$'\t' -k1 -rn | head -10 | while IFS=$'\t' read -r _ podname req_cpu use_cpu req_mem use_mem; do
        printf "  %-45s %8s %8s %8s %8s\n" "$podname" "$req_cpu" "$use_cpu" "$req_mem" "$use_mem"
    done

    rm -f /tmp/node_metrics_$$ 2>/dev/null
    echo ""
}

echo ""
echo "=============================================================================="
echo "DAEMONSET PLACEMENT ANALYSIS                                       $VERSION"
echo "=============================================================================="
echo "Date:              $(date '+%Y-%m-%d %H:%M:%S')"
echo "Kubeconfig:        $KUBECONFIG_PATH"
echo "DaemonSet CPU:     $DS_CPU_REQUEST"
echo "DaemonSet Memory:  $DS_MEMORY_REQUEST"
echo "=============================================================================="
echo ""

DS_CPU_MC=$(cpu_to_millicores "$DS_CPU_REQUEST")
DS_MEM_MI=$(memory_to_mi "$DS_MEMORY_REQUEST")

# Get PriorityClasses
echo "PRIORITY CLASSES"
echo "----------------"
PRIORITY_CLASSES=$($KUBECTL get priorityclasses -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.value}{"\n"}{end}' 2>/dev/null | sort -t$'\t' -k2 -rn)
if [[ -n "$PRIORITY_CLASSES" ]]; then
    printf "%-30s %s\n" "NAME" "VALUE"
    printf "%-30s %s\n" "----" "-----"
    echo "$PRIORITY_CLASSES" | while read -r line; do
        NAME=$(echo "$line" | cut -f1)
        VALUE=$(echo "$line" | cut -f2)
        printf "%-30s %s\n" "$NAME" "$VALUE"
    done
    # Check for recommended priority class
    if echo "$PRIORITY_CLASSES" | grep -q "system-node-critical"; then
        RECOMMENDED_PRIORITY="system-node-critical"
    elif echo "$PRIORITY_CLASSES" | grep -q "system-cluster-critical"; then
        RECOMMENDED_PRIORITY="system-cluster-critical"
    else
        RECOMMENDED_PRIORITY=""
    fi
else
    echo "  No PriorityClasses found (using default scheduling priority)"
    RECOMMENDED_PRIORITY=""
fi
echo ""

# Get all nodes
NODES=$($KUBECTL get nodes -o jsonpath='{.items[*].metadata.name}')

if [[ -z "$NODES" ]]; then
    echo "Error: No nodes found or unable to connect to cluster"
    exit 1
fi

# Collect all unique taints (using a simple list with dedup)
ALL_TAINTS_LIST=""

# Temporary file for summary
SUMMARY_FILE=$(mktemp)
trap "rm -f $SUMMARY_FILE /tmp/node_metrics_$$ 2>/dev/null" EXIT

echo "NODE DETAILS"
echo "------------"

for NODE in $NODES; do
    # Get node status
    STATUS=$($KUBECTL get node "$NODE" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')

    # Get taints
    TAINTS_JSON=$($KUBECTL get node "$NODE" -o jsonpath='{.spec.taints}')
    if [[ -z "$TAINTS_JSON" || "$TAINTS_JSON" == "null" ]]; then
        TAINT_LIST=""
    else
        TAINT_LIST=$($KUBECTL get node "$NODE" -o jsonpath='{range .spec.taints[*]}{.key}={.value}:{.effect}{","}{end}' | sed 's/,$//')

        # Collect unique taints
        IFS=',' read -ra TAINT_ARR <<< "$TAINT_LIST"
        for t in "${TAINT_ARR[@]}"; do
            if [[ -n "$t" ]]; then
                KEY=$(echo "$t" | cut -d'=' -f1)
                EFFECT=$(echo "$t" | grep -oE ':(NoSchedule|NoExecute|PreferNoSchedule)$' | tr -d ':')
                TAINT_ENTRY="$KEY:$EFFECT"
                if [[ ! "$ALL_TAINTS_LIST" =~ "$TAINT_ENTRY" ]]; then
                    ALL_TAINTS_LIST="${ALL_TAINTS_LIST:+$ALL_TAINTS_LIST }$TAINT_ENTRY"
                fi
            fi
        done
    fi

    # Get allocatable resources
    ALLOC_CPU=$($KUBECTL get node "$NODE" -o jsonpath='{.status.allocatable.cpu}')
    ALLOC_MEM=$($KUBECTL get node "$NODE" -o jsonpath='{.status.allocatable.memory}')
    ALLOC_PODS=$($KUBECTL get node "$NODE" -o jsonpath='{.status.allocatable.pods}')

    ALLOC_CPU_MC=$(cpu_to_millicores "$ALLOC_CPU")
    ALLOC_MEM_MI=$(memory_to_mi "$ALLOC_MEM")

    # Get current resource requests on node
    CPU_REQS=$($KUBECTL get pods --all-namespaces --field-selector spec.nodeName="$NODE" \
        -o jsonpath='{range .items[*]}{range .spec.containers[*]}{.resources.requests.cpu}{" "}{end}{end}' 2>/dev/null)
    MEM_REQS=$($KUBECTL get pods --all-namespaces --field-selector spec.nodeName="$NODE" \
        -o jsonpath='{range .items[*]}{range .spec.containers[*]}{.resources.requests.memory}{" "}{end}{end}' 2>/dev/null)

    USED_CPU_MC=$(sum_cpu_requests "$CPU_REQS")
    USED_MEM_MI=$(sum_memory_requests "$MEM_REQS")

    # Calculate available
    AVAIL_CPU_MC=$((ALLOC_CPU_MC - USED_CPU_MC))
    AVAIL_MEM_MI=$((ALLOC_MEM_MI - USED_MEM_MI))

    # Get running pod count
    RUNNING_PODS=$($KUBECTL get pods --all-namespaces --field-selector spec.nodeName="$NODE" --no-headers 2>/dev/null | wc -l | tr -d ' ')
    AVAIL_PODS=$((ALLOC_PODS - RUNNING_PODS))

    # Check if daemonset can schedule
    CAN_SCHEDULE="YES"
    REASONS=""

    if [[ "$STATUS" != "True" ]]; then
        CAN_SCHEDULE="NO"
        REASONS="NotReady"
    fi

    if [[ $AVAIL_CPU_MC -lt $DS_CPU_MC ]]; then
        CAN_SCHEDULE="NO"
        REASONS="${REASONS:+$REASONS, }InsufficientCPU"
    fi

    if [[ $AVAIL_MEM_MI -lt $DS_MEM_MI ]]; then
        CAN_SCHEDULE="NO"
        REASONS="${REASONS:+$REASONS, }InsufficientMemory"
    fi

    if [[ $AVAIL_PODS -lt 1 ]]; then
        CAN_SCHEDULE="NO"
        REASONS="${REASONS:+$REASONS, }MaxPodsReached"
    fi

    if [[ -n "$TAINT_LIST" ]]; then
        CAN_SCHEDULE="${CAN_SCHEDULE}*"
        REASONS="${REASONS:+$REASONS, }HasTaints"
    fi

    SCHEDULE_STATUS="$CAN_SCHEDULE${REASONS:+ ($REASONS)}"

    # Print detailed info
    echo ""
    echo "Node: $NODE"
    echo "  Ready:           $STATUS"
    echo "  Taints:          ${TAINT_LIST:-<none>}"
    echo "  Allocatable:     CPU=${ALLOC_CPU_MC}m  Mem=${ALLOC_MEM_MI}Mi  Pods=${ALLOC_PODS}"
    echo "  Requested:       CPU=${USED_CPU_MC}m  Mem=${USED_MEM_MI}Mi  Pods=${RUNNING_PODS}  (pod specs, not actual usage)"
    echo "  Available:       CPU=${AVAIL_CPU_MC}m  Mem=${AVAIL_MEM_MI}Mi  Pods=${AVAIL_PODS}  (scheduling headroom)"
    echo "  Can Schedule:    $SCHEDULE_STATUS"

    # Show over-provisioned pods if insufficient resources
    if [[ "$REASONS" == *"InsufficientCPU"* ]]; then
        show_overprovisioned_pods "$NODE" "cpu"
    elif [[ "$REASONS" == *"InsufficientMemory"* ]]; then
        show_overprovisioned_pods "$NODE" "memory"
    fi

    # Save to summary file
    SHORT_NAME=$(echo "$NODE" | cut -c1-44)
    printf "%-45s %8s %10s %8s %s\n" "$SHORT_NAME" "$AVAIL_CPU_MC" "$AVAIL_MEM_MI" "$AVAIL_PODS" "$SCHEDULE_STATUS" >> "$SUMMARY_FILE"
done

echo ""
echo "=============================================================================="
echo "SUMMARY TABLE"
echo "=============================================================================="
printf "%-45s %8s %10s %8s %s\n" "NODE" "CPU(m)" "MEM(Mi)" "PODS" "SCHEDULABLE"
printf "%-45s %8s %10s %8s %s\n" "----" "------" "-------" "----" "-----------"
# Show YES first, then NO
grep " YES" "$SUMMARY_FILE" 2>/dev/null || true
grep " NO" "$SUMMARY_FILE" 2>/dev/null || true

echo ""
echo "* = Requires tolerations (see below)"
echo ""
echo "NOTE: CPU/MEM values are from pod resource REQUESTS, not actual usage."
echo "      Use 'kubectl top nodes' to see real-time usage metrics."
echo ""
echo "DaemonSet Requirements: CPU=${DS_CPU_REQUEST} (${DS_CPU_MC}m), Memory=${DS_MEMORY_REQUEST} (${DS_MEM_MI}Mi)"

# Build taint keys list if taints exist
TAINT_KEYS=""
if [[ -n "$ALL_TAINTS_LIST" ]]; then
    echo ""
    echo "=============================================================================="
    echo "TAINTS FOUND"
    echo "=============================================================================="
    echo ""
    echo "The following taints were found in the cluster:"
    echo ""

    for taint in $ALL_TAINTS_LIST; do
        KEY=$(echo "$taint" | cut -d: -f1)
        EFFECT=$(echo "$taint" | cut -d: -f2)
        echo "  - $KEY ($EFFECT)"
        TAINT_KEYS="${TAINT_KEYS:+$TAINT_KEYS,}$KEY"
    done
fi
