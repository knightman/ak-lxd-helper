#!/usr/bin/env bash
# Unit tests for lab projects 004 + 005: vLLM serving Qwen3-8B + pi wired to it.
# Run from the repo root: bash lab/tests/lab-004-005.sh
#
# Each check prints PASS/FAIL; the script exits non-zero if any check fails.
set -u
URL="${AK_LXD_URL:-http://127.0.0.1:8080}"
VLLM=lab-004-vllm
PI=lab-005-pi
MODEL="Qwen/Qwen3-8B"

pass=0; fail=0
_check() {  # _check <label> <expected-grep-pattern> <command>
  local label="$1" pattern="$2"; shift 2
  local out
  out=$("$@" 2>&1)
  if echo "$out" | grep -qE "$pattern"; then
    printf '  \033[32mPASS\033[0m  %s\n' "$label"; pass=$((pass+1))
  else
    printf '  \033[31mFAIL\033[0m  %s\n' "$label"; fail=$((fail+1))
    echo "        expected pattern: $pattern"
    echo "        got: $(echo "$out" | head -c 240)"
  fi
}

# helper to exec a command inside an LXD instance via the helper API
_exec() {
  local name="$1"; shift
  curl -s -X POST "$URL/api/instances/$name/exec" \
    -H 'content-type: application/json' \
    -d "$(python3 -c 'import json,sys;print(json.dumps({"command":" ".join(sys.argv[1:])}))' "$@")" \
    | python3 -c "import sys,json;d=json.load(sys.stdin);data=d.get('data') or {};sys.stdout.write(data.get('stdout','')+data.get('stderr',''))"
}

echo "== vLLM (lab-004-vllm) =="
_check "vllm serve process is running" "vllm serve" \
  _exec "$VLLM" "pgrep -af 'vllm serve' | head -1"
_check "vllm /v1/models lists $MODEL" "$MODEL" \
  _exec "$VLLM" "curl -fs http://localhost:8000/v1/models"
_check "/v1/chat/completions returns non-empty + usage" '"completion_tokens"' \
  _exec "$VLLM" "curl -fs http://localhost:8000/v1/chat/completions -H 'content-type: application/json' -d '{\"model\":\"$MODEL\",\"messages\":[{\"role\":\"user\",\"content\":\"echo OK\"}],\"max_tokens\":12,\"temperature\":0.0}'"

echo
echo "== cross-VM reach (lab-005-pi -> lab-004-vllm) =="
VLLM_IP=$(curl -fs "$URL/api/instances/$VLLM" | python3 -c "import sys,json;d=json.load(sys.stdin)['data'];n=d.get('state',{}).get('network',{});
[print(a['address']) for i,n in n.items() for a in n.get('addresses',[]) if a.get('scope')=='global' and a.get('family')=='inet' and a['address'].startswith('10.')]" | head -1)
_check "from lab-005, GET $VLLM_IP:8000/v1/models lists $MODEL" "$MODEL" \
  _exec "$PI" "curl -fs --max-time 8 http://$VLLM_IP:8000/v1/models"

echo
echo "== pi (lab-005-pi) =="
_check "pi CLI built (cli.js exists)" "cli.js" \
  _exec "$PI" "ls /home/lab/pi/packages/coding-agent/dist/cli.js 2>/dev/null"
_check "pi --help runs" "AI coding assistant" \
  _exec "$PI" "su - lab -c '/home/lab/pi/pi-test.sh --help' 2>&1 | head -3"
_check "models.json registers vllm provider + $MODEL" "$MODEL" \
  _exec "$PI" "cat /home/lab/.pi/agent/models.json 2>/dev/null"

echo
echo "== end-to-end (pi -> vLLM completion) =="
_check "pi --provider vllm one-shot returns text from Qwen3-8B" "[A-Za-z]" \
  _exec "$PI" "su - lab -c '/home/lab/pi/pi-test.sh --provider vllm --model vllm/$MODEL --no-tools -p \"Reply with exactly: hello-from-pi\" 2>&1' | tail -5"

echo
echo "== web search / tool calling =="
# Regression for the tool-calling flags on lab-004's vLLM (--enable-auto-tool-choice
# --tool-call-parser hermes). Without them this request 400s, curl -fs yields nothing,
# and pi's web_search can never fire. With them, vLLM returns a chat.completion object.
_check "vllm accepts OpenAI tool-calling requests" "chat.completion" \
  _exec "$VLLM" "curl -fs http://localhost:8000/v1/chat/completions -H 'content-type: application/json' -d '{\"model\":\"$MODEL\",\"messages\":[{\"role\":\"user\",\"content\":\"What is the weather in Paris?\"}],\"max_tokens\":64,\"temperature\":0.0,\"tools\":[{\"type\":\"function\",\"function\":{\"name\":\"get_weather\",\"description\":\"Get the weather for a city\",\"parameters\":{\"type\":\"object\",\"properties\":{\"city\":{\"type\":\"string\"}},\"required\":[\"city\"]}}}],\"tool_choice\":\"auto\"}'"
_check "pi-web-access extension installed (zero-config Exa web_search)" "pi-web-access" \
  _exec "$PI" "cat /home/lab/.pi/agent/settings.json 2>/dev/null"
# End-to-end: pi must actually call web_search (pi-web-access/Exa) and surface a live
# result. Network-dependent; the model has to choose to call the tool. Asserts the
# official Python URL appears in the answer.
_check "pi web_search returns a live result (finds python.org)" "python\\.org" \
  _exec "$PI" "su - lab -c '/home/lab/pi/pi-test.sh --provider vllm --model vllm/$MODEL -p \"Use the web_search tool to find the official Python website, then reply with just its URL.\" 2>&1' | tail -15"

echo
echo "== persistent tmux session (lab-005-pi) =="
_check "tmux session 'pi' exists" "^pi:" \
  _exec "$PI" "su - lab -c 'tmux ls 2>/dev/null'"
_check "systemd user unit pi-session.service is enabled" "enabled" \
  _exec "$PI" "su - lab -c 'XDG_RUNTIME_DIR=/run/user/\$(id -u) systemctl --user is-enabled pi-session.service' 2>&1"

echo
echo "==============================="
printf 'RESULT: %d pass, %d fail\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
