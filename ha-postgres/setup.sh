#!/bin/bash
#
# OpenEverest HA PostgreSQL — Killercoda background setup.
#
# Wired into index.json as details.intro.background, so it runs unattended while the user
# reads the intro. Killercoda captures stdout/stderr at /var/log/killercoda.
#
# Two contracts this script must honour:
#   1. It never blocks on input. Every wait is bounded by a timeout.
#   2. It ALWAYS creates the sentinel /tmp/openeverest-setup-done, which step1.md waits
#      on. A setup failure has to degrade into a slower lab, never a hung one — which is
#      why there is deliberately no `set -e` here and why the sentinel is written from an
#      EXIT trap.

SENTINEL=/tmp/openeverest-setup-done
trap 'touch "$SENTINEL"' EXIT

export DEBIAN_FRONTEND=noninteractive
export HELM_CACHE_HOME=/root/.cache/helm

# Pinned to the exact versions the scenario steps install.
OE_CHART_VERSION="2.0.0-dev.2"
PROVIDER_VERSION="0.1.0"
MANIFEST=/root/pg-ha-demo.yaml

# Images the lab pulls, resolved from the pinned charts and the provider's version
# catalogue (default bundle 18.4-1). Warming these is the single biggest speed-up.
PREPULL_IMAGES=(
  "ghcr.io/openeverest/openeverest-dev:${OE_CHART_VERSION}"
  "ghcr.io/openeverest/plugin-hub:0.1.14"
  "ghcr.io/openeverest/provider-percona-postgresql:${PROVIDER_VERSION}"
  "percona/percona-postgresql-operator:3.0.0"
  "percona/percona-distribution-postgresql:18.4-1"
  "percona/percona-pgbouncer:1.25.2-1"
  "percona/percona-pgbackrest:2.58.0-2"
)

log()  { echo "[setup $(date -u +%H:%M:%S)] $*"; }
warn() { echo "[setup $(date -u +%H:%M:%S)] WARN: $*" >&2; }

# wait_for <timeout-seconds> <description> <command...>
# Polls the command until it succeeds or the timeout expires. Returns 1 on timeout so the
# caller can decide whether that is fatal (it never is, here).
wait_for() {
  local timeout=$1 desc=$2
  shift 2
  local deadline=$(( SECONDS + timeout ))
  until "$@" >/dev/null 2>&1; do
    if (( SECONDS >= deadline )); then
      warn "timed out after ${timeout}s waiting for ${desc}"
      return 1
    fi
    sleep 3
  done
  log "ok: ${desc}"
}

# ---------------------------------------------------------------- cluster readiness ----

if ! command -v kubectl >/dev/null 2>&1; then
  warn "kubectl not found on this image — the scenario needs a Kubernetes backend"
  exit 0
fi

wait_for 180 "kube-apiserver to answer" kubectl get --raw=/readyz

all_nodes_ready() {
  local total ready
  total=$(kubectl get nodes --no-headers 2>/dev/null | wc -l)
  [ "$total" -ge 1 ] || return 1
  ready=$(kubectl get nodes --no-headers 2>/dev/null | awk '$2 == "Ready"' | wc -l)
  [ "$ready" -eq "$total" ]
}
wait_for 180 "all nodes to report Ready" all_nodes_ready

# --------------------------------------------------------------------------- helm ------

if command -v helm >/dev/null 2>&1; then
  log "helm already present: $(helm version --short 2>/dev/null)"
else
  log "helm not found, installing..."
  if curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash >/dev/null 2>&1; then
    log "helm installed: $(helm version --short 2>/dev/null)"
  else
    warn "helm install failed — step 1 will not work until helm is available"
  fi
fi

# ------------------------------------------------------------------- storage class -----

# The Instance asks for a PVC per engine replica. Without a default StorageClass those
# PVCs stay Pending forever and the cluster never reaches Ready.
default_sc_exists() {
  kubectl get storageclass -o jsonpath='{.items[?(@.metadata.annotations.storageclass\.kubernetes\.io/default-class=="true")].metadata.name}' 2>/dev/null \
    | grep -q .
}
if ! wait_for 90 "a default StorageClass" default_sc_exists; then
  warn "no default StorageClass — PVCs will stay Pending and step 2 will not pass"
  kubectl get storageclass 2>&1 | sed 's/^/    /'
fi

# ------------------------------------------------------------------- chart repo --------

if helm repo add openeverest https://openeverest.github.io/helm-charts/ --force-update >/dev/null 2>&1 \
   && helm repo update >/dev/null 2>&1; then
  log "ok: openeverest chart repo added and indexed"
else
  warn "could not reach the OpenEverest chart repo — step 1 will retry"
fi

# Pre-flight the pinned version so a chart that has been pulled fails here, in the log,
# rather than in front of the user halfway through step 1.
if helm show chart openeverest/openeverest --version "$OE_CHART_VERSION" --devel >/dev/null 2>&1; then
  log "ok: openeverest chart ${OE_CHART_VERSION} resolves"
else
  warn "openeverest chart ${OE_CHART_VERSION} did not resolve from the repo"
fi

# ------------------------------------------------------- instance manifest fallback ----

# step2.md writes this same file with a heredoc. Shipping it here too means a user who
# skips the heredoc still has something to `kubectl apply -f`.
cat > "$MANIFEST" <<'YAML'
apiVersion: core.openeverest.io/v1alpha1
kind: Instance
metadata:
  name: pg-ha-demo
spec:
  providerRef:
    name: provider-percona-postgresql
  topology:
    type: cluster
  components:
    engine:
      type: postgresql
      replicas: 3
      resources:
        requests: { cpu: "250m", memory: 512Mi }
      storage:
        size: 1Gi
    proxy:
      type: pgbouncer
      replicas: 2
YAML
log "ok: wrote ${MANIFEST}"

# ---------------------------------------------------------------- image pre-pull -------

# Best effort. A DaemonSet with one init container per image warms every node's image
# cache in parallel; the pause container just keeps the pod alive so we can tell when the
# init containers are done. Tolerating everything means the control-plane node gets warmed
# too. The DaemonSet is always deleted, timeout or not.
prepull() {
  local ds=openeverest-image-prepull
  local i=0 img

  {
    cat <<'YAML'
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: openeverest-image-prepull
  namespace: kube-system
  labels:
    app: openeverest-image-prepull
spec:
  selector:
    matchLabels:
      app: openeverest-image-prepull
  template:
    metadata:
      labels:
        app: openeverest-image-prepull
    spec:
      tolerations:
        - operator: Exists
      terminationGracePeriodSeconds: 0
      initContainers:
YAML
    for img in "${PREPULL_IMAGES[@]}"; do
      printf '        - name: pull-%d\n' "$i"
      printf '          image: %s\n' "$img"
      printf '          command: ["/bin/sh", "-c", "exit 0"]\n'
      i=$(( i + 1 ))
    done
    cat <<'YAML'
      containers:
        - name: pause
          image: registry.k8s.io/pause:3.9
YAML
  } | kubectl apply -f - >/dev/null 2>&1 || {
    warn "could not create the pre-pull DaemonSet — images will pull during the lab"
    return 1
  }

  prepull_complete() {
    local desired ready
    desired=$(kubectl get ds -n kube-system "$ds" -o jsonpath='{.status.desiredNumberScheduled}' 2>/dev/null)
    ready=$(kubectl get ds -n kube-system "$ds" -o jsonpath='{.status.numberReady}' 2>/dev/null)
    [ -n "$desired" ] && [ "$desired" != "0" ] && [ "$ready" = "$desired" ]
  }

  log "pre-pulling ${#PREPULL_IMAGES[@]} images on all nodes (best effort)..."
  wait_for 180 "images to be pre-pulled" prepull_complete

  kubectl delete daemonset -n kube-system "$ds" --ignore-not-found --wait=false >/dev/null 2>&1
  log "pre-pull DaemonSet removed"
}
prepull

# ------------------------------------------------------------------- diagnostics -------

# Printed to /var/log/killercoda so a failed run can be diagnosed without reproducing it.
# Node capacity and control-plane taints are the two things most likely to explain pods
# that never leave Pending on a small lab cluster.
log "kubernetes version: $(kubectl version -o json 2>/dev/null | grep -o '"gitVersion": *"[^"]*"' | head -1 | cut -d'"' -f4)"
log "nodes:"
kubectl get nodes -o wide 2>&1 | sed 's/^/    /'
log "allocatable cpu/memory per node:"
kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"  cpu="}{.status.allocatable.cpu}{"  mem="}{.status.allocatable.memory}{"\n"}{end}' 2>&1 | sed 's/^/    /'
log "taints:"
kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"  "}{.spec.taints[*].key}{"\n"}{end}' 2>&1 | sed 's/^/    /'
log "storage classes:"
kubectl get storageclass 2>&1 | sed 's/^/    /'

log "setup complete"
