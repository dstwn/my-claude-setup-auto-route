# Pustaka kecil untuk tes. Di-source oleh tests/*.test.sh. Tanpa dependensi selain bash, python3, git.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALLER="$ROOT/install-claude-setup.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); }
bad() { FAIL=$((FAIL + 1)); echo "  GAGAL: $*"; }
assert_eq()       { if [ "$1" = "$2" ]; then ok; else bad "$3: harap [$2], dapat [$1]"; fi; }
assert_contains() { case "$1" in *"$2"*) ok;; *) bad "$3: [$2] tidak ada di: ${1:0:200}";; esac; }
assert_absent()   { case "$1" in *"$2"*) bad "$3: [$2] seharusnya tidak ada";; *) ok;; esac; }
assert_file()     { if [ -e "$1" ]; then ok; else bad "tidak ada: $1"; fi; }
assert_no_file()  { if [ ! -e "$1" ]; then ok; else bad "seharusnya tidak ada: $1"; fi; }
new_home()  { local t; t=$(mktemp -d); mkdir -p "$t/.claude"; echo "$t"; }
install_into() { HOME="$1" bash "$INSTALLER" </dev/null >"$1/install.log" 2>&1; }
new_repo() { git init -q "$1" && git -C "$1" config user.email t@t && git -C "$1" config user.name t \
             && echo a > "$1/a" && git -C "$1" add -A && git -C "$1" commit -qm init; }
finish() { echo "$(basename "$0"): $PASS lulus, $FAIL gagal"; [ "$FAIL" -eq 0 ]; }
