# Runs inside the berkeleyskypilot/skypilot container as its entrypoint (`sh /krater/skypilot-start.sh`).
# Ported from Krater's docker-compose.yml `skypilot` service; keep the two in step. It writes the server
# config from env at every start, keeps the per-project workspaces Krater created, and starts the API
# server the way SkyPilot's Helm chart does.
#
# Env (set by the krater-skypilot unit):
#   KRATER_PUBLIC_URL, KRATER_SKYPILOT_POLICY_TOKEN   the launch gate's URL and token
#   ENABLE_BASIC_AUTH                                 "true" only for the one-time service-token bootstrap
#   SKYPILOT_BASIC_AUTH_USER, SKYPILOT_BASIC_AUTH_PASSWORD
set -eu

if [ "$ENABLE_BASIC_AUTH" = "true" ]; then
  : "${SKYPILOT_BASIC_AUTH_PASSWORD:?basic auth is on but no password was given}"
  # SkyPilot only reads this (`user:<bcrypt hash>`) on its first start with an empty state directory.
  SKYPILOT_INITIAL_BASIC_AUTH="$SKYPILOT_BASIC_AUTH_USER:$(python -c 'import bcrypt, os; print(bcrypt.hashpw(os.environ["SKYPILOT_BASIC_AUTH_PASSWORD"].encode(), bcrypt.gensalt()).decode())')"
  export SKYPILOT_INITIAL_BASIC_AUTH
fi
unset SKYPILOT_BASIC_AUTH_PASSWORD
mkdir -p /root/.sky /root/.config/vastai

cat > /tmp/krater-sky-config.yaml <<CFG
# Generated at container start by krater-skypilot (patchworklabsorg/infra, modules/krater) -- do not edit.

# Called from members' own machines as well as from this container, so it is Krater's public URL.
admin_policy: ${KRATER_PUBLIC_URL}/internal/skypilot/policy?token=${KRATER_SKYPILOT_POLICY_TOKEN}

# Without this, every new SSO login defaults to SkyPilot role admin.
rbac:
  default_role: user

# The "default" workspace isn't tied to any Ganymede project, so every cloud is off in it. There is no
# workspace-level cloud allowlist: each cloud has to be deny-listed one by one.
workspaces:
  default:
    aws: {disabled: true}
    azure: {disabled: true}
    cudo: {disabled: true}
    do: {disabled: true}
    fluidstack: {disabled: true}
    gcp: {disabled: true}
    hyperbolic: {disabled: true}
    ibm: {disabled: true}
    kubernetes: {disabled: true}
    lambda: {disabled: true}
    mithril: {disabled: true}
    nebius: {disabled: true}
    oci: {disabled: true}
    paperspace: {disabled: true}
    primeintellect: {disabled: true}
    runpod: {disabled: true}
    scp: {disabled: true}
    seeweb: {disabled: true}
    shadeform: {disabled: true}
    ssh: {disabled: true}
    vast: {disabled: true}
    vsphere: {disabled: true}
    yotta: {disabled: true}
CFG

# SkyPilot saves the workspaces Krater creates into this same file, so keep those; everything else is
# regenerated on every start.
python - <<'PY'
import os, yaml
path = "/root/.sky/config.yaml"
with open("/tmp/krater-sky-config.yaml") as f:
    config = yaml.safe_load(f)
current = {}
if os.path.exists(path):
    with open(path) as f:
        current = yaml.safe_load(f) or {}
workspaces = current.get("workspaces") or {}
workspaces.update(config["workspaces"])
config["workspaces"] = workspaces
with open(path, "w") as f:
    yaml.safe_dump(config, f, sort_keys=False)
PY

exec sky api start --deploy --foreground
