#!/bin/bash
# Jalankan semua tes: bash tests/run.sh [nama-filter]
cd "$(dirname "$0")" || exit 1
rc=0
bash -n ../install-claude-setup.sh || { echo "syntax error di installer"; exit 1; }
for t in *.test.sh; do
  case "$t" in *"${1:-}"*) bash "$t" || rc=1;; esac
done
[ "$rc" -eq 0 ] && echo "SEMUA TES LULUS" || echo "ADA TES GAGAL"
exit "$rc"
