#!/usr/bin/env bash
set -euo pipefail

BASE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG="$BASE/cron.log"
LOCK="$BASE/.cron.lock"

# --- logging ---
exec >>"$LOG" 2>&1
# exec > >(tee -a "$LOG") 2>&1   # uncomment for manual debugging

echo "=== $(date -u) cron start ==="

# --- single-run lock ---
exec 9>"$LOCK"
if ! flock -n 9; then
  echo "[INFO] Another run is in progress; exiting."
  exit 0
fi

# --- env ---
export HOME=/home/ubuntu
export SHELL=/bin/bash
export PATH="$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export PYTHONUNBUFFERED=1

cd "$BASE"

# --- patch middleware to prevent automatic unstaking loop ---
# Compares staking CONTRACT ADDRESSES (case-insensitive) instead of program-id
# strings. The original valory code compared the friendly program name returned by
# _get_current_staking_program() (e.g. 'pearl_beta_mech_marketplace_6') against the
# raw address stored in the config (e.g. '0xac3Ed...'), which never matches and
# caused an infinite unstake+restake loop every few days. Comparing resolved
# contract addresses fixes the loop while still allowing legitimate program
# migrations (e.g. expert_11 -> expert_13).
#
# The patcher is a standalone, unit-tested script (scripts/patch_unstaking_middleware.py).
echo "[INFO] Patching middleware to prevent automatic unstaking loop..."
poetry run python3 "/home/ubuntu/scripts/patch_unstaking_middleware.py" \
    || echo "[WARN] Unstaking middleware patcher failed; continuing."

# --- sanity checks ---
for cmd in poetry docker; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "[ERROR] $cmd not found"
    exit 1
  fi
done

docker compose version >/dev/null 2>&1 || {
  echo "[ERROR] docker compose plugin missing"
  exit 1
}

echo "[INFO] python: $(python3 --version 2>&1)"
echo "[INFO] poetry: $(poetry --version 2>&1)"
echo "[INFO] docker: $(docker --version 2>&1)"

# --- runtime controls ---
MAX_RETRIES=3
SLEEP_BETWEEN=180
RUN_TIMEOUT=1800

CONFIG="configs/config_predict_trader.json"
# Operate password: env override, else gitignored .operate_password (chmod 600).
OPERATE_PASSWORD="${OPERATE_PASSWORD:-$(cat "$BASE/.operate_password" 2>/dev/null || true)}"
if [ -z "$OPERATE_PASSWORD" ]; then
  echo "[ERROR] OPERATE_PASSWORD not set and $BASE/.operate_password missing"
  exit 1
fi
PRIORITY_MECH_ADDRESS='0xB3C6319962484602b00d5587e965946890b82101'
PRIORITY_MECH_SERVICE_ID='2235'
# Local clone of the trader agent repo (for the preflight image gate).
# Convention: clone dagacha/trader at ~/trader (override via env if elsewhere).
TRADER_REPO="${TRADER_REPO:-$HOME/trader}"

# ------------------------------------------------------------------
# Scoped cleanup: ONLY services belonging to 28-trader
# ------------------------------------------------------------------

get_service_ids() {
  ls -1 "$BASE/.operate/services" 2>/dev/null | grep '^sc-' || true
}

cleanup_this_trader_only() {
  mapfile -t SERVICE_IDS < <(get_service_ids)

  if [[ "${#SERVICE_IDS[@]}" -eq 0 ]]; then
    echo "[INFO] No service IDs found for this trader; nothing to clean."
    return 0
  fi

  for sid in "${SERVICE_IDS[@]}"; do
    echo "[INFO] Cleaning containers for service $sid"
    docker ps -aq \
      --filter "label=com.docker.compose.project=$sid" \
      | xargs -r docker rm -f || true

    echo "[INFO] Cleaning networks for service $sid"
    docker network ls --format '{{.Name}}' \
      | grep "^${sid}_service_.*_localnet$" \
      | xargs -r docker network rm || true
  done
}

# ------------------------------------------------------------------
# Main run
# ------------------------------------------------------------------

run_once() {
  set +e
  local tmp rc
  tmp="$(mktemp)"
  trap 'rm -f "$tmp"' RETURN

  echo "[INFO] Preparing clean Docker state (scoped to 28-trader)..."
  cleanup_this_trader_only
  sleep 60   # allow Docker IPAM to fully release subnets

  # Protect other traders' containers from run_service.sh's global cleanup.
  # run_service.sh kills all containers matching _abci_0|_tm_0 by name.
  # We rename other traders' containers to strip the matching suffix, then restore after.
  local other_containers=""
  other_containers="$(docker ps --format '{{.Names}}' | grep -E '_abci_0$|_tm_0$' || true)"
  mapfile -t MY_SIDS < <(get_service_ids)
  local protected=""
  for c in $other_containers; do
    local c_project
    c_project="$(docker inspect "$c" --format '{{index .Config.Labels "com.docker.compose.project"}}' 2>/dev/null || true)"
    local is_mine=false
    for sid in "${MY_SIDS[@]}"; do
      [[ "$c_project" == "$sid" ]] && is_mine=true && break
    done
    if [[ "$is_mine" == false ]]; then
      # Strip _abci_0 or _tm_0 suffix so run_service.sh's grep doesn't match
      local safe_name=""
      if [[ "$c" == *_abci_0 ]]; then
        safe_name="x${c%_abci_0}i"
      elif [[ "$c" == *_tm_0 ]]; then
        safe_name="x${c%_tm_0}t"
      else
        continue
      fi
      docker rename "$c" "$safe_name" 2>/dev/null && protected="$protected $safe_name:$c"
    fi
  done
  if [[ -n "$protected" ]]; then
    echo "[INFO] Protected other traders' containers from cleanup:$protected"
  fi

  {
    OPERATE_PASSWORD="$OPERATE_PASSWORD" \
    PRIORITY_MECH_ADDRESS="$PRIORITY_MECH_ADDRESS" \
    PRIORITY_MECH_SERVICE_ID="$PRIORITY_MECH_SERVICE_ID" \
    timeout --preserve-status "$RUN_TIMEOUT" \
      ./run_service.sh "$CONFIG" --attended=false
  } 2>&1 | tee "$tmp"

  rc=${PIPESTATUS[0]}

  # Restore other traders' container names
  if [[ -n "$protected" ]]; then
    echo "[INFO] Restoring other traders' container names..."
    for pair in $protected; do
      local safe_name="${pair%%:*}"
      local orig_name="${pair##*:}"
      docker rename "$safe_name" "$orig_name" 2>/dev/null || echo "[WARN] Could not rename $safe_name back to $orig_name"
    done
  fi

  if grep -q "invalid pool request: Pool overlaps" "$tmp"; then
    echo "[WARN] Docker IPAM overlap detected; retrying after cooldown."
    sleep 180
    return 101
  fi

  if grep -q "Timed out when waiting for transaction to go through" "$tmp"; then
    echo "[WARN] Chain timeout detected."
    return 100
  fi

  if [[ "$rc" -eq 124 ]]; then
    echo "[WARN] Run exceeded timeout."
    return 102
  fi

  if [[ "$rc" -ne 0 ]]; then
    echo "[ERROR] run_service.sh failed (rc=$rc)"
    tail -n 80 "$tmp" || true
  fi

  return "$rc"
}

# ------------------------------------------------------------------
# Preflight image gate: verify the agent image required by the config
# exists locally, building it if missing. Prevents the cryptic
#   'manifest for valory/oar-trader:<hash> not found: manifest unknown'
# docker-compose failure that happens when the quickstart config and the
# locally-built fork image drift apart (fork images are not on Docker Hub).
# Runs ONCE before the retry loop: the required image does not change
# between retries, so a deterministic build failure exits immediately.
# ------------------------------------------------------------------
preflight_image_gate() {
  local config_hash repo_svc_cid agent_hash image
  config_hash="$(python3 -c "import json;print(json.load(open('$BASE/$CONFIG'))['hash'])" 2>/dev/null || true)"
  if [ -z "$config_hash" ]; then
    echo "[GATE][WARN] cannot read service hash from $CONFIG; skipping gate"
    return 0
  fi

  # Primary: config service == trader repo HEAD service -> agent hash from repo.
  agent_hash=""
  if [ -f "$TRADER_REPO/packages/packages.json" ]; then
    repo_svc_cid="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["dev"].get("service/valory/trader_pearl/0.1.0",""))' "$TRADER_REPO/packages/packages.json" 2>/dev/null || true)"
    if [ -n "$repo_svc_cid" ] && [ "$repo_svc_cid" = "$config_hash" ]; then
      agent_hash="$(sed -n 's/^agent: valory\/trader:[0-9.]*:\(bafybei[a-z0-9]*\)[[:space:]]*$/\1/p' "$TRADER_REPO/packages/valory/services/trader_pearl/service.yaml" 2>/dev/null || true)"
    fi
  fi
  # Fallback: the image tag operate computed on the previous deploy.
  if [ -z "$agent_hash" ]; then
    agent_hash="$(grep -ohE 'valory/oar-trader:bafybei[a-z0-9]+' \
      "$BASE"/.operate/services/sc-*/deployment/docker-compose.yaml 2>/dev/null \
      | head -1 | cut -d: -f2 || true)"
    if [ -n "$agent_hash" ]; then
      echo "[GATE][WARN] config service != trader repo HEAD service (drift?); using last-deployed image tag"
    fi
  fi
  if [ -z "$agent_hash" ]; then
    echo "[GATE][WARN] cannot resolve required agent image; skipping gate"
    return 0
  fi

  image="valory/oar-trader:$agent_hash"
  if docker image inspect "$image" >/dev/null 2>&1; then
    echo "[GATE] OK: $image present locally"
    return 0
  fi

  echo "[GATE] MISSING: $image"
  if [ -x "$TRADER_REPO/build_image_offline.sh" ]; then
    echo "[GATE] building via $TRADER_REPO/build_image_offline.sh ..."
    if "$TRADER_REPO/build_image_offline.sh" "$TRADER_REPO" "valory/trader:0.1.0:$agent_hash" \
      && docker image inspect "$image" >/dev/null 2>&1; then
      echo "[GATE] built $image"
      return 0
    fi
  else
    echo "[GATE][FATAL] no build script at $TRADER_REPO/build_image_offline.sh"
  fi
  echo "[GATE][FATAL] image $image missing and could not be built. Align config with a built agent:"
  echo "[GATE][FATAL]   $TRADER_REPO/release_service.sh --quickstart $BASE"
  exit 1
}

preflight_image_gate

attempt=1
while true; do
  if run_once; then
    echo "[INFO] run completed successfully on attempt $attempt."
    break
  fi

  rc=$?
  if (( attempt >= MAX_RETRIES )); then
    echo "[FATAL] run failed (rc=$rc) after $attempt attempts; giving up."
    break
  fi

  echo "[INFO] retrying in ${SLEEP_BETWEEN}s (attempt $((attempt+1))/${MAX_RETRIES})..."
  sleep "$SLEEP_BETWEEN"
  attempt=$((attempt+1))
done

echo "=== $(date -u) cron done ==="
