#!/bin/bash
#
# OpenEverest HA PostgreSQL — verification for step 2 ("Provision HA PostgreSQL").
#
# Wired into index.json as details.steps[1].verify. Killercoda runs it when the user
# presses "Check" and marks the step complete only on exit 0.
#
# This deliberately checks the resulting cluster state rather than whether a command was
# run. `kubectl apply` succeeding proves only that the API server accepted a manifest; it
# says nothing about whether a Postgres cluster actually came up. So the bar here is:
#
#   1. the Instance exists and reports phase Ready
#   2. exactly one engine pod is the primary
#   3. at least two engine pods are replicas
#   4. every engine pod passes its readiness probe
#   5. the connection Secret the Instance advertises actually exists
#
# Checks 2-4 are what separate "an HA cluster" from "one Postgres pod". A single-replica
# cluster would satisfy phase Ready on its own.
#
# There is a short grace period because the role labels settle a moment after the Instance
# flips to Ready, so a user who presses Check immediately still passes.

NS="${NS:-everest-system}"
INSTANCE="${INSTANCE:-pg-ha-demo}"
TIMEOUT="${VERIFY_TIMEOUT:-90}"
MIN_REPLICAS="${MIN_REPLICAS:-2}"

SEL="postgres-operator.crunchydata.com/cluster=${INSTANCE}"
ROLE_LABEL='.metadata.labels.postgres-operator\.crunchydata\.com/role'

# Set by check() to explain the most recent failure.
REASON=""

# The Instance may not be where we expect if the user applied it elsewhere. Look it up
# cluster-wide before giving up, so a wrong namespace produces a useful message instead of
# a bare "not found".
resolve_namespace() {
  kubectl get instance "$INSTANCE" -n "$NS" >/dev/null 2>&1 && return 0

  local found
  found=$(kubectl get instances.core.openeverest.io -A --no-headers 2>/dev/null \
    | awk -v n="$INSTANCE" '$2 == n { print $1; exit }')

  if [ -n "$found" ]; then
    NS="$found"
    SEL="postgres-operator.crunchydata.com/cluster=${INSTANCE}"
    return 0
  fi
  return 1
}

check() {
  REASON=""

  if ! resolve_namespace; then
    REASON="No Instance named '${INSTANCE}' found in any namespace. Did 'kubectl apply -f pg-ha-demo.yaml' run?"
    return 1
  fi

  # ---- 1. Instance phase ----
  local phase
  phase=$(kubectl get instance "$INSTANCE" -n "$NS" -o jsonpath='{.status.phase}' 2>/dev/null)

  if [ -z "$phase" ]; then
    REASON="Instance '${INSTANCE}' exists but has no status yet — the provider has not reconciled it."
    return 1
  fi

  if [ "$phase" != "Ready" ]; then
    local msg
    msg=$(kubectl get instance "$INSTANCE" -n "$NS" -o jsonpath='{.status.message}' 2>/dev/null)
    REASON="Instance '${INSTANCE}' is in phase '${phase}', expected 'Ready'.${msg:+ Message: ${msg}}"
    return 1
  fi

  # ---- 2 & 3. Engine roles ----
  # The cluster label also matches the PgBouncer pods, so count by role rather than
  # assuming everything the selector returns is an engine.
  local roles primaries replicas
  roles=$(kubectl get pods -n "$NS" -l "$SEL" \
    -o jsonpath="{range .items[*]}{${ROLE_LABEL}}{\"\n\"}{end}" 2>/dev/null)

  primaries=$(printf '%s\n' "$roles" | grep -cE '^(primary|master)$')
  replicas=$(printf '%s\n' "$roles" | grep -cx 'replica')

  if [ "$primaries" -ne 1 ]; then
    REASON="Expected exactly 1 primary engine pod, found ${primaries}. A cluster with no primary has not finished electing a leader."
    return 1
  fi

  if [ "$replicas" -lt "$MIN_REPLICAS" ]; then
    REASON="Expected at least ${MIN_REPLICAS} replica engine pods, found ${replicas}. This is not a highly-available cluster yet."
    return 1
  fi

  # ---- 4. Engine pods actually ready ----
  # Role labels appear before the readiness probe passes, so check both.
  local ready_engines expected_engines
  expected_engines=$(( primaries + replicas ))
  ready_engines=$(kubectl get pods -n "$NS" -l "$SEL" \
    -o jsonpath="{range .items[*]}{${ROLE_LABEL}}{\" \"}{range .status.conditions[?(@.type=='Ready')]}{.status}{end}{\"\n\"}{end}" 2>/dev/null \
    | awk '$1 ~ /^(primary|master|replica)$/ && $2 == "True"' | wc -l)

  if [ "$ready_engines" -ne "$expected_engines" ]; then
    REASON="Only ${ready_engines} of ${expected_engines} engine pods are Ready."
    return 1
  fi

  # ---- 5. Connection secret ----
  local secret
  secret=$(kubectl get instance "$INSTANCE" -n "$NS" \
    -o jsonpath='{.status.connectionSecretRef.name}' 2>/dev/null)

  if [ -z "$secret" ]; then
    REASON="Instance '${INSTANCE}' is Ready but advertises no connection Secret."
    return 1
  fi

  if ! kubectl get secret "$secret" -n "$NS" >/dev/null 2>&1; then
    REASON="Instance '${INSTANCE}' advertises Secret '${secret}', but it does not exist in namespace '${NS}'."
    return 1
  fi

  PRIMARIES="$primaries"
  REPLICAS_FOUND="$replicas"
  SECRET_NAME="$secret"
  return 0
}

deadline=$(( SECONDS + TIMEOUT ))
while true; do
  if check; then
    echo "OK: Instance '${INSTANCE}' is Ready in namespace '${NS}'"
    echo "OK: ${PRIMARIES} primary + ${REPLICAS_FOUND} replicas, all engine pods passing readiness"
    echo "OK: connection secret '${SECRET_NAME}' present"
    exit 0
  fi
  (( SECONDS >= deadline )) && break
  sleep 5
done

# Failed. Print why, then enough state for the user to act on it.
echo "FAILED: ${REASON}"
echo
echo "--- instances ---"
kubectl get instances.core.openeverest.io -A 2>&1
echo
echo "--- pods (${NS}) ---"
kubectl get pods -n "$NS" -l "$SEL" \
  -L postgres-operator.crunchydata.com/role 2>&1
echo
echo "--- pvcs (${NS}) ---"
kubectl get pvc -n "$NS" 2>&1
echo
echo "Hint: 'kubectl describe instance ${INSTANCE} -n ${NS}' shows the reconcile conditions,"
echo "and 'kubectl logs -n ${NS} deploy/provider-percona-postgresql' shows the provider's view."
exit 1
