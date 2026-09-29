#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

# Use a new loopback-only Anvil. No caller-supplied RPC or production keys are used.
tmp="$(mktemp -d)"
config="$(python3 -c 'import tempfile; f=tempfile.NamedTemporaryFile(prefix="smoke.",suffix=".local.json",dir="config",delete=False); print(f.name); f.close()')"
pid=''
cleanup() {
  if [[ -n "$pid" ]]; then kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; fi
  rm -f "$config"
  rm -rf "$tmp"
}
trap cleanup EXIT
port="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"
export RPC_URL="http://127.0.0.1:$port"
export DEPLOY_CONFIG="$config"
export FOUNDRY_BROADCAST="$tmp/broadcast"
anvil --host 127.0.0.1 --port "$port" --chain-id 31337 --hardfork cancun --silent >"$tmp/anvil.log" 2>&1 &
pid=$!
ready=false
for _ in $(seq 1 40); do
  kill -0 "$pid" 2>/dev/null || { cat "$tmp/anvil.log"; exit 1; }
  if cast chain-id --rpc-url "$RPC_URL" >"$tmp/chain" 2>/dev/null; then ready=true; break; fi
  sleep 0.25
done
[[ "$ready" == true && "$(cat "$tmp/chain")" == 31337 ]] || { echo 'Local Anvil did not start.' >&2; exit 1; }
cast rpc --rpc-url "$RPC_URL" eth_accounts >"$tmp/accounts.json"
account() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[int(sys.argv[2])])' "$tmp/accounts.json" "$1"; }
deployer="$(account 0)"; owner="$(account 1)"; worker="$(account 2)"
recipient="$(account 3)"; source="$(account 4)"; new_owner="$(account 5)"; second_worker="$(account 6)"
python3 - "$config" "$owner" "$recipient" "$worker" "$second_worker" <<'PY'
import json,sys
with open(sys.argv[1], 'w') as output:
    json.dump({'chainId':31337,'owner':sys.argv[2],'recipient':sys.argv[3],
               'workers':sys.argv[4:],'requireSafeOwner':False}, output)
PY
python3 scripts/validate_config.py "$config"
forge script script/Deploy.s.sol:Deploy --rpc-url "$RPC_URL" --sender "$deployer" --unlocked --broadcast
export SWEEPER_ADDRESS="$(python3 - "$FOUNDRY_BROADCAST/Deploy.s.sol/31337/run-latest.json" <<'PY'
import json,sys
records=json.load(open(sys.argv[1]))['transactions']
print(next(x['contractAddress'] for x in records if x['contractName']=='BatchPermitSweeper' and x['transactionType']=='CREATE'))
PY
)"
forge script script/VerifyDeployment.s.sol:VerifyDeployment --rpc-url "$RPC_URL"
forge create test/mocks/Tokens.sol:PermitToken --rpc-url "$RPC_URL" --from "$deployer" --unlocked --broadcast --json >"$tmp/token.json"
token="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["deployedTo"])' "$tmp/token.json")"
python3 scripts/owner_batch.py --config "$config" --sweeper "$SWEEPER_ADDRESS" --token "$token" --output "$tmp/owner.json"
python3 - "$tmp/owner.json" <<'PY'
import json,sys
batch=json.load(open(sys.argv[1]))
assert len(batch['transactions']) == 1
assert batch['chainId'] == '31337'
assert batch['transactions'][0]['data'].startswith('0x')
PY
send() { cast send --rpc-url "$RPC_URL" --unlocked --from "$1" "$2" "${@:3}" >/dev/null; }
call() { cast call --rpc-url "$RPC_URL" "$@"; }
if send "$deployer" "$SWEEPER_ADDRESS" 'unpause()' 2>/dev/null; then
  echo 'Deployer unexpectedly retained administrator powers.' >&2; exit 1
fi
send "$owner" "$SWEEPER_ADDRESS" 'setTokenAllowed(address,bool)' "$token" true
send "$owner" "$SWEEPER_ADDRESS" 'unpause()'
send "$deployer" "$token" 'mint(address,uint256)' "$source" 100
send "$source" "$token" 'approve(address,uint256)' "$SWEEPER_ADDRESS" 100
version="$(call "$SWEEPER_ADDRESS" 'configVersion()(uint256)')"
timestamp="$(cast block latest --rpc-url "$RPC_URL" --json | python3 -c 'import json,sys; x=json.load(sys.stdin)["timestamp"]; print(int(x,0) if isinstance(x,str) else x)')"
context="($recipient,$version,$((timestamp+600)))"
send "$worker" "$SWEEPER_ADDRESS" 'batchSweep(address,address[],(address,uint256,uint256))' "$token" "[$source]" "$context"
[[ "$(call "$token" 'balanceOf(address)(uint256)' "$recipient")" == 100 ]]
[[ "$(call "$token" 'balanceOf(address)(uint256)' "$source")" == 0 ]]
send "$second_worker" "$SWEEPER_ADDRESS" 'pause()'
if send "$worker" "$SWEEPER_ADDRESS" 'unpause()' 2>/dev/null; then
  echo 'Worker unexpectedly acquired recovery powers.' >&2; exit 1
fi
send "$owner" "$SWEEPER_ADDRESS" 'transferOwnership(address)' "$new_owner"
send "$new_owner" "$SWEEPER_ADDRESS" 'acceptOwnership()'
send "$new_owner" "$SWEEPER_ADDRESS" 'unpause()'
actual_owner="$(call "$SWEEPER_ADDRESS" 'owner()(address)')"
python3 - "$actual_owner" "$new_owner" <<'PY'
import sys
assert int(sys.argv[1],16) == int(sys.argv[2],16)
PY
if send "$owner" "$SWEEPER_ADDRESS" 'setOperator(address,bool)' "$worker" false 2>/dev/null; then
  echo 'Former owner unexpectedly retained administrator powers.' >&2; exit 1
fi
echo 'PASS: parameterized deployment, bytecode check, unsigned owner batch, worker sweep, pause and ownership handover.'
