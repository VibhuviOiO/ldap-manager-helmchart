#!/usr/bin/env bash
#
# e2e-local.sh - install the chart on a real cluster and assert what it claims.
#
# Usage:
#   hack/e2e-local.sh [--chart DIR] [--namespace NS] [--release NAME] [--keep]
#
# Starts k3s in Docker (the same image e2e.yml uses) when KUBECONFIG is not
# already usable, then verifies, on the live cluster:
#
#   1. the chart installs and the pod becomes Ready
#   2. both PersistentVolumeClaims bind
#   3. config.yml is a DIRECTORY mount, not a subPath file mount
#   4. all three probes target the app-local endpoint, never /health
#   5. the Secret's keys arrive as environment variables (envFrom)
#   6. a ConfigMap edit reaches the running pod with NO restart
#   7. an in-place upgrade keeps what is in /app/.data
#   8. helm uninstall keeps both claims, and a reinstall under the same release
#      name adopts them with /app/.data intact
#   9. a different release name cannot adopt a kept claim
#
# Every check is a hard failure: this script exists to be able to say "the
# chart does this" rather than "the template looks like it does".
#
# It never runs `helm install --wait`, on purpose. Helm computes
#     expectedReady = replicas - maxUnavailable
# for a Deployment, and this chart runs one replica with maxUnavailable: 1 (the
# state volumes are ReadWriteOnce, so a surge pod would fight the old one for
# the same claim). expectedReady is therefore 0 and --wait returns as soon as
# the ReplicaSet exists - before any pod is Ready. `kubectl rollout status` is
# the gate that actually observes the pod.

set -euo pipefail

CHART="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NAMESPACE="ldap-manager-e2e"
RELEASE="ldap-manager"
KEEP=false
K3S_NAME="k3s-ldap-manager"
KUBECONFIG_PATH="${KUBECONFIG:-/tmp/ldap-manager-k3s.yaml}"
PORT=18080

while [ $# -gt 0 ]; do
    case "$1" in
        --chart)      CHART="$2"; shift 2 ;;
        --namespace)  NAMESPACE="$2"; shift 2 ;;
        --release)    RELEASE="$2"; shift 2 ;;
        --keep)       KEEP=true; shift ;;
        -h|--help)    sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
done

log() { printf '\n==> %s\n' "$*"; }
die() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

for tool in helm kubectl docker; do
    command -v "$tool" >/dev/null || die "$tool is required"
done

# ---------------------------------------------------------------- the cluster

cluster_reachable() {
    KUBECONFIG="$KUBECONFIG_PATH" kubectl version >/dev/null 2>&1
}

if ! cluster_reachable; then
    log "no cluster reachable through KUBECONFIG=$KUBECONFIG_PATH; starting k3s"
    docker rm -f "$K3S_NAME" >/dev/null 2>&1 || true
    # k3s, not kind: the sibling openldap chart needs containerd 1.7. This chart
    # has no such constraint, but one rig for both is one thing to maintain.
    docker run -d --name "$K3S_NAME" --privileged -p 6443:6443 \
        rancher/k3s:v1.31.4-k3s1 server \
        --disable=traefik --write-kubeconfig-mode=644 --tls-san=127.0.0.1 >/dev/null

    for _ in $(seq 1 60); do
        docker exec "$K3S_NAME" test -f /etc/rancher/k3s/k3s.yaml 2>/dev/null && break
        sleep 2
    done
    docker exec "$K3S_NAME" cat /etc/rancher/k3s/k3s.yaml > "$KUBECONFIG_PATH"
    chmod 600 "$KUBECONFIG_PATH"
fi
export KUBECONFIG="$KUBECONFIG_PATH"

# k3s writes the kubeconfig before the node registers; `kubectl wait node --all`
# fails with "no matching resources found" against an empty list, so poll for
# existence first.
for _ in $(seq 1 60); do
    [ "$(kubectl get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')" -ge 1 ] && break
    sleep 2
done
kubectl wait --for=condition=Ready node --all --timeout=5m
kubectl get storageclass

# ------------------------------------------------------------------ the test

log "namespace and Secret"
kubectl delete namespace "$NAMESPACE" --ignore-not-found --wait=true >/dev/null
kubectl create namespace "$NAMESPACE"
kubectl -n "$NAMESPACE" create secret generic ldap-manager-secrets \
    --from-literal=LDAP_MANAGER_CLUSTER_EXAMPLE_CLUSTER_PASSWORD='E2ePassword123' \
    --from-literal=LDAP_MANAGER_SECRET_KEY="$(openssl rand -hex 32)" >/dev/null

log "install"
helm install "$RELEASE" "$CHART" -n "$NAMESPACE" \
    --set secrets.existingSecret=ldap-manager-secrets \
    --set config.clusters[0].name=example-cluster \
    --set config.clusters[0].host=ldap.example.com \
    --set config.clusters[0].bind_dn=cn=admin,dc=example,dc=com \
    --set config.clusters[0].base_dn=dc=example,dc=com \
    --set config.clusters[0].credential.source=env

log "the pod becomes Ready (helm --wait cannot see this: maxUnavailable: 1, one replica)"
kubectl -n "$NAMESPACE" rollout status "deploy/$RELEASE" --timeout=5m
kubectl -n "$NAMESPACE" get deploy,svc,pvc,pods -o wide

POD=$(kubectl -n "$NAMESPACE" get pod -l "app.kubernetes.io/instance=$RELEASE" -o jsonpath='{.items[0].metadata.name}')
[ -n "$POD" ] || die "no pod found for release $RELEASE"

log "both claims bound"
for claim in "$RELEASE-data" "$RELEASE-secrets"; do
    phase=$(kubectl -n "$NAMESPACE" get pvc "$claim" -o jsonpath='{.status.phase}')
    [ "$phase" = "Bound" ] || die "pvc/$claim is $phase, not Bound"
    echo "    pvc/$claim Bound"
done

log "config.yml is a directory mount, and the app reads it through LDAP_MANAGER_CONFIG"
mount_subpath=$(kubectl -n "$NAMESPACE" get pod "$POD" \
    -o jsonpath='{.spec.containers[0].volumeMounts[?(@.name=="config")].subPath}')
[ -z "$mount_subpath" ] || die "the config volumeMount has subPath=$mount_subpath; a subPath mount never sees ConfigMap updates"
kubectl -n "$NAMESPACE" exec "$POD" -- sh -c '
    set -e
    [ "$LDAP_MANAGER_CONFIG" = "/etc/ldap-manager/config.yml" ] || { echo "LDAP_MANAGER_CONFIG=$LDAP_MANAGER_CONFIG"; exit 1; }
    [ -d /etc/ldap-manager ] || { echo "/etc/ldap-manager is not a directory"; exit 1; }
    [ -L /etc/ldap-manager/config.yml ] || { echo "config.yml is not the ConfigMap symlink"; exit 1; }
    grep -q "example-cluster" /etc/ldap-manager/config.yml || { echo "config.yml does not carry the rendered cluster"; exit 1; }
    echo "    $LDAP_MANAGER_CONFIG -> $(readlink -f /etc/ldap-manager/config.yml)"
'

log "probes are app-local (/api/auth/status), never /health"
for probe in startupProbe readinessProbe livenessProbe; do
    path=$(kubectl -n "$NAMESPACE" get deploy "$RELEASE" -o jsonpath="{.spec.template.spec.containers[0].$probe.httpGet.path}")
    [ "$path" = "/api/auth/status" ] || die "$probe probes $path, expected /api/auth/status"
    echo "    $probe -> $path"
done

log "the Secret's keys arrive as environment variables (the app reads them by name)"
kubectl -n "$NAMESPACE" exec "$POD" -- sh -c '
    set -e
    [ -n "$LDAP_MANAGER_CLUSTER_EXAMPLE_CLUSTER_PASSWORD" ] || { echo "cluster password is not in the environment"; exit 1; }
    [ -n "$LDAP_MANAGER_SECRET_KEY" ] || { echo "LDAP_MANAGER_SECRET_KEY is not in the environment"; exit 1; }
    echo "    cluster password and session key present"
'

log "the app writes its state as the unprivileged uid"
kubectl -n "$NAMESPACE" exec "$POD" -- sh -c '
    set -e
    touch /app/.data/e2e-marker /app/.secrets/e2e-marker
    echo "    uid=$(id -u) wrote /app/.data/e2e-marker and /app/.secrets/e2e-marker"
'

log "a ConfigMap edit reaches the running pod WITHOUT a restart"
restarts_before=$(kubectl -n "$NAMESPACE" get pod "$POD" -o jsonpath='{.status.containerStatuses[0].restartCount}')
kubectl -n "$NAMESPACE" patch configmap "$RELEASE-config" --type merge -p '{"data":{"config.yml":"auth:\n  mode: \"none\"\n  default_role: \"readonly\"\n  session:\n    lifetime_hours: 12\nclusters:\n  - name: patched-live\n    host: ldap2.example.com\n    bind_dn: cn=admin,dc=example,dc=com\n    base_dn: dc=example,dc=com\n"}}' >/dev/null
propagated=false
for _ in $(seq 1 24); do
    # The kubelet syncs the volume on its own schedule; watching mode is fast,
    # a one-minute sync period is the documented worst case.
    if kubectl -n "$NAMESPACE" exec "$POD" -- grep -q patched-live /etc/ldap-manager/config.yml 2>/dev/null; then
        propagated=true
        break
    fi
    sleep 5
done
[ "$propagated" = true ] || die "the edited config.yml never reached the pod"
restarts_after=$(kubectl -n "$NAMESPACE" get pod "$POD" -o jsonpath='{.status.containerStatuses[0].restartCount}')
[ "$restarts_before" = "$restarts_after" ] || die "the pod restarted ($restarts_before -> $restarts_after); the mount should not need it"
echo "    patched config.yml visible, restartCount still $restarts_after"

log "the UI answers through the Service"
kubectl -n "$NAMESPACE" port-forward "svc/$RELEASE" "$PORT:8000" >/tmp/ldap-manager-e2e-port-forward.log 2>&1 &
PF_PID=$!
# Out of the job table, so bash does not print "Terminated: 15 kubectl ..." over
# the next step's output when this one is killed.
disown "$PF_PID" 2>/dev/null || true
trap 'kill "$PF_PID" >/dev/null 2>&1 || true' EXIT
for _ in $(seq 1 20); do
    code=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/api/auth/status" || true)
    [ "$code" = "200" ] && break
    sleep 1
done
[ "$code" = "200" ] || die "/api/auth/status returned $code through the Service"
echo "    GET :$PORT/api/auth/status -> $code"
kill "$PF_PID" >/dev/null 2>&1 || true
trap - EXIT

log "an in-place upgrade keeps /app/.data"
kubectl -n "$NAMESPACE" exec "$POD" -- sh -c 'echo kept > /app/.data/e2e-marker'
helm upgrade "$RELEASE" "$CHART" -n "$NAMESPACE" --reuse-values \
    --set config.auth.sessionLifetimeHours=8 >/dev/null
kubectl -n "$NAMESPACE" rollout status "deploy/$RELEASE" --timeout=5m
POD=$(kubectl -n "$NAMESPACE" get pod -l "app.kubernetes.io/instance=$RELEASE" -o jsonpath='{.items[0].metadata.name}')
marker=$(kubectl -n "$NAMESPACE" exec "$POD" -- cat /app/.data/e2e-marker)
[ "$marker" = "kept" ] || die "the upgrade lost /app/.data (marker: '$marker')"
echo "    /app/.data survived the upgrade"

log "uninstall keeps the claims (helm.sh/resource-policy: keep)"
data_uid_before=$(kubectl -n "$NAMESPACE" get "pvc/$RELEASE-data" -o jsonpath='{.metadata.uid}')
helm uninstall "$RELEASE" -n "$NAMESPACE" >/dev/null
deleted=false
for _ in $(seq 1 12); do
    # Helm deletes what it rendered; without the annotation the claim and its PV
    # are gone within seconds of the uninstall.
    if ! kubectl -n "$NAMESPACE" get "pvc/$RELEASE-data" >/dev/null 2>&1; then
        deleted=true
        break
    fi
    if [ -n "$(kubectl -n "$NAMESPACE" get "pvc/$RELEASE-data" -o jsonpath='{.metadata.deletionTimestamp}')" ]; then
        deleted=true
        break
    fi
    sleep 5
done
[ "$deleted" = false ] || die "the claim was deleted by helm uninstall; /app/.secrets would not survive a reinstall"
data_uid_after=$(kubectl -n "$NAMESPACE" get "pvc/$RELEASE-data" -o jsonpath='{.metadata.uid}')
[ "$data_uid_before" = "$data_uid_after" ] || die "the claim was replaced (uid $data_uid_before -> $data_uid_after)"
echo "    pvc/$RELEASE-data kept, uid unchanged"

log "a reinstall under the same release name adopts the kept claim"
helm install "$RELEASE" "$CHART" -n "$NAMESPACE" \
    --set secrets.existingSecret=ldap-manager-secrets >/dev/null
kubectl -n "$NAMESPACE" rollout status "deploy/$RELEASE" --timeout=5m
[ "$(kubectl -n "$NAMESPACE" get "pvc/$RELEASE-data" -o jsonpath='{.metadata.uid}')" = "$data_uid_after" ] \
    || die "the reinstall did not reuse the kept claim"
POD=$(kubectl -n "$NAMESPACE" get pod -l "app.kubernetes.io/instance=$RELEASE" -o jsonpath='{.items[0].metadata.name}')
marker=$(kubectl -n "$NAMESPACE" exec "$POD" -- cat /app/.data/e2e-marker)
[ "$marker" = "kept" ] || die "the reinstall lost /app/.data (marker: '$marker')"
echo "    /app/.data survived the uninstall/reinstall cycle"

log "a DIFFERENT release name cannot adopt a kept claim"
# Rendered names are <release>-<chart>, so a different release normally gets
# different claims. Overriding the name - the usual GitOps shape - collides
# instead, and Helm must refuse rather than silently take the volume over.
if helm install "$RELEASE-other" "$CHART" -n "$NAMESPACE" \
        --set fullnameOverride="$RELEASE" >/tmp/ldap-manager-e2e-foreign.log 2>&1; then
    die "a foreign release adopted the kept claim; Helm's ownership check did not fire"
fi
grep -q "invalid ownership metadata" /tmp/ldap-manager-e2e-foreign.log \
    || { cat /tmp/ldap-manager-e2e-foreign.log; die "the foreign install failed for an unexpected reason"; }
echo "    refused: $(head -1 /tmp/ldap-manager-e2e-foreign.log)"

if [ "$KEEP" = true ]; then
    log "--keep: leaving namespace $NAMESPACE and cluster $K3S_NAME in place"
else
    # Kept claims are kept on purpose: uninstalling the release does not remove
    # them, so an explicit delete is the only way to clean up.
    helm uninstall "$RELEASE" -n "$NAMESPACE" >/dev/null 2>&1 || true
    kubectl -n "$NAMESPACE" delete pvc --all >/dev/null 2>&1 || true
    kubectl delete namespace "$NAMESPACE" --wait=false >/dev/null
    log "done (the k3s container $K3S_NAME is still running; docker rm -f $K3S_NAME to stop it)"
fi
