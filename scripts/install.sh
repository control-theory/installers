#!/bin/bash
set -e

# ControlTheory Agent Installation Script
# Version
VERSION="v1.2.4"
# Supports both Docker and Kubernetes (Helm) installations
#
# Usage:
#   ./install.sh -i <org-id> --ds-token <t1> --cluster-token <t2> --config-endpoint <url> --data-endpoint <h:p> --cluster-name <name> -e <env>
#   ./install.sh -i <org-id> -t ds --ds-token <t> --config-endpoint <url> --data-endpoint <h:p> --cluster-name <name> -e <env>
#   ./install.sh -i <org-id> -p docker --docker-token <t> --config-endpoint <url> --data-endpoint <h:p> --cluster-name <name> -e <env>
#   ./install.sh -o uninstall
#   ./install.sh -o uninstall -p docker
#   ./install.sh -o status
#   ./install.sh -o preflight

# Embedded configuration
DS_ADMISSION_TOKEN=""
CLUSTER_ADMISSION_TOKEN=""
DOCKER_ADMISSION_TOKEN=""
CONFIG_ENDPOINT=""
DATA_ENDPOINT=""
DOCKER_IMAGE="controltheory/supervisor"
DOCKER_IMAGE_TAG="v1.3.11"

# Defaults
OPERATION="install"
PLATFORM="k8s"
TYPE="both"
HOST_PORT="false"
KUBECONFIG_FILE="$HOME/.kube/config"
NAMESPACE="${NAMESPACE:-controltheory}"
ORG_ID=""
CLUSTER_NAME=""
DEPLOYMENT_ENV=""

usage() {
  cat <<EOF
ControlTheory Agent Installer $VERSION

Usage: $0 [options]

General options:
  -o, --operation <op>   Operation: install, uninstall, status, preflight (default: install)
  -p, --platform <p>     Target platform: docker, k8s (default: k8s)
  -h, --help             Show this help message
  -v, --version          Show version

Options:
  -i, --org-id <id>                    Organization identifier (required for install)
      --config-endpoint <url>          Config endpoint URL (required for install)
      --data-endpoint <host:port>      Data endpoint address (required for install)
      --cluster-name <name>            Cluster/host name (required for k8s, optional for docker - defaults to 'docker')
  -e, --env <environment>              Deployment environment (required for install)

Options for docker platform:
      --docker-token <token>           Docker admission token (required for install)
      --docker-tag <tag>               Docker image tag (default: v1.3.9)

Options for k8s platform:
      --ds-token <token>               DaemonSet admission token (required for ds/both)
      --cluster-token <token>          Cluster admission token (required for cluster/both)
  -t, --type <ds|cluster|both>         Type to install (default: both)
      --host-port                      Expose OTLP ports (1757/1758) on node for DaemonSet
      --kubeconfig <file>              Path to kubeconfig file (default: ~/.kube/config)
  -n, --namespace <namespace>          Kubernetes namespace (default: controltheory)

Examples:
  $0 -i okz30akqj --ds-token <t1> --cluster-token <t2> --config-endpoint <url> --data-endpoint <h:p> --cluster-name mycluster -e prod
  $0 -i okz30akqj -t ds --ds-token <t> --config-endpoint <url> --data-endpoint <h:p> --cluster-name mycluster -e dev
  $0 -i okz30akqj -p docker --docker-token <t> --config-endpoint <url> --data-endpoint <h:p> --cluster-name myhost -e prod
  $0 -o uninstall
  $0 -o uninstall -p docker
  $0 -o status
  $0 -o status -p docker
  $0 -o preflight
  $0 -o preflight --kubeconfig ~/.kube/ctstage
EOF
  exit 1
}

# Parse arguments
while [ $# -gt 0 ]; do
  case "$1" in
    -o|--operation)
      OPERATION="$2"
      shift 2
      ;;
    -p|--platform)
      PLATFORM="$2"
      shift 2
      ;;
    -t|--type)
      TYPE="$2"
      shift 2
      ;;
    --docker-token)
      DOCKER_ADMISSION_TOKEN="$2"
      shift 2
      ;;
    --docker-tag)
      DOCKER_IMAGE_TAG="$2"
      shift 2
      ;;
    --ds-token)
      DS_ADMISSION_TOKEN="$2"
      shift 2
      ;;
    --cluster-token)
      CLUSTER_ADMISSION_TOKEN="$2"
      shift 2
      ;;
    --config-endpoint)
      CONFIG_ENDPOINT="$2"
      shift 2
      ;;
    --data-endpoint)
      DATA_ENDPOINT="$2"
      shift 2
      ;;
    -i|--org-id)
      ORG_ID="$2"
      shift 2
      ;;
    -e|--env)
      DEPLOYMENT_ENV="$2"
      shift 2
      ;;
    --cluster-name)
      CLUSTER_NAME="$2"
      shift 2
      ;;
    --kubeconfig)
      KUBECONFIG_FILE="$2"
      shift 2
      ;;
    -n|--namespace)
      NAMESPACE="$2"
      shift 2
      ;;
    --host-port)
      HOST_PORT="true"
      shift 1
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
      usage
      ;;
  esac
done

# Validate arguments

if [ "$OPERATION" != "install" ] && [ "$OPERATION" != "uninstall" ] && [ "$OPERATION" != "status" ] && [ "$OPERATION" != "preflight" ]; then
  echo "Error: Operation must be 'install', 'uninstall', 'status', or 'preflight'"
  usage
fi

if [ "$PLATFORM" != "docker" ] && [ "$PLATFORM" != "k8s" ]; then
  echo "Error: Platform must be 'docker' or 'k8s'"
  usage
fi

if [ "$PLATFORM" = "k8s" ]; then
  if [ "$TYPE" != "ds" ] && [ "$TYPE" != "cluster" ] && [ "$TYPE" != "both" ]; then
    echo "Error: Type must be 'ds', 'cluster', or 'both'"
    usage
  fi
fi

# Validate required configuration for install
validate_config() {
  # Validate common required options
  if [ -z "$ORG_ID" ]; then
    echo "Error: -i/--org-id is required for install"
    usage
  fi
  if [ -z "$CONFIG_ENDPOINT" ]; then
    echo "Error: --config-endpoint is required for install"
    usage
  fi
  if [ -z "$DATA_ENDPOINT" ]; then
    echo "Error: --data-endpoint is required for install"
    usage
  fi
  # cluster_name is required for k8s, optional for docker
  if [ -z "$CLUSTER_NAME" ] && [ "$PLATFORM" = "k8s" ]; then
    echo "Error: --cluster-name is required for k8s install"
    usage
  fi
  if [ -z "$DEPLOYMENT_ENV" ]; then
    echo "Error: -e/--env is required for install"
    usage
  fi

  # Validate tokens
  if [ "$PLATFORM" = "docker" ]; then
    if [ -z "$DOCKER_ADMISSION_TOKEN" ]; then
      echo "Error: --docker-token is required for docker install"
      usage
    fi
  elif [ "$PLATFORM" = "k8s" ]; then
    if [ "$TYPE" = "ds" ] || [ "$TYPE" = "both" ]; then
      if [ -z "$DS_ADMISSION_TOKEN" ]; then
        echo "Error: --ds-token is required for k8s ds/both install"
        usage
      fi
    fi
    if [ "$TYPE" = "cluster" ] || [ "$TYPE" = "both" ]; then
      if [ -z "$CLUSTER_ADMISSION_TOKEN" ]; then
        echo "Error: --cluster-token is required for k8s cluster/both install"
        usage
      fi
    fi
  fi
}

# Set kubectl/helm commands with kubeconfig (only for k8s platform)
KUBECTL="kubectl"
HELM="helm"
if [ "$PLATFORM" = "k8s" ] && [ -n "$KUBECONFIG_FILE" ]; then
  if [ ! -f "$KUBECONFIG_FILE" ]; then
    echo "Error: Kubeconfig file not found: $KUBECONFIG_FILE"
    usage
  fi
  KUBECTL="kubectl --kubeconfig $KUBECONFIG_FILE"
  HELM="helm --kubeconfig $KUBECONFIG_FILE"
fi

# Release names
RELEASE_NAME_DS="aigent-ds"
RELEASE_NAME_CLUSTER="aigent-cluster"
CONTAINER_NAME="aigent"

#
# Docker functions
#
docker_install() {
  echo "Installing ControlTheory Agent via Docker..."
  echo "Container Name: $CONTAINER_NAME"
  echo ""

  # Capture hostname for container
  HOST_NAME=$(hostname)

  # Build docker run command with optional CLUSTER_NAME
  # setting K8S_NODE_NAME temp fix.
  DOCKER_CMD="docker run -d \
    --name $CONTAINER_NAME \
    --hostname "aigent-docker" \
    --restart unless-stopped \
    --privileged \
    -v ./data:/data \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -v /var/lib/docker/containers:/var/lib/docker/containers:ro \
    -v /var/log:/var/log \
    -e CONTROLPLANE_ENDPOINT=$CONFIG_ENDPOINT \
    -e ADMISSION_TOKEN=$DOCKER_ADMISSION_TOKEN \
    -e BUTLER_ENDPOINT=$DATA_ENDPOINT \
    -e DEPLOYMENT_ENV=$DEPLOYMENT_ENV \
    -e K8S_NODE_NAME=$HOST_NAME \
    -e HOST_NAME=$HOST_NAME"

  # Default cluster name to "docker" for docker platform
  if [ -z "$CLUSTER_NAME" ]; then
    CLUSTER_NAME="docker"
  fi
  DOCKER_CMD="$DOCKER_CMD -e CLUSTER_NAME=$CLUSTER_NAME"

  DOCKER_CMD="$DOCKER_CMD \
    -p 4317:1757 \
    -p 4318:1758 \
    ${DOCKER_IMAGE}:${DOCKER_IMAGE_TAG}"

  eval "$DOCKER_CMD"

  echo ""
  echo "Docker installation complete!"
  echo "Container: $CONTAINER_NAME"
  echo ""
  echo "To check status:"
  echo "  docker ps | grep $CONTAINER_NAME"
  echo "  docker logs $CONTAINER_NAME"
}

docker_uninstall() {
  echo "Uninstalling ControlTheory Agent from Docker..."
  echo "Container Name: $CONTAINER_NAME"
  echo ""

  docker stop "$CONTAINER_NAME" 2>/dev/null || true
  docker rm "$CONTAINER_NAME" 2>/dev/null || true

  echo ""
  echo "Docker uninstallation complete!"
}

#
# Kubernetes functions
#

# Quick preflight check - warns if nodes have insufficient resources
quick_preflight_check() {
  local total_nodes=0
  local problem_nodes=0
  local ds_cpu_mc=$(cpu_to_millicores "$PREFLIGHT_CPU_REQUEST")
  local ds_mem_mi=$(memory_to_mi "$PREFLIGHT_MEMORY_REQUEST")

  local nodes=$($KUBECTL get nodes -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)
  [[ -z "$nodes" ]] && return

  for node in $nodes; do
    total_nodes=$((total_nodes + 1))

    local alloc_cpu=$($KUBECTL get node "$node" -o jsonpath='{.status.allocatable.cpu}' 2>/dev/null)
    local alloc_mem=$($KUBECTL get node "$node" -o jsonpath='{.status.allocatable.memory}' 2>/dev/null)
    local alloc_cpu_mc=$(cpu_to_millicores "$alloc_cpu")
    local alloc_mem_mi=$(memory_to_mi "$alloc_mem")

    local cpu_reqs=$($KUBECTL get pods --all-namespaces --field-selector spec.nodeName="$node" \
        -o jsonpath='{range .items[*]}{range .spec.containers[*]}{.resources.requests.cpu}{" "}{end}{end}' 2>/dev/null)
    local mem_reqs=$($KUBECTL get pods --all-namespaces --field-selector spec.nodeName="$node" \
        -o jsonpath='{range .items[*]}{range .spec.containers[*]}{.resources.requests.memory}{" "}{end}{end}' 2>/dev/null)

    local used_cpu_mc=$(sum_cpu_requests "$cpu_reqs")
    local used_mem_mi=$(sum_memory_requests "$mem_reqs")

    local avail_cpu_mc=$((alloc_cpu_mc - used_cpu_mc))
    local avail_mem_mi=$((alloc_mem_mi - used_mem_mi))

    if [[ $avail_cpu_mc -lt $ds_cpu_mc ]] || [[ $avail_mem_mi -lt $ds_mem_mi ]]; then
      problem_nodes=$((problem_nodes + 1))
    fi
  done

  if [[ $problem_nodes -gt 0 ]]; then
    echo ""
    echo "WARNING: $problem_nodes of $total_nodes nodes have insufficient resources (use -o preflight for details)"
    echo ""
  fi
}

k8s_install_ds() {
  echo "Installing AIgent DaemonSet (node log collection)..."
  quick_preflight_check

  local HELM_ARGS=(
    --namespace="$NAMESPACE"
    --set daemonset.controlplane.admission_token="$DS_ADMISSION_TOKEN"
    --set daemonset.controlplane.endpoint="$CONFIG_ENDPOINT"
    --set daemonset.butler_endpoint="$DATA_ENDPOINT"
    --set daemonset.cluster_name="$CLUSTER_NAME"
    --set daemonset.deployment_env="$DEPLOYMENT_ENV"
  )

  if [ "$HOST_PORT" = "true" ]; then
    HELM_ARGS+=(--set hostPort.enabled=true)
    echo "  Host Port: enabled (1757/1758)"
  fi

  $HELM upgrade --install --create-namespace "$RELEASE_NAME_DS" ct-helm/aigent-ds "${HELM_ARGS[@]}"
}

k8s_install_cluster() {
  echo "Installing AIgent Cluster Agent (k8s events)..."
  $HELM upgrade --install --create-namespace "$RELEASE_NAME_CLUSTER" ct-helm/aigent-cluster \
    --namespace="$NAMESPACE" \
    --set deployment.controlplane.admission_token="$CLUSTER_ADMISSION_TOKEN" \
    --set deployment.controlplane.endpoint="$CONFIG_ENDPOINT" \
    --set deployment.butler_endpoint="$DATA_ENDPOINT" \
    --set deployment.cluster_name="$CLUSTER_NAME" \
    --set deployment.deployment_env="$DEPLOYMENT_ENV"
}

k8s_uninstall_ds() {
  echo "Uninstalling AIgent DaemonSet..."
  $HELM uninstall "$RELEASE_NAME_DS" --namespace="$NAMESPACE" 2>/dev/null || echo "DaemonSet release not found"
}

k8s_uninstall_cluster() {
  echo "Uninstalling AIgent Cluster Agent..."
  $HELM uninstall "$RELEASE_NAME_CLUSTER" --namespace="$NAMESPACE" 2>/dev/null || echo "Cluster Agent release not found"
}

k8s_install() {
  echo "Installing ControlTheory Agent on Kubernetes..."
  echo "Cluster Name: $CLUSTER_NAME"
  echo "Deployment Environment: $DEPLOYMENT_ENV"
  echo "Namespace: $NAMESPACE"
  echo "Type: $TYPE"
  if [ "$HOST_PORT" = "true" ]; then
    echo "Host Port: enabled (1757/1758)"
  fi
  if [ -n "$KUBECONFIG_FILE" ]; then
    echo "Kubeconfig: $KUBECONFIG_FILE"
  fi
  echo ""

  # Add helm repo
  echo "Adding ct-helm repository..."
  $HELM repo add ct-helm https://control-theory.github.io/helm-charts 2>/dev/null || true
  $HELM repo update ct-helm
  echo ""

  case "$TYPE" in
    ds)
      k8s_install_ds
      ;;
    cluster)
      k8s_install_cluster
      ;;
    both)
      k8s_install_ds
      echo ""
      k8s_install_cluster
      ;;
  esac

  echo ""
  echo "Kubernetes installation complete!"
  echo "Namespace: $NAMESPACE"
  if [ "$TYPE" = "ds" ] || [ "$TYPE" = "both" ]; then
    echo "DaemonSet Release: $RELEASE_NAME_DS"
  fi
  if [ "$TYPE" = "cluster" ] || [ "$TYPE" = "both" ]; then
    echo "Cluster Agent Release: $RELEASE_NAME_CLUSTER"
  fi
  echo ""
  echo "To check status:"
  echo "  $KUBECTL get pods -n $NAMESPACE"
}

k8s_uninstall() {
  echo "Uninstalling ControlTheory Agent from Kubernetes..."
  echo "Namespace: $NAMESPACE"
  echo "Type: $TYPE"
  if [ -n "$KUBECONFIG_FILE" ]; then
    echo "Kubeconfig: $KUBECONFIG_FILE"
  fi
  echo ""

  case "$TYPE" in
    ds)
      k8s_uninstall_ds
      ;;
    cluster)
      k8s_uninstall_cluster
      ;;
    both)
      k8s_uninstall_ds
      k8s_uninstall_cluster
      ;;
  esac

  echo ""
  echo "Kubernetes uninstallation complete!"
}

#
# Status functions
#
k8s_status() {
  echo ""
  echo "=============================================================================="
  echo "CONTROLTHEORY AGENT STATUS (Kubernetes)"
  echo "=============================================================================="
  echo "Date:        $(date '+%Y-%m-%d %H:%M:%S')"
  echo "Kubeconfig:  $KUBECONFIG_FILE"
  echo "Namespace:   $NAMESPACE"
  echo "=============================================================================="
  echo ""

  # Check helm releases
  echo "HELM RELEASES"
  echo "-------------"
  local ds_release=$($HELM list -n "$NAMESPACE" -f "^${RELEASE_NAME_DS}$" -q 2>/dev/null)
  local cluster_release=$($HELM list -n "$NAMESPACE" -f "^${RELEASE_NAME_CLUSTER}$" -q 2>/dev/null)

  if [[ -n "$ds_release" ]]; then
    local ds_info=$($HELM list -n "$NAMESPACE" -f "^${RELEASE_NAME_DS}$" --output json 2>/dev/null | grep -o '"status":"[^"]*"' | cut -d'"' -f4)
    local ds_version=$($HELM list -n "$NAMESPACE" -f "^${RELEASE_NAME_DS}$" --output json 2>/dev/null | grep -o '"chart":"[^"]*"' | cut -d'"' -f4)
    printf "  %-20s %-12s %s\n" "$RELEASE_NAME_DS" "$ds_info" "$ds_version"
  else
    printf "  %-20s %-12s\n" "$RELEASE_NAME_DS" "NOT INSTALLED"
  fi

  if [[ -n "$cluster_release" ]]; then
    local cluster_info=$($HELM list -n "$NAMESPACE" -f "^${RELEASE_NAME_CLUSTER}$" --output json 2>/dev/null | grep -o '"status":"[^"]*"' | cut -d'"' -f4)
    local cluster_version=$($HELM list -n "$NAMESPACE" -f "^${RELEASE_NAME_CLUSTER}$" --output json 2>/dev/null | grep -o '"chart":"[^"]*"' | cut -d'"' -f4)
    printf "  %-20s %-12s %s\n" "$RELEASE_NAME_CLUSTER" "$cluster_info" "$cluster_version"
  else
    printf "  %-20s %-12s\n" "$RELEASE_NAME_CLUSTER" "NOT INSTALLED"
  fi

  echo ""

  # Check pods
  echo "PODS"
  echo "----"
  local pods=$($KUBECTL get pods -n "$NAMESPACE" -l 'app.kubernetes.io/name in (aigent-ds, aigent-cluster)' --no-headers 2>/dev/null)
  if [[ -n "$pods" ]]; then
    printf "  %-50s %-12s %-10s %s\n" "NAME" "STATUS" "RESTARTS" "AGE"
    printf "  %-50s %-12s %-10s %s\n" "----" "------" "--------" "---"
    $KUBECTL get pods -n "$NAMESPACE" -l 'app.kubernetes.io/name in (aigent-ds, aigent-cluster)' --no-headers 2>/dev/null | while read -r line; do
      local name=$(echo "$line" | awk '{print $1}')
      local ready=$(echo "$line" | awk '{print $2}')
      local status=$(echo "$line" | awk '{print $3}')
      local restarts=$(echo "$line" | awk '{print $4}')
      local age=$(echo "$line" | awk '{print $5}')
      printf "  %-50s %-12s %-10s %s\n" "$name" "$status" "$restarts" "$age"
    done
  else
    echo "  No ControlTheory pods found in namespace $NAMESPACE"
  fi

  echo ""

  # Summary
  echo "SUMMARY"
  echo "-------"
  if [[ -n "$ds_release" ]] || [[ -n "$cluster_release" ]]; then
    [[ -n "$ds_release" ]] && echo "  DaemonSet:     INSTALLED"
    [[ -z "$ds_release" ]] && echo "  DaemonSet:     not installed"
    [[ -n "$cluster_release" ]] && echo "  Cluster Agent: INSTALLED"
    [[ -z "$cluster_release" ]] && echo "  Cluster Agent: not installed"
  else
    echo "  ControlTheory Agent is NOT installed"
  fi
}

docker_status() {
  echo ""
  echo "=============================================================================="
  echo "CONTROLTHEORY AGENT STATUS (Docker)"
  echo "=============================================================================="
  echo "Date:        $(date '+%Y-%m-%d %H:%M:%S')"
  echo "Container:   $CONTAINER_NAME"
  echo "=============================================================================="
  echo ""

  # Check container
  echo "CONTAINER"
  echo "---------"
  local container_info=$(docker ps -a --filter "name=^${CONTAINER_NAME}$" --format "{{.Status}}\t{{.Image}}\t{{.Ports}}" 2>/dev/null)

  if [[ -n "$container_info" ]]; then
    local status=$(echo "$container_info" | cut -f1)
    local image=$(echo "$container_info" | cut -f2)
    local ports=$(echo "$container_info" | cut -f3)
    echo "  Name:    $CONTAINER_NAME"
    echo "  Status:  $status"
    echo "  Image:   $image"
    echo "  Ports:   ${ports:-<none>}"
  else
    echo "  Container '$CONTAINER_NAME' not found"
  fi

  echo ""

  # Summary
  echo "SUMMARY"
  echo "-------"
  if [[ -n "$container_info" ]]; then
    if echo "$container_info" | grep -qi "^up"; then
      echo "  ControlTheory Agent is RUNNING"
    else
      echo "  ControlTheory Agent is STOPPED"
    fi
  else
    echo "  ControlTheory Agent is NOT installed"
  fi
}

#
# Preflight Check - Analyze cluster nodes for DaemonSet placement
#
PREFLIGHT_VERSION="v1.2.1"
PREFLIGHT_CPU_REQUEST="200m"
PREFLIGHT_MEMORY_REQUEST="500Mi"

# Convert CPU to millicores
cpu_to_millicores() {
    local cpu="$1"
    if [[ "$cpu" =~ ^([0-9]+)m$ ]]; then
        echo "${BASH_REMATCH[1]}"
    elif [[ "$cpu" =~ ^([0-9]+)$ ]]; then
        echo "$((${BASH_REMATCH[1]} * 1000))"
    elif [[ "$cpu" =~ ^([0-9]+)\.([0-9]+)$ ]]; then
        local whole="${BASH_REMATCH[1]}"
        local frac="${BASH_REMATCH[2]}"
        frac=$(printf "%-3s" "$frac" | tr ' ' '0' | cut -c1-3)
        echo "$((whole * 1000 + 10#$frac))"
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
        echo "$((${BASH_REMATCH[1]} / 1024 / 1024))"
    else
        echo "0"
    fi
}

# Sum CPU requests
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

# Show over-provisioned pods on a node
show_overprovisioned_pods() {
    local node="$1"
    local sort_by="$2"

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

    $KUBECTL get pods --all-namespaces --field-selector spec.nodeName="$node" \
        -o jsonpath='{range .items[*]}{.metadata.namespace}{"\t"}{.metadata.name}{"\t"}{range .spec.containers[*]}{.resources.requests.cpu}{" "}{end}{"\t"}{range .spec.containers[*]}{.resources.requests.memory}{" "}{end}{"\n"}{end}' 2>/dev/null | \
    while IFS=$'\t' read -r ns name cpu_reqs mem_reqs; do
        [[ -z "$name" ]] && continue

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
                mc=$((whole * 1000 + 10#$frac))
            else
                mc=0
            fi
            pod_cpu_mc=$((pod_cpu_mc + mc))
        done

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

        local metrics_line=$(grep "^${ns}[[:space:]]" /tmp/node_metrics_$$ | grep "[[:space:]]${name}[[:space:]]" 2>/dev/null | head -1)
        [[ -z "$metrics_line" ]] && continue

        local actual_cpu_raw=$(echo "$metrics_line" | awk '{print $3}')
        local actual_mem_raw=$(echo "$metrics_line" | awk '{print $4}')

        local actual_cpu_mc=0
        if [[ "$actual_cpu_raw" =~ ^([0-9]+)m$ ]]; then
            actual_cpu_mc="${BASH_REMATCH[1]}"
        elif [[ "$actual_cpu_raw" =~ ^([0-9]+)$ ]]; then
            actual_cpu_mc=$((${BASH_REMATCH[1]} * 1000))
        fi

        local actual_mem_mi=0
        if [[ "$actual_mem_raw" =~ ^([0-9]+)Mi$ ]]; then
            actual_mem_mi="${BASH_REMATCH[1]}"
        elif [[ "$actual_mem_raw" =~ ^([0-9]+)Gi$ ]]; then
            actual_mem_mi=$((${BASH_REMATCH[1]} * 1024))
        elif [[ "$actual_mem_raw" =~ ^([0-9]+)Ki$ ]]; then
            actual_mem_mi=$((${BASH_REMATCH[1]} / 1024))
        fi

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

preflight_check() {
    echo ""
    echo "=============================================================================="
    echo "DAEMONSET PLACEMENT ANALYSIS                                   $PREFLIGHT_VERSION"
    echo "=============================================================================="
    echo "Date:              $(date '+%Y-%m-%d %H:%M:%S')"
    echo "Kubeconfig:        $KUBECONFIG_FILE"
    echo "DaemonSet CPU:     $PREFLIGHT_CPU_REQUEST"
    echo "DaemonSet Memory:  $PREFLIGHT_MEMORY_REQUEST"
    echo "=============================================================================="
    echo ""

    local DS_CPU_MC=$(cpu_to_millicores "$PREFLIGHT_CPU_REQUEST")
    local DS_MEM_MI=$(memory_to_mi "$PREFLIGHT_MEMORY_REQUEST")

    # Get PriorityClasses
    echo "PRIORITY CLASSES"
    echo "----------------"
    local PRIORITY_CLASSES=$($KUBECTL get priorityclasses -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.value}{"\n"}{end}' 2>/dev/null | sort -t$'\t' -k2 -rn)
    if [[ -n "$PRIORITY_CLASSES" ]]; then
        printf "%-30s %s\n" "NAME" "VALUE"
        printf "%-30s %s\n" "----" "-----"
        echo "$PRIORITY_CLASSES" | while read -r line; do
            local NAME=$(echo "$line" | cut -f1)
            local VALUE=$(echo "$line" | cut -f2)
            printf "%-30s %s\n" "$NAME" "$VALUE"
        done
    else
        echo "  No PriorityClasses found (using default scheduling priority)"
    fi
    echo ""

    # Get all nodes
    local NODES=$($KUBECTL get nodes -o jsonpath='{.items[*].metadata.name}')

    if [[ -z "$NODES" ]]; then
        echo "Error: No nodes found or unable to connect to cluster"
        exit 1
    fi

    local ALL_TAINTS_LIST=""
    local SUMMARY_FILE=$(mktemp)
    trap "rm -f $SUMMARY_FILE /tmp/node_metrics_$$ 2>/dev/null" EXIT

    echo "NODE DETAILS"
    echo "------------"

    for NODE in $NODES; do
        local STATUS=$($KUBECTL get node "$NODE" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')

        local TAINTS_JSON=$($KUBECTL get node "$NODE" -o jsonpath='{.spec.taints}')
        local TAINT_LIST=""
        if [[ -n "$TAINTS_JSON" && "$TAINTS_JSON" != "null" ]]; then
            TAINT_LIST=$($KUBECTL get node "$NODE" -o jsonpath='{range .spec.taints[*]}{.key}={.value}:{.effect}{","}{end}' | sed 's/,$//')

            IFS=',' read -ra TAINT_ARR <<< "$TAINT_LIST"
            for t in "${TAINT_ARR[@]}"; do
                if [[ -n "$t" ]]; then
                    local KEY=$(echo "$t" | cut -d'=' -f1)
                    local EFFECT=$(echo "$t" | grep -oE ':(NoSchedule|NoExecute|PreferNoSchedule)$' | tr -d ':')
                    local TAINT_ENTRY="$KEY:$EFFECT"
                    if [[ ! "$ALL_TAINTS_LIST" =~ "$TAINT_ENTRY" ]]; then
                        ALL_TAINTS_LIST="${ALL_TAINTS_LIST:+$ALL_TAINTS_LIST }$TAINT_ENTRY"
                    fi
                fi
            done
        fi

        local ALLOC_CPU=$($KUBECTL get node "$NODE" -o jsonpath='{.status.allocatable.cpu}')
        local ALLOC_MEM=$($KUBECTL get node "$NODE" -o jsonpath='{.status.allocatable.memory}')
        local ALLOC_PODS=$($KUBECTL get node "$NODE" -o jsonpath='{.status.allocatable.pods}')

        local ALLOC_CPU_MC=$(cpu_to_millicores "$ALLOC_CPU")
        local ALLOC_MEM_MI=$(memory_to_mi "$ALLOC_MEM")

        local CPU_REQS=$($KUBECTL get pods --all-namespaces --field-selector spec.nodeName="$NODE" \
            -o jsonpath='{range .items[*]}{range .spec.containers[*]}{.resources.requests.cpu}{" "}{end}{end}' 2>/dev/null)
        local MEM_REQS=$($KUBECTL get pods --all-namespaces --field-selector spec.nodeName="$NODE" \
            -o jsonpath='{range .items[*]}{range .spec.containers[*]}{.resources.requests.memory}{" "}{end}{end}' 2>/dev/null)

        local USED_CPU_MC=$(sum_cpu_requests "$CPU_REQS")
        local USED_MEM_MI=$(sum_memory_requests "$MEM_REQS")

        local AVAIL_CPU_MC=$((ALLOC_CPU_MC - USED_CPU_MC))
        local AVAIL_MEM_MI=$((ALLOC_MEM_MI - USED_MEM_MI))

        local RUNNING_PODS=$($KUBECTL get pods --all-namespaces --field-selector spec.nodeName="$NODE",status.phase!=Succeeded,status.phase!=Failed --no-headers 2>/dev/null | wc -l | tr -d ' ')
        local AVAIL_PODS=$((ALLOC_PODS - RUNNING_PODS))

        local CAN_SCHEDULE="YES"
        local REASONS=""

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

        local SCHEDULE_STATUS="$CAN_SCHEDULE${REASONS:+ ($REASONS)}"

        echo ""
        echo "Node: $NODE"
        echo "  Ready:           $STATUS"
        echo "  Taints:          ${TAINT_LIST:-<none>}"
        echo "  Allocatable:     CPU=${ALLOC_CPU_MC}m  Mem=${ALLOC_MEM_MI}Mi  Pods=${ALLOC_PODS}"
        echo "  Requested:       CPU=${USED_CPU_MC}m  Mem=${USED_MEM_MI}Mi  Pods=${RUNNING_PODS}  (pod specs, not actual usage)"
        echo "  Available:       CPU=${AVAIL_CPU_MC}m  Mem=${AVAIL_MEM_MI}Mi  Pods=${AVAIL_PODS}  (scheduling headroom)"
        echo "  Can Schedule:    $SCHEDULE_STATUS"

        if [[ "$REASONS" == *"InsufficientCPU"* ]]; then
            show_overprovisioned_pods "$NODE" "cpu"
        elif [[ "$REASONS" == *"InsufficientMemory"* ]]; then
            show_overprovisioned_pods "$NODE" "memory"
        fi

        local SHORT_NAME=$(echo "$NODE" | cut -c1-44)
        printf "%-45s %8s %10s %8s %s\n" "$SHORT_NAME" "$AVAIL_CPU_MC" "$AVAIL_MEM_MI" "$AVAIL_PODS" "$SCHEDULE_STATUS" >> "$SUMMARY_FILE"
    done

    echo ""
    echo "=============================================================================="
    echo "SUMMARY TABLE"
    echo "=============================================================================="
    printf "%-45s %8s %10s %8s %s\n" "NODE" "CPU(m)" "MEM(Mi)" "PODS" "SCHEDULABLE"
    printf "%-45s %8s %10s %8s %s\n" "----" "------" "-------" "----" "-----------"
    grep " YES" "$SUMMARY_FILE" 2>/dev/null || true
    grep " NO" "$SUMMARY_FILE" 2>/dev/null || true

    echo ""
    echo "* = Requires tolerations (see below)"
    echo ""
    echo "NOTE: CPU/MEM values are from pod resource REQUESTS, not actual usage."
    echo "      Use 'kubectl top nodes' to see real-time usage metrics."
    echo ""
    echo "DaemonSet Requirements: CPU=${PREFLIGHT_CPU_REQUEST} (${DS_CPU_MC}m), Memory=${PREFLIGHT_MEMORY_REQUEST} (${DS_MEM_MI}Mi)"

    if [[ -n "$ALL_TAINTS_LIST" ]]; then
        echo ""
        echo "=============================================================================="
        echo "TAINTS FOUND"
        echo "=============================================================================="
        echo ""
        echo "The following taints were found in the cluster:"
        echo ""

        for taint in $ALL_TAINTS_LIST; do
            local KEY=$(echo "$taint" | cut -d: -f1)
            local EFFECT=$(echo "$taint" | cut -d: -f2)
            echo "  - $KEY ($EFFECT)"
        done
    fi
}

#
# Main
#

# Only validate config for install operations
if [ "$OPERATION" = "install" ]; then
  validate_config
fi

# Handle status operation
if [ "$OPERATION" = "status" ]; then
  if [ "$PLATFORM" = "k8s" ]; then
    k8s_status
  else
    docker_status
  fi
# Handle preflight operation (k8s only)
elif [ "$OPERATION" = "preflight" ]; then
  if [ "$PLATFORM" != "k8s" ]; then
    echo "Error: preflight operation is only available for k8s platform"
    exit 1
  fi
  preflight_check
else
  case "$PLATFORM" in
    docker)
      case "$OPERATION" in
        install)
          docker_install
          ;;
        uninstall)
          docker_uninstall
          ;;
      esac
      ;;
    k8s)
      case "$OPERATION" in
        install)
          k8s_install
          ;;
        uninstall)
          k8s_uninstall
          ;;
      esac
      ;;
  esac
fi

echo ""
echo "Completed: $(date -u '+%Y-%m-%d %H:%M:%S UTC') | $VERSION"
