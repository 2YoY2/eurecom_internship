#!/usr/bin/env bash
# Deploy the CU and the DU onto the cluster from the manifests in deploy/ and
# the ConfigMaps the site supplies (see scripts/6-deploy.sh).
#
#   ./scripts/6-deploy.sh
#   NAMESPACE=ran ./scripts/6-deploy.sh
#
# What it does, in order: check the cluster and the images, apply the three
# ConfigMaps, substitute the pinned images into deploy/*.yaml, stamp a hash of
# the configs into both pod templates, apply, and wait for each rollout.
#
# The hash is the point of this script existing rather than a plain kubectl
# apply -f: a ConfigMap's content changing does not restart anything. Without
# it, "re-render and deploy" leaves the old config running and every log you
# then read is from the config you thought you replaced.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/versions.env"
[ -f "$ROOT/versions.local.env" ] && . "$ROOT/versions.local.env"
. "$ROOT/scripts/lib.sh"

NS="${NAMESPACE:-ran}"
OUT="${OUT:-$(mktemp -d)}"

# The ConfigMaps carrying cell identity, PLMN, the CU/RIC/core addresses, the
# peer MACs and the PCI addresses are NOT part of this repo and are not created
# here. They are supplied per deployment and must already exist in the namespace.
# The repo stays generic: nothing in it describes a particular radio or site.
REQUIRED_CM="l1-config oai-cu-conf oai-du-high-conf"

die() { printf '\033[31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }
step(){ printf '\n\033[1m>> %s\033[0m\n' "$*"; }

step "Preflight"
need_tool kubectl >/dev/null || die "kubectl unavailable"
need_tool yq >/dev/null || die "yq unavailable"
kubectl get nodes >/dev/null 2>&1 || die "no reachable cluster (kubectl get nodes failed)"
for var in IMAGE_DU_LOW IMAGE_DU_HIGH IMAGE_CU; do
  img="${!var:-}"; [ -n "$img" ] || die "$var unset in versions.env"
  docker image inspect "$img" >/dev/null 2>&1 \
    || echo "   note: $img is not in the local store; the kubelet will have to pull it"
done
echo "   namespace: $NS"

# Both DU halves pin themselves to a labelled node. That is deliberate: the GPU,
# the fronthaul NIC and the SR-IOV VF are properties of particular machines, and
# on a multi-node cluster architecture alone does not identify them. An unlabelled
# cluster leaves the pod Pending with no explanation, so check it here instead.
if [ -z "$(kubectl get nodes -l yoy.ran/role=du-low -o name 2>/dev/null)" ]; then
  die "no node carries yoy.ran/role=du-low — label the GPU host first:
       kubectl label node <gpu-host> yoy.ran/role=du-low"
fi

step "ConfigMaps"
kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
missing=""
for cm in $REQUIRED_CM; do
  if kubectl get configmap -n "$NS" "$cm" >/dev/null 2>&1; then
    echo "   found $cm"
  else
    missing="$missing $cm"
  fi
done
[ -n "$missing" ] && die "missing ConfigMap(s) in namespace $NS:$missing
       These carry the site's RAN configuration and are deliberately not in this
       repo. Create them from your own configs, e.g.:
         kubectl create configmap l1-config -n $NS \\
           --from-file=cuphycontroller_site.yaml=<path> \\
           --from-file=l2_adapter_config_site.yaml=<path> \\
           --from-file=nvipc_l1_dpdk.yaml=<path>"

# Roll the pods when the mounted configuration changes: the annotation tracks
# the ConfigMaps' resourceVersions, so an edit to a config is a new rollout.
CFGHASH="$(for cm in $REQUIRED_CM; do
             kubectl get configmap -n "$NS" "$cm" -o jsonpath='{.metadata.resourceVersion}' 2>/dev/null
           done | sha256sum | cut -c1-16)"
echo "   config hash: $CFGHASH"

step "Rendering deploy manifests"
mkdir -p "$OUT"
cp "$ROOT/deploy/10-du-low.yaml"  "$OUT/10-du-low.yaml"
cp "$ROOT/deploy/11-cu.yaml"      "$OUT/11-cu.yaml"
cp "$ROOT/deploy/12-du-high.yaml" "$OUT/12-du-high.yaml"
yq -i "
  .spec.template.metadata.annotations.\"vran/config-hash\" = \"$CFGHASH\" |
  (.spec.template.spec.containers[] | select(.name == \"nv-cubb\")).image  = \"$IMAGE_DU_LOW\"
" "$OUT/10-du-low.yaml" || die "could not render the DU-Low manifest"
yq -i "
  .spec.template.metadata.annotations.\"vran/config-hash\" = \"$CFGHASH\" |
  (.spec.template.spec.containers[] | select(.name == \"oai-du-high\")).image = \"$IMAGE_DU_HIGH\"
" "$OUT/12-du-high.yaml" || die "could not render the DU-High manifest"
yq -i "
  .spec.template.metadata.annotations.\"vran/config-hash\" = \"$CFGHASH\" |
  (.spec.template.spec.containers[] | select(.name == \"oai-cu\")).image = \"$IMAGE_CU\"
" "$OUT/11-cu.yaml" || die "could not render the CU manifest"
grep -q IMAGE_ "$OUT/10-du-low.yaml" "$OUT/11-cu.yaml" "$OUT/12-du-high.yaml" \
  && die "an image placeholder survived substitution — check the container names"
echo "   DU-Low  $IMAGE_DU_LOW"
echo "   DU-High $IMAGE_DU_HIGH"
echo "   CU      $IMAGE_CU"

# CU first: the DU dials F1 and retries until the CU answers, so this order
# just avoids a minute of F1 Setup failures in the DU log.
# Order: CU, then DU-Low, then DU-High.
#
# The DU-High goes last for a reason that is not cosmetic. The L1's nvIPC connect
# handshake is single-shot, so if the DU-High dials before the L1 is listening it
# blocks forever and the L1 has to be restarted before the next attempt. Waiting
# for the DU-Low to report ready is what makes the ordering safe.
step "Applying"
kubectl apply -n "$NS" -f "$OUT/11-cu.yaml"     | sed 's/^/   /' || die "CU apply failed"
kubectl apply -n "$NS" -f "$OUT/10-du-low.yaml" | sed 's/^/   /' || die "DU-Low apply failed"

step "Waiting for rollouts"
kubectl rollout status -n "$NS" deploy/oai-cu      --timeout=180s || die "CU did not become ready"
# The L1's readiness probe waits for "L1 is ready!", which needs the fronthaul
# and the GPU. Budget minutes, not seconds: cuPHY spends ~160 s initialising its
# kernels on the GPU before it even opens the FAPI transport. A genuine failure
# here is usually the radio or the timing rather than Kubernetes.
kubectl rollout status -n "$NS" deploy/aerial-cubb --timeout=900s \
  || die "DU-Low did not become ready — see docs/TROUBLESHOOTING.md"

# The DU-High runs on a different machine and a different architecture. If that
# host is not a node in this cluster there is nowhere to schedule it, and saying
# so plainly is better than leaving a pod Pending forever.
step "DU-High"
if [ -z "$(kubectl get nodes -l yoy.ran/role=du-high -o name 2>/dev/null)" ]; then
  cat <<'MSG'
   SKIPPED: no node carries the label yoy.ran/role=du-high.

   The DU-High is a separate machine from the GPU host. To schedule it here the
   host has to join this cluster and be labelled:

       kubectl label node <du-high-host> yoy.ran/role=du-high

   Until then it runs outside Kubernetes; see
   ../fapi-over-dpdk/deploy-split/run-du-high.sh, which takes the same image and
   the same two mounted configs.
MSG
elif ! kubectl get configmap -n "$NS" oai-du-high-conf >/dev/null 2>&1; then
  echo "   SKIPPED: ConfigMap oai-du-high-conf not found in namespace $NS."
else
  kubectl apply -n "$NS" -f "$OUT/12-du-high.yaml" | sed 's/^/   /' || die "DU-High apply failed"
  kubectl rollout status -n "$NS" deploy/oai-du-high --timeout=300s \
    || die "DU-High did not become ready — see ../fapi-over-dpdk/RESUME.md"
fi

step "Status"
kubectl get pods -n "$NS" -o wide
cat <<MSG

>> Verify, layer by layer:

     kubectl exec -n $NS deploy/aerial-cubb -c nv-cubb -- \\
       bash -c 'grep -E "PHY Cell Id|CONFIG.response" \$AERIAL_LOG_PATH/phy.log'
     kubectl logs -n $NS deploy/aerial-cubb -c nv-cubb --tail=3 | grep "Cell  0 |"
     kubectl logs -n $NS deploy/oai-cu | grep -E "NGSetupResponse|F1 Setup"
MSG
