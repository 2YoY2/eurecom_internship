#!/usr/bin/env bash
# Deploy the DU (Aerial L1 + OAI L2) onto k3s from the artefacts built locally.
#
#   ./scripts/34-deploy-du.sh
#   NAMESPACE=ran ./scripts/34-deploy-du.sh
#
# Everything it needs was produced by earlier steps; it verifies each before
# touching the cluster, because a half-satisfied prerequisite here becomes a
# CrashLoopBackOff that takes far longer to read than an up-front check.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/versions.env"
. "$ROOT/scripts/lib-tools.sh"
export PATH="$HOME/.local/bin:$PATH"
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"

STACK="${STACK_DIR:-$ROOT/stack}"
AERIAL_SRC="$STACK/aerial-cuda-accelerated-ran"
CFGDIR="$AERIAL_SRC/cuPHY-CP/cuphycontroller/config"
RENDERED="$ROOT/site/rendered"
NS="${NAMESPACE:-ran}"
REL="${RELEASE:-aerial-du}"
ARCH="$(uname -m)"

die() { printf '\033[31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }
step(){ printf '\n\033[1m>> %s\033[0m\n' "$*"; }

step "Preflight"
need_tool kubectl >/dev/null || die "kubectl unavailable"
need_tool helm >/dev/null || die "helm unavailable"
kubectl get nodes >/dev/null 2>&1 || die "no reachable cluster — run ./scripts/32-install-k3s.sh"
[ -x "$AERIAL_SRC/build.$ARCH/cuPHY-CP/cuphycontroller/examples/cuphycontroller_scf" ] \
  || die "no L1 binary — run ./scripts/31-build-stack.sh l1"
# The FAPI TLV framing is a compile-time property of the L1: SCF_FAPI_10_04=ON
# gives 32-bit TLV lengths, but OAI writes 16-bit ones. A default-preset build
# passes every other check and then rejects the cell at CONFIG.request.
CMC="$AERIAL_SRC/build.$ARCH/CMakeCache.txt"
if [ -f "$CMC" ] && grep -Eq "^SCF_FAPI_10_04:[A-Z]+=ON" "$CMC"; then
  die "L1 in build.$ARCH was compiled with SCF_FAPI_10_04=ON (32-bit TLV lengths); OAI's L2 frames TLVs with 16-bit lengths. Rebuild: rm -rf $AERIAL_SRC/build.$ARCH && ./scripts/31-build-stack.sh l1"
fi
docker image inspect oai-gnb-aerial:latest >/dev/null 2>&1 \
  || die "oai-gnb-aerial:latest missing — run ./scripts/31-build-stack.sh l2"
# An oai-gnb-aerial:latest tag proves nothing about WHAT it was built from: a
# leftover image from an earlier setup deploys silently and then speaks a
# different FAPI encoding to the L1 -- CONFIG.request TLVs misparse and the
# cell is rejected with errors that look like PRACH misconfiguration.
# 31-build-stack.sh records the OAI commit it built from; require a match.
if [ -f "$STACK/.oai-gnb-aerial.commit" ]; then
  BUILT="$(cat "$STACK/.oai-gnb-aerial.commit")"
  HAVE="$(git -C "$STACK/openairinterface5g" rev-parse HEAD 2>/dev/null)"
  [ "$BUILT" = "$HAVE" ] || [ "${SKIP_L2_CHECK:-0}" = 1 ] \
    || die "oai-gnb-aerial:latest was built from $BUILT but stack/openairinterface5g is at $HAVE — run ./scripts/31-build-stack.sh l2 (or SKIP_L2_CHECK=1 to override)"
elif [ "${SKIP_L2_CHECK:-0}" != 1 ]; then
  die "no build record for oai-gnb-aerial:latest — this repo cannot prove the image matches stack/openairinterface5g. Run ./scripts/31-build-stack.sh l2 once (or SKIP_L2_CHECK=1 to deploy an image of unknown origin)"
fi
[ -f "$RENDERED/cuphycontroller_site.yaml" ] \
  || die "no rendered L1 config — run ./scripts/33-render-config.sh"
echo "   cluster : $(kubectl get nodes -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)"
echo "   L1      : build.$ARCH present"
echo "   L2      : oai-gnb-aerial:latest"

# run_l1.sh resolves its argument as cuphycontroller_<profile>.yaml inside the
# cuBB tree, so the rendered config has to live there under a name of our own.
# Using a distinct name keeps the upstream vendor templates untouched, so the
# tree still diffs clean against the pinned tag apart from this one file.
step "Installing the rendered L1 config into the cuBB tree"
cp -f "$RENDERED/cuphycontroller_site.yaml" "$CFGDIR/cuphycontroller_site.yaml" \
  || die "could not write $CFGDIR/cuphycontroller_site.yaml"
echo "   $CFGDIR/cuphycontroller_site.yaml"
# The rendered adapter config (tick_generator_mode from site.yaml) travels with it.
[ -f "$RENDERED/l2_adapter_config_site.yaml" ] \
  && cp -f "$RENDERED/l2_adapter_config_site.yaml" "$CFGDIR/l2_adapter_config_site.yaml"
# The L1 config names its adapter file; make sure that file actually exists.
L2A="$(grep -m1 '^l2adapter_filename:' "$CFGDIR/cuphycontroller_site.yaml" | awk '{print $2}')"
[ -f "$CFGDIR/$L2A" ] || die "L1 config references $L2A but it is not in $CFGDIR"
echo "   l2 adapter: $L2A"

step "Namespace and gNB config"
kubectl get ns "$NS" >/dev/null 2>&1 || kubectl create namespace "$NS"
if [ -f "$RENDERED/gnb.conf" ]; then
  kubectl create configmap gnb-conf -n "$NS" \
    --from-file=gnb.conf="$RENDERED/gnb.conf" \
    --dry-run=client -o yaml | kubectl apply -f -
  echo "   configmap/gnb-conf from site/rendered/gnb.conf"
  GNB_ARG=(--set l2.configMap=gnb-conf)
else
  echo "   WARNING: no rendered gnb.conf — the L2 will use the image default"
  GNB_ARG=()
fi

# The reference compose mounts OAI's cmake_targets/share into the L1 at
# /opt/cuBB/share. Omitting it is not obviously fatal -- it surfaces later as
# a cell-configuration failure -- so pass it whenever the directory exists.
SHARE="$STACK/openairinterface5g/cmake_targets/share"
if [ -d "$SHARE" ]; then
  echo "   cuBB share: $SHARE"
else
  echo "   WARNING: $SHARE missing; /opt/cuBB/share will be empty in the L1"
  SHARE=""
fi

# The rendered configs are delivered by hostPath, which Helm cannot hash. Do it
# ourselves and put it in the pod annotations, otherwise a re-render produces an
# identical pod spec, no restart, and a "successful" deploy still running the
# previous configuration.
CFGHASH="$(cat "$RENDERED"/cuphycontroller_site.yaml "$RENDERED"/gnb.conf \
             "$CFGDIR/$L2A" 2>/dev/null | sha256sum | cut -c1-16)"
echo "   config hash: $CFGHASH"

# Per-site chart overrides: hugepage size, image registry, MIG device, node
# selector. Untracked, like everything in site/. Applied with -f so the
# --set values below (which come from build artefacts) still win.
SITE_VALUES=()
if [ -f "$ROOT/site/values.yaml" ]; then
  SITE_VALUES=(-f "$ROOT/site/values.yaml")
  echo "   site overrides: site/values.yaml"
fi

step "Deploying $REL to namespace $NS"
helm upgrade --install "$REL" "$ROOT/charts/aerial-du" -n "$NS" \
  "${SITE_VALUES[@]}" \
  --set l1.cubbHostPath="$AERIAL_SRC" \
  --set l1.configProfile=site \
  --set l1.sharePath="$SHARE" \
  --set configHash="$CFGHASH" \
  --set l1.image.repository="$AERIAL_IMAGE" \
  --set l1.image.tag="$AERIAL_TAG" \
  "${GNB_ARG[@]}" \
  || die "helm install failed"

step "Status"
# Give the controllers a moment: querying pods immediately after helm returns
# races the ReplicaSet controller and reports "no resources found" for a
# Deployment that is about to come up perfectly well.
for i in $(seq 1 15); do
  [ "$(kubectl get pods -n "$NS" --no-headers 2>/dev/null | wc -l)" -gt 0 ] && break
  sleep 2
done
kubectl get deploy,rs,pods -n "$NS" -o wide 2>&1

# No pod after that means the ReplicaSet could not create one -- a pod-level
# rejection the Deployment's own validation did not catch. The reason lives in
# the ReplicaSet's conditions and the namespace events, not in the pod list.
POD="$(kubectl get pods -n "$NS" -l app.kubernetes.io/name=aerial-du -o name 2>/dev/null | head -1)"
if [ -z "$POD" ]; then
  echo
  echo "!! No pod was created. Why:"
  kubectl describe deploy "$REL" -n "$NS" 2>/dev/null | sed -n '/Conditions:/,/Events:/p' | sed 's/^/   /'
  kubectl describe rs -n "$NS" 2>/dev/null | grep -A6 -i 'conditions\|error\|failed' | head -20 | sed 's/^/   /'
  echo "   --- recent events ---"
  kubectl get events -n "$NS" --sort-by=.lastTimestamp 2>/dev/null | tail -15 | sed 's/^/   /'
else
  PHASE="$(kubectl get "$POD" -n "$NS" -o jsonpath='{.status.phase}' 2>/dev/null)"
  if [ "$PHASE" = "Pending" ]; then
    echo
    echo "!! Pod is Pending — the scheduler could not place it:"
    kubectl describe "$POD" -n "$NS" 2>/dev/null | sed -n '/Events:/,$p' | head -15 | sed 's/^/   /'
    # By far the most common cause here: nvidia.com/gpu is not advertised
    # because the device plugin is absent, which in turn needs Docker's
    # default runtime to be nvidia.
    GPUCAP="$(kubectl get nodes -o jsonpath='{.items[0].status.allocatable.nvidia\.com/gpu}' 2>/dev/null)"
    echo
    echo "   node advertises nvidia.com/gpu = ${GPUCAP:-<none>}"
    if [ -z "$GPUCAP" ]; then
      cat <<'MSG'
   The node exposes no GPU, so a Pod requesting one can never be scheduled.
   Fix, in order (nvidia-ctk MERGES into daemon.json; hand-editing or piping
   a fresh file over it discards whatever else that file already configures):

     sudo cp /etc/docker/daemon.json /etc/docker/daemon.json.bak 2>/dev/null
     sudo nvidia-ctk runtime configure --runtime=docker --set-as-default
     sudo systemctl restart docker
     ./scripts/32-install-k3s.sh          # then installs the device plugin

   Restarting Docker restarts every container on the host, including the
   cluster's own system pods. They recover; check `docker ps` first so you
   know what you are interrupting.
MSG
    fi
  fi
fi
cat <<EOF

>> The L1 becomes ready when it prints "L1 is ready!" — that means the
   fronthaul is up and the RU is responding. Watch it with:

     kubectl logs -n $NS -l app.kubernetes.io/name=aerial-du -c nv-cubb -f

   Then the L2, which registers with the AMF over N2:

     kubectl logs -n $NS -l app.kubernetes.io/name=aerial-du -c oai-gnb -f

   If the L1 never reports ready, the usual causes are fronthaul timing
   (the T1a/Ta4 windows in site.yaml) or the RU not being provisioned for
   the VLAN and eAxC ids this config uses.
EOF
