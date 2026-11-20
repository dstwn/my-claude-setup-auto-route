#!/bin/bash
. "$(dirname "$0")/lib.sh"
H=$(new_home); C="$H/.claude"

install_into "$H"; rc=$?
assert_eq "$rc" 0 "install pertama exit code"
log=$(cat "$H/install.log")
for m in "self-test hook lulus" "self-test hook worktree lulus" "self-test model-switch-guard lulus" "self-test statusline lulus"; do
  assert_contains "$log" "$m" "log install"
done
assert_absent "$log" "GAGAL" "log install"

for a in scout:haiku Explore:haiku builder:inherit builder-isolated:inherit critic:opus critic-lite:sonnet; do
  f="$C/agents/${a%%:*}.md"; assert_file "$f"
  assert_contains "$(cat "$f" 2>/dev/null)" "model: ${a##*:}" "model agent ${a%%:*}"
done
for f in hooks/readonly-bash.py hooks/worktree-create.sh hooks/model-switch-guard.py bin/nested-claude statusline.py model-routing.md \
         skills/nested-implement/SKILL.md skills/receiving-codereview/SKILL.md; do assert_file "$C/$f"; done
assert_contains "$(cat "$C/CLAUDE.md" 2>/dev/null)" "model-routing.md" "CLAUDE.md mengimpor routing"
assert_no_file "$C/skills/ids-spec-parallel-pr"
assert_no_file "$C/skills/to-tickets-preferences"
for f in builder builder-isolated critic critic-lite; do
  assert_contains "$(cat "$C/agents/$f.md")" "review-lessons.md" "$f membaca lessons"
done

s=$(cat "$C/settings.json")
assert_eq "$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d.get("model"))' "$C/settings.json")" "opus" "settings model"
for k in WorktreeCreate PreModelSwitch; do
  assert_contains "$s" "$k" "settings hooks.$k"
done
assert_contains "$s" "statusLine" "settings statusLine"

# idempotent: run ulang tidak mengubah apa pun dan tidak membuat backup
cp "$C/settings.json" "$H/settings.before"
install_into "$H"; assert_eq "$?" 0 "install ulang exit code"
cmp -s "$C/settings.json" "$H/settings.before" && ok || bad "settings.json berubah saat install ulang"
n=$(find "$C" -name '*.bak-*' | wc -l); assert_eq "$n" 0 "jumlah file backup setelah install ulang"
n=$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["hooks"]["PreModelSwitch"]))' "$C/settings.json")
assert_eq "$n" 1 "PreModelSwitch tidak ganda"

# settings milik pengguna dihormati
H2=$(new_home)
cat > "$H2/.claude/settings.json" <<'JSON'
{"theme":"dark","statusLine":{"type":"command","command":"my-own"},
 "hooks":{"PreModelSwitch":[{"hooks":[{"type":"command","command":"/x/other.sh"}]}]}}
JSON
install_into "$H2"; assert_eq "$?" 0 "install dengan settings milik pengguna"
python3 - "$H2/.claude/settings.json" <<'PY' && ok || bad "settings pengguna tidak dihormati"
import json, sys
d = json.load(open(sys.argv[1]))
assert d["theme"] == "dark"
assert d["statusLine"]["command"] == "my-own"
cmds = [h["command"] for e in d["hooks"]["PreModelSwitch"] for h in e["hooks"]]
assert "/x/other.sh" in cmds and any("model-switch-guard.py" in c for c in cmds), cmds
PY

# perubahan file di sisi pengguna tidak hilang tanpa jejak: backup dibuat saat isi berbeda
echo "# edit lokal" >> "$C/agents/scout.md"
install_into "$H"
n=$(find "$C/agents" -name 'scout.md.bak-*' | wc -l); assert_eq "$n" 1 "backup scout.md saat isi berbeda"

# repo publik tidak membawa nama internal
leak=$(grep -n -i "cursor\|manobo\|julie-grace" "$INSTALLER" | head -3)
assert_eq "$leak" "" "nama internal di installer"

rm -rf "$H" "$H2"
finish
