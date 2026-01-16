#!/bin/sh
set -e

# ControlTheory Agent Installation Script
# Supports both Docker and Kubernetes (Helm) installations
#
# Usage:
#   ./install.sh -i <org-id> --ds-token <t1> --cluster-token <t2> --config-endpoint <url> --data-endpoint <h:p> --cluster-name <name> -e <env>
#   ./install.sh -i <org-id> -t ds --ds-token <t> --config-endpoint <url> --data-endpoint <h:p> --cluster-name <name> -e <env>
#   ./install.sh -i <org-id> -p docker --docker-token <t> --config-endpoint <url> --data-endpoint <h:p> --cluster-name <name> -e <env>
#   ./install.sh -o uninstall
#   ./install.sh -o uninstall -p docker

# Embedded configuration
DS_ADMISSION_TOKEN=""
CLUSTER_ADMISSION_TOKEN=""
DOCKER_ADMISSION_TOKEN=""
CONFIG_ENDPOINT=""
DATA_ENDPOINT=""
DOCKER_IMAGE="controltheory/supervisor"
DOCKER_IMAGE_TAG="v1.3.9"

# Defaults
OPERATION="install"
PLATFORM="k8s"
TYPE="both"
KUBECONFIG_FILE="$HOME/.kube/config"
NAMESPACE="${NAMESPACE:-controltheory}"
ORG_ID=""
CLUSTER_NAME=""
DEPLOYMENT_ENV=""

usage() {
  echo "ControlTheory Agent Installer"
  echo ""
  echo "Usage: $0 [options]"
  echo ""
  echo "General options:"
  echo "  -o, --operation <install|uninstall>  Operation to perform (default: install)"
  echo "  -p, --platform <docker|k8s>          Target platform (default: k8s)"
  echo ""
  echo "Options:"
  echo "  -i, --org-id <id>                    Organization identifier (required for install)"
  echo "      --config-endpoint <url>          Config endpoint URL (required for install)"
  echo "      --data-endpoint <host:port>      Data endpoint address (required for install)"
  echo "      --cluster-name <name>            Cluster/host name (required for k8s, optional for docker - defaults to 'docker')"
  echo "  -e, --env <environment>              Deployment environment (required for install)"
  echo ""
  echo "Options for docker platform:"
  echo "      --docker-token <token>           Docker admission token (required for install)"
  echo "      --docker-tag <tag>               Docker image tag (default: v1.3.9)"
  echo ""
  echo "Options for k8s platform:"
  echo "      --ds-token <token>               DaemonSet admission token (required for ds/both)"
  echo "      --cluster-token <token>          Cluster admission token (required for cluster/both)"
  echo "  -t, --type <ds|cluster|both>          Type to install (default: both)"
  echo "      --kubeconfig <file>              Path to kubeconfig file (default: ~/.kube/config)"
  echo "  -n, --namespace <namespace>          Kubernetes namespace (default: controltheory)"
  echo ""
  echo "Examples:"
  echo "  $0 -i okz30akqj --ds-token <t1> --cluster-token <t2> --config-endpoint <url> --data-endpoint <h:p> --cluster-name mycluster -e prod"
  echo "  $0 -i okz30akqj -t ds --ds-token <t> --config-endpoint <url> --data-endpoint <h:p> --cluster-name mycluster -e dev"
  echo "  $0 -i okz30akqj -p docker --docker-token <t> --config-endpoint <url> --data-endpoint <h:p> --cluster-name myhost -e prod"
  echo "  $0 -o uninstall"
  echo "  $0 -o uninstall -p docker"
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
    -h|--help)
      usage
      ;;
    *)
      echo "Unknown option: $1"
      usage
      ;;
  esac
done

# Validate arguments

if [ "$OPERATION" != "install" ] && [ "$OPERATION" != "uninstall" ]; then
  echo "Error: Operation must be 'install' or 'uninstall'"
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

  # Build docker run command with optional CLUSTER_NAME
  DOCKER_CMD="docker run -d \
    --name $CONTAINER_NAME \
    --restart unless-stopped \
    --privileged \
    -v ./data:/data \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -v /var/lib/docker/containers:/var/lib/docker/containers:ro \
    -v /var/log:/var/log \
    -e CONTROLPLANE_ENDPOINT=$CONFIG_ENDPOINT \
    -e ADMISSION_TOKEN=$DOCKER_ADMISSION_TOKEN \
    -e BUTLER_ENDPOINT=$DATA_ENDPOINT \
    -e DEPLOYMENT_ENV=$DEPLOYMENT_ENV"

  # Default cluster name to "docker" for docker platform
  if [ -z "$CLUSTER_NAME" ]; then
    CLUSTER_NAME="docker"
  fi
  DOCKER_CMD="$DOCKER_CMD -e CLUSTER_NAME=$CLUSTER_NAME"

  DOCKER_CMD="$DOCKER_CMD \
    -p 4317:4317 \
    -p 4318:4318 \
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
k8s_install_ds() {
  echo "Installing AIgent DaemonSet (node log collection)..."
  $HELM upgrade --install --create-namespace "$RELEASE_NAME_DS" ct-helm/aigent-ds \
    --namespace="$NAMESPACE" \
    --set daemonset.controlplane.admission_token="$DS_ADMISSION_TOKEN" \
    --set daemonset.controlplane.endpoint="$CONFIG_ENDPOINT" \
    --set daemonset.cluster_name="$CLUSTER_NAME" \
    --set daemonset.deployment_env="$DEPLOYMENT_ENV"

  echo "Waiting for DaemonSet to be ready..."
  $KUBECTL rollout status daemonset/"$RELEASE_NAME_DS" -n "$NAMESPACE" --timeout=120s
}

k8s_install_cluster() {
  echo "Installing AIgent Cluster Agent (k8s events)..."
  $HELM upgrade --install --create-namespace "$RELEASE_NAME_CLUSTER" ct-helm/aigent-cluster \
    --namespace="$NAMESPACE" \
    --set deployment.controlplane.admission_token="$CLUSTER_ADMISSION_TOKEN" \
    --set deployment.controlplane.endpoint="$CONFIG_ENDPOINT" \
    --set deployment.cluster_name="$CLUSTER_NAME" \
    --set deployment.deployment_env="$DEPLOYMENT_ENV"

  echo "Waiting for Cluster Agent to be ready..."
  $KUBECTL rollout status deployment/"$RELEASE_NAME_CLUSTER" -n "$NAMESPACE" --timeout=120s
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
# Main
#

# Only validate config for install operations
if [ "$OPERATION" = "install" ]; then
  validate_config
fi

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
