#!/bin/bash
. "$(dirname "$0")/lib.sh"
H=$(new_home); install_into "$H"; C="$H/.claude"

# ── readonly-bash: 0 = lolos, 2 = blok ──
rb() { local rc=0; python3 -c 'import json,sys; print(json.dumps({"tool_input":{"command":sys.argv[1]}}))' "$2" \
        | python3 "$C/hooks/readonly-bash.py" >/dev/null 2>&1 || rc=$?; assert_eq "$rc" "$1" "readonly-bash: $2"; }
for c in 'git log --oneline -5' 'git diff main...HEAD | head -50' 'git branch -a' 'git show HEAD:README.md' 'git status --short' \
         'ls -la src | head' 'wc -l README.md' 'cat README.md' 'grep -rn "foo|bar" src | wc -l'; do rb 0 "$c"; done
for c in 'git push origin main' 'rm -rf build' 'git log > out.txt' 'git branch newbranch' 'git diff --output=x.patch' 'ls || rm x' \
         'find . -name x -delete' 'git log; rm x' 'cat a && git push' 'echo $(rm x)' 'echo `rm x`' 'git log | tee out.txt' \
         'sed -i s/a/b/ f' 'git checkout main' 'git reset --hard' 'curl -X POST http://x' 'npm install' 'git stash' \
         'git commit -m x' 'cat a > b' 'cp a b' 'mv a b' 'git tag v1'; do rb 2 "$c"; done

# ── model-switch-guard ──
g() { printf '%s' "$1" | python3 -I "$C/hooks/model-switch-guard.py" 2>/dev/null; }
b='"hook_event_name":"PreModelSwitch","source":"command"'
assert_contains "$(g "{$b,\"context_tokens\":9000,\"prompt_cache_warm\":true}")" '"allow"' "guard: konteks kecil"
o=$(g "{$b,\"from_model\":\"a\",\"to_model\":\"b\",\"context_tokens\":182000,\"prompt_cache_warm\":true,\"estimated_cache_write_usd\":1.14}")
assert_contains "$o" '"ask"' "guard: besar+hangat"; assert_contains "$o" '1.14' "guard: biaya tampil"
assert_contains "$(g "{$b,\"context_tokens\":182000,\"prompt_cache_warm\":false}")" '"allow"' "guard: cache dingin"
assert_eq "$(g '{"hook_event_name":"PreModelSwitch","source":"picker","context_tokens":182000,"prompt_cache_warm":true}')" "" "guard: picker diam"
assert_eq "$(g 'bukan json')" "" "guard: input rusak diam"
assert_contains "$(printf '%s' "{$b,\"context_tokens\":12000,\"prompt_cache_warm\":true}" | CLAUDE_SWITCH_GUARD_TOKENS=5000 python3 -I "$C/hooks/model-switch-guard.py")" '"ask"' "guard: ambang dari env"

# ── statusline ──
sl() { NESTED_STATE_DIR="${2:-/nonexistent}" python3 -I "$C/statusline.py" <<<"$1"; }
assert_eq "$(sl '{"model":{"display_name":"Opus 5.5"},"effort":{"level":"high"},"context_window":{"total_input_tokens":42000,"used_percentage":21}}')" \
          "Opus 5.5 · high · ctx 42k (21%)" "statusline: model effort konteks"
assert_eq "$(sl 'x')" "claude" "statusline: input rusak"
mkdir -p "$H/st/x"; echo RUNNING > "$H/st/x/status"; echo sonnet/light > "$H/st/x/model"; sleep 30 & sp=$!; echo $sp > "$H/st/x/pid"
assert_contains "$(sl '{"model":{"display_name":"Opus 5.5"}}' "$H/st")" "nested 1: sonnet/light" "statusline: sesi nested berjalan"
kill $sp 2>/dev/null; wait $sp 2>/dev/null
assert_absent "$(sl '{"model":{"display_name":"Opus 5.5"}}' "$H/st")" "nested" "statusline: proses mati tidak tampil"

rm -rf "$H"
finish
