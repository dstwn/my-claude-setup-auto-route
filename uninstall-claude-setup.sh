#!/bin/bash
# Uninstall untuk install-claude-setup.sh. Hanya menyentuh ~/.claude/.
# Tidak ada yang dihapus permanen: semua dipindah ke ~/.claude/uninstalled-<waktu>/ (bisa dikembalikan).
#   --dry-run          tampilkan rencana saja, tanpa mengubah apa pun
#   --yes              jangan tanya konfirmasi (wajib bila tidak interaktif)
#   --purge            pindahkan juga riwayat sesi nested (~/.claude/nested: log, runs.jsonl, state)
#   --with-ids-layer   hapus juga skill lapisan IDS (ids-spec-parallel-pr, to-tickets-preferences)
# Tidak pernah disentuh: review-lessons.md, nested-allow.txt, file *.bak-*, agent/skill/hook buatanmu sendiri.
set -u
CLAUDE_DIR="$HOME/.claude"
dry=0; yes=0; purge=0; ids=0
for a in "$@"; do
  case "$a" in
    --dry-run) dry=1;; --yes|-y) yes=1;; --purge) purge=1;; --with-ids-layer) ids=1;;
    -h|--help) sed -n 2,9p "$0"; exit 0;;
    *) echo "opsi tidak dikenal: $a (lihat --help)"; exit 2;;
  esac
done
command -v python3 >/dev/null 2>&1 || { echo "❌ python3 dibutuhkan (untuk mengedit settings.json)."; exit 1; }
[ -d "$CLAUDE_DIR" ] || { echo "Tidak ada $CLAUDE_DIR; tidak ada yang perlu dihapus."; exit 0; }

FILES=(agents/scout.md agents/Explore.md agents/builder.md agents/builder-isolated.md agents/critic.md agents/critic-lite.md
       hooks/readonly-bash.py hooks/worktree-create.sh hooks/model-switch-guard.py
       bin/nested-claude statusline.py model-routing.md
       skills/nested-implement/SKILL.md skills/receiving-codereview/SKILL.md)
[ "$ids" = 1 ] && FILES+=(skills/ids-spec-parallel-pr/SKILL.md skills/to-tickets-preferences/SKILL.md)
IMPORT_LINE='@~/.claude/model-routing.md'
SETTINGS="$CLAUDE_DIR/settings.json"; CLAUDE_MD="$CLAUDE_DIR/CLAUDE.md"
CR_SKILL="$CLAUDE_DIR/skills/code-review/SKILL.md"
TS=$(date +%Y%m%d-%H%M%S); TRASH="$CLAUDE_DIR/uninstalled-$TS"

# sesi nested yang masih berjalan? jangan dihapus dari bawahnya
for s in "$CLAUDE_DIR"/nested/*/status; do
  [ -f "$s" ] || continue
  [ "$(cat "$s")" = RUNNING ] || continue
  pid=$(cat "$(dirname "$s")/pid" 2>/dev/null || true)
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    echo "❌ Ada sesi nested yang masih berjalan: $(basename "$(dirname "$s")"). Hentikan dulu: nested-claude stop <nama>"; exit 1
  fi
done

# settings.json: hanya entri milik kita (hook WorktreeCreate/PreModelSwitch kita, statusLine kita)
settings_edit() { # $1 = dry|apply
python3 -I - "$SETTINGS" "$1" << 'PYEOF'
import json, os, sys
p, mode = sys.argv[1], sys.argv[2]
if not os.path.exists(p):
    sys.exit(0)
try:
    d = json.load(open(p, encoding="utf-8"))
except Exception:
    print("  ⚠️  settings.json bukan JSON murni; tidak disentuh (hapus entri hook/statusLine kita secara manual)"); sys.exit(0)
ch = []
hooks = d.get("hooks")
if isinstance(hooks, dict):
    for ev, name in (("WorktreeCreate", "worktree-create.sh"), ("PreModelSwitch", "model-switch-guard.py")):
        arr = hooks.get(ev)
        if not isinstance(arr, list):
            continue
        new = []
        for e in arr:
            hs = e.get("hooks") or []
            keep = [h for h in hs if name not in (h.get("command") or "")]
            if len(keep) != len(hs):
                ch.append("hook " + ev)
            if keep or not hs:
                e = dict(e)
                if hs:
                    e["hooks"] = keep
                new.append(e)
        if new:
            hooks[ev] = new
        else:
            hooks.pop(ev)
    if not hooks:
        d.pop("hooks")
sl = d.get("statusLine")
if sl and "statusline.py" in json.dumps(sl):
    d.pop("statusLine"); ch.append("statusLine")
for c in ch:
    print("  settings.json: hapus " + c)
if ch and mode == "apply":
    json.dump(d, open(p, "w", encoding="utf-8"), indent=2, ensure_ascii=False)
    open(p, "a").write("\n")
PYEOF
}

echo "Rencana uninstall (tujuan cadangan: $TRASH):"
found=0
for f in "${FILES[@]}"; do [ -e "$CLAUDE_DIR/$f" ] && { echo "  pindah  ~/.claude/$f"; found=1; }; done
out=$(settings_edit dry); [ -n "$out" ] && { echo "$out"; found=1; }
grep -qxF "$IMPORT_LINE" "$CLAUDE_MD" 2>/dev/null && { echo "  CLAUDE.md: hapus baris $IMPORT_LINE"; found=1; }
if [ -f "$CR_SKILL" ] && grep -q '^context: fork$' "$CR_SKILL" && grep -q '^agent: critic$' "$CR_SKILL"; then
  echo "  skills/code-review/SKILL.md: lepas 'context: fork' dan 'agent: critic' (hasil patch installer)"; found=1
fi
if [ "$purge" = 1 ] && [ -d "$CLAUDE_DIR/nested" ]; then echo "  pindah  ~/.claude/nested (riwayat sesi)"; found=1; fi
[ "$found" = 1 ] || { echo "  (tidak ada yang perlu dihapus)"; exit 0; }
[ "$dry" = 1 ] && { echo; echo "--dry-run: tidak ada yang diubah."; exit 0; }

if [ "$yes" != 1 ]; then
  [ -t 0 ] || { echo "❌ Tidak interaktif: tambahkan --yes untuk melanjutkan."; exit 1; }
  read -rp "Lanjutkan? [y/N]: " ans || ans=""
  case "$ans" in [Yy]*) ;; *) echo "Dibatalkan."; exit 0;; esac
fi

mkdir -p "$TRASH"
for f in "${FILES[@]}"; do
  [ -e "$CLAUDE_DIR/$f" ] || continue
  mkdir -p "$TRASH/$(dirname "$f")"; mv "$CLAUDE_DIR/$f" "$TRASH/$f"
done
for d in skills/nested-implement skills/receiving-codereview skills/ids-spec-parallel-pr skills/to-tickets-preferences bin hooks agents; do
  rmdir "$CLAUDE_DIR/$d" 2>/dev/null || true   # hanya bila sudah kosong
done
[ -f "$SETTINGS" ] && cp "$SETTINGS" "$TRASH/settings.json"
settings_edit apply >/dev/null
if grep -qxF "$IMPORT_LINE" "$CLAUDE_MD" 2>/dev/null; then
  cp "$CLAUDE_MD" "$TRASH/CLAUDE.md"
  grep -vxF "$IMPORT_LINE" "$CLAUDE_MD" > "$CLAUDE_MD.tmp.$$" || true
  mv "$CLAUDE_MD.tmp.$$" "$CLAUDE_MD"
fi
if [ -f "$CR_SKILL" ] && grep -q '^context: fork$' "$CR_SKILL" && grep -q '^agent: critic$' "$CR_SKILL"; then
  mkdir -p "$TRASH/skills/code-review"; cp "$CR_SKILL" "$TRASH/skills/code-review/SKILL.md"
  grep -vxE 'context: fork|agent: critic' "$CR_SKILL" > "$CR_SKILL.tmp.$$" || true
  mv "$CR_SKILL.tmp.$$" "$CR_SKILL"
fi
[ "$purge" = 1 ] && [ -d "$CLAUDE_DIR/nested" ] && mv "$CLAUDE_DIR/nested" "$TRASH/nested"

echo
echo "✅ Selesai. Salinan semua yang dilepas ada di $TRASH"
echo "   Hapus permanen kapan saja dengan: rm -rf \"$TRASH\""
echo "Yang sengaja TIDAK diubah:"
echo "  - \"model\": \"opus\" di settings.json (installer menimpanya; nilai lamamu ada di ~/.claude/settings.json.bak-* bila ada)"
echo "  - allow git read-only (git status/log/diff/show) di settings.json: aman, hapus manual bila mau"
echo "  - review-lessons.md, nested-allow.txt, file *.bak-*, dan riwayat ~/.claude/nested (kecuali --purge)"
echo "Plugin auto-route dilepas terpisah:  /plugin uninstall auto-route   (atau: claude plugin uninstall auto-route)"
echo "Restart Claude Code agar perubahan berlaku."
