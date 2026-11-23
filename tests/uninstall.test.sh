#!/bin/bash
. "$(dirname "$0")/lib.sh"
UN="$ROOT/uninstall-claude-setup.sh"
snap() { (cd "$1/.claude" && find . -type f -not -path './uninstalled-*' | sort | while read -r f; do printf '%s %s\n' "$f" "$(md5sum < "$f")"; done); }
trash() { ls -d "$1"/.claude/uninstalled-* 2>/dev/null | head -1; }
setup() { # $1 = home; tambahkan barang milik pengguna lalu install
  local C="$1/.claude"; mkdir -p "$C/agents" "$C/skills/mine" "$C/skills/code-review"
  echo "mine" > "$C/agents/mine.md"; echo "skill saya" > "$C/skills/mine/SKILL.md"
  printf '# aturan saya\n- jangan lupa X\n' > "$C/CLAUDE.md"
  echo "- aturan lama" > "$C/review-lessons.md"; echo "Bash(make:*)" > "$C/nested-allow.txt"
  printf -- '---\nname: code-review\ncontext: fork\nagent: critic\n---\nisi\n' > "$C/skills/code-review/SKILL.md"
  cat > "$C/settings.json" <<'JSON'
{"theme":"dark","hooks":{"PreModelSwitch":[{"hooks":[{"type":"command","command":"/x/other.sh"}]}],
 "Stop":[{"hooks":[{"type":"command","command":"/x/stop.sh"}]}]}}
JSON
  install_into "$1"
}

H=$(new_home); setup "$H"; C="$H/.claude"
assert_file "$C/agents/critic.md"; assert_file "$C/bin/nested-claude"
mkdir -p "$C/nested/s1"; echo DONE > "$C/nested/s1/status"; echo '{"x":1}' > "$C/nested/runs.jsonl"

# dry-run tidak mengubah apa pun
before=$(snap "$H"); out=$(HOME="$H" bash "$UN" --dry-run 2>&1); rc=$?
assert_eq "$rc" 0 "dry-run exit code"; assert_eq "$(snap "$H")" "$before" "dry-run tidak mengubah file"
assert_contains "$out" "pindah  ~/.claude/agents/critic.md" "dry-run: daftar rencana"; assert_contains "$out" "hook PreModelSwitch" "dry-run: rencana settings"
assert_eq "$(trash "$H")" "" "dry-run tidak membuat folder cadangan"

# tanpa --yes dan tidak interaktif: menolak
HOME="$H" bash "$UN" </dev/null >/dev/null 2>&1; [ $? -ne 0 ] && ok || bad "tanpa --yes harus menolak saat tidak interaktif"
assert_eq "$(snap "$H")" "$before" "penolakan tidak mengubah file"
HOME="$H" bash "$UN" --bogus >/dev/null 2>&1; assert_eq "$?" 2 "opsi tidak dikenal exit 2"

# sesi nested berjalan memblokir
mkdir -p "$C/nested/live"; echo RUNNING > "$C/nested/live/status"; sleep 30 & sp=$!; echo $sp > "$C/nested/live/pid"
HOME="$H" bash "$UN" --yes >/dev/null 2>&1; [ $? -ne 0 ] && ok || bad "sesi berjalan harus memblokir"
assert_file "$C/agents/critic.md"
kill $sp 2>/dev/null; wait $sp 2>/dev/null; rm -rf "$C/nested/live"

# uninstall sungguhan
out=$(HOME="$H" bash "$UN" --yes 2>&1); assert_eq "$?" 0 "uninstall exit code"
for f in agents/scout.md agents/Explore.md agents/builder.md agents/builder-isolated.md agents/critic.md agents/critic-lite.md \
         hooks/readonly-bash.py hooks/worktree-create.sh hooks/model-switch-guard.py bin/nested-claude statusline.py model-routing.md \
         skills/nested-implement/SKILL.md skills/receiving-codereview/SKILL.md; do assert_no_file "$C/$f"; done
assert_no_file "$C/bin"; assert_no_file "$C/hooks"
T=$(trash "$H"); assert_file "$T/agents/critic.md"; assert_file "$T/settings.json"; assert_file "$T/CLAUDE.md"
# milik pengguna utuh
assert_eq "$(cat "$C/agents/mine.md")" mine "agent milik pengguna"; assert_eq "$(cat "$C/skills/mine/SKILL.md")" "skill saya" "skill milik pengguna"
assert_eq "$(cat "$C/review-lessons.md")" "- aturan lama" "review-lessons.md tak disentuh"; assert_file "$C/nested-allow.txt"
assert_contains "$(cat "$C/CLAUDE.md")" "- jangan lupa X" "CLAUDE.md: baris pengguna tetap"; assert_absent "$(cat "$C/CLAUDE.md")" "model-routing.md" "CLAUDE.md: import dihapus"
assert_file "$C/nested/runs.jsonl"
cr=$(cat "$C/skills/code-review/SKILL.md"); assert_absent "$cr" "context: fork" "patch code-review dilepas"; assert_contains "$cr" "name: code-review" "code-review: frontmatter lain tetap"
python3 - "$C/settings.json" <<'PY' && ok || bad "settings.json setelah uninstall"
import json, sys
d = json.load(open(sys.argv[1]))
assert d["theme"] == "dark" and d["model"] == "opus"
cmds = [h["command"] for e in d["hooks"]["PreModelSwitch"] for h in e["hooks"]]
assert cmds == ["/x/other.sh"], cmds
assert "Stop" in d["hooks"] and "WorktreeCreate" not in d["hooks"] and "statusLine" not in d
assert "Bash(git log:*)" in d["permissions"]["allow"]
PY

# kedua kali: tidak ada yang tersisa
out=$(HOME="$H" bash "$UN" --yes 2>&1); assert_eq "$?" 0 "uninstall kedua exit code"; assert_contains "$out" "tidak ada yang perlu dihapus" "uninstall kedua"

# install lagi setelah uninstall berfungsi (round trip)
install_into "$H"; assert_eq "$?" 0 "install ulang setelah uninstall"; assert_file "$C/agents/critic.md"

# --purge dan --with-ids-layer
mkdir -p "$C/skills/ids-spec-parallel-pr"; echo x > "$C/skills/ids-spec-parallel-pr/SKILL.md"
HOME="$H" bash "$UN" --yes >/dev/null 2>&1; assert_file "$C/skills/ids-spec-parallel-pr/SKILL.md"
HOME="$H" bash "$UN" --yes --purge --with-ids-layer >/dev/null 2>&1
assert_no_file "$C/skills/ids-spec-parallel-pr"; assert_no_file "$C/nested"

# statusLine milik pengguna dibiarkan
H2=$(new_home); echo '{"statusLine":{"type":"command","command":"my-own"}}' > "$H2/.claude/settings.json"; install_into "$H2"
HOME="$H2" bash "$UN" --yes >/dev/null 2>&1
assert_contains "$(cat "$H2/.claude/settings.json")" "my-own" "statusLine pengguna tetap"

# HOME tanpa .claude
H3=$(mktemp -d); out=$(HOME="$H3" bash "$UN" --yes 2>&1); assert_eq "$?" 0 "tanpa ~/.claude exit code"

rm -rf "$H" "$H2" "$H3"
finish
