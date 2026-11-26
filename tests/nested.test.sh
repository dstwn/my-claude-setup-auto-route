#!/bin/bash
. "$(dirname "$0")/lib.sh"
H=$(new_home); install_into "$H"; N="$H/.claude/bin/nested-claude"
REPO="$H/repo"; new_repo "$REPO"
export HOME="$H" NESTED_CLAUDE_BIN="$ROOT/tests/stubs/claude" NESTED_STATE_DIR="$H/nested"
mkdir -p "$H/t"
echo "Fix typo in the tooltip label on the settings page. Single file." > "$H/t/light.md"
echo "Add endpoint POST /orders/export that queues a background job and sends a webhook. Database schema gets one new column." > "$H/t/api.md"
echo "Fix authorization bug: users can see other tenants' invoices. Add permission check." > "$H/t/heavy.md"
echo "Show the author name under each blog post title." > "$H/t/author.md"

cls() { "$N" classify "$H/t/$1.md" | sed -n "s/^$2=//p"; }
assert_eq "$(cls light tier)" light "classify light";   assert_eq "$(cls light model)" sonnet "classify light model"
assert_eq "$(cls heavy tier)" heavy "classify heavy";   assert_eq "$(cls heavy model)" opus "classify heavy model"
assert_contains "$("$N" classify "$H/t/heavy.md")" "authn/authz" "classify override"
assert_eq "$(cls api tier)" heavy "classify api (skor 6 = heavy)"
assert_eq "$(cls author tier)" light "classify: 'author' bukan override auth"
assert_contains "$(NESTED_CLAUDE_BIN=/bin/false "$N" classify "$H/t/light.md" --llm)" "tier=light" "classify --llm jatuh ke heuristik"
"$N" classify /tidak/ada >/dev/null 2>&1; [ $? -ne 0 ] && ok || bad "classify file hilang harus gagal"

# start: tunggu sesi selesai
run() { # nama task kind turns cost [opsi...]
  local nm=$1 task=$2 kind=$3 tr=$4 co=$5; shift 5
  STUB_OUT="$H/args-$nm" STUB_KIND=$kind STUB_TURNS=$tr STUB_COST=$co "$N" start --name "$nm" --repo "$REPO" --task-file "$H/t/$task.md" "$@" >"$H/out-$nm" 2>&1
  local i; for i in $(seq 1 50); do [ "$(cat "$H/nested/$nm/status" 2>/dev/null)" != RUNNING ] && break; sleep 0.2; done
}
arg() { grep -A1 "^$2\$" "$H/args-$1" | tail -1; }

run a1 light ok 12 0.3 --tier auto
assert_eq "$(arg a1 --model)" sonnet "auto light: model"; assert_eq "$(arg a1 --max-turns)" 60 "auto light: turn"; assert_eq "$(arg a1 --max-budget-usd)" 3 "auto light: biaya"
assert_contains "$(cat "$H/out-a1")" "auto-tier -> light / sonnet" "auto light: pesan"
# pagar keselamatan sesi nested: tanpa prompt izin, force-push dan push ke main ditolak
a1=$(cat "$H/args-a1")
assert_eq "$(arg a1 --permission-mode)" dontAsk "permission-mode dontAsk"
for d in "Bash(git push --force:*)" "Bash(git push -f:*)" "Bash(git push origin main:*)" "Bash(git push origin master:*)" "Bash(git push --delete:*)"; do
  assert_contains "$a1" "$d" "DENY memuat $d"
done
run a2 heavy ok 40 0.5 --tier auto
assert_eq "$(arg a2 --model)" opus "auto heavy: model"; assert_eq "$(arg a2 --max-turns)" 150 "auto heavy: turn"; assert_eq "$(arg a2 --max-budget-usd)" 10 "auto heavy: biaya"
run a3 light ok 12 0.3 --tier auto --model opus
assert_eq "$(arg a3 --model)" opus "--model eksplisit menang"; assert_eq "$(arg a3 --max-turns)" 60 "--model eksplisit: tier tetap light"
run a4 api ok 30 1.0 --tier medium
assert_eq "$(arg a4 --max-turns)" 100 "tier medium: turn"; assert_eq "$(arg a4 --max-budget-usd)" 6 "tier medium: biaya"
run a5 light limit 60 2.8 --tier auto
run a6 light block 3 0.1 --tier auto
assert_eq "$(cat "$H/nested/a1/status")" DONE "status DONE"
assert_eq "$(cat "$H/nested/a5/status")" LIMIT "status LIMIT"
assert_eq "$(cat "$H/nested/a6/status")" BLOCKED "status BLOCKED"

# validasi opsi
"$N" start --name b1 --repo "$REPO" --task-file "$H/t/light.md" --tier foo >/dev/null 2>&1; [ $? -ne 0 ] && ok || bad "--tier salah harus gagal"
"$N" start --name b2 --repo "$REPO" --task-file "$H/t/light.md" --ids bogus >/dev/null 2>&1; [ $? -ne 0 ] && ok || bad "--ids salah harus gagal"
"$N" start --name b3 --repo "$REPO" --task-file "$H/t/light.md" --ids 'PROJ-1;x' >/dev/null 2>&1; [ $? -ne 0 ] && ok || bad "--ids dengan karakter berbahaya harus gagal"
run k1 light ok 5 0.1 --tier auto --ids PROJ-12 --draft
assert_contains "$(cat "$H/nested/k1/prompt.md")" 'starts with `PROJ-12: `' "prompt memuat konvensi key"
assert_contains "$(cat "$H/nested/k1/prompt.md")" "review-lessons.md" "prompt memuat lessons"

# riwayat dan report
n=$(wc -l < "$H/nested/runs.jsonl"); assert_eq "$n" 7 "jumlah baris runs.jsonl"
python3 - "$H/nested/runs.jsonl" <<'PY' && ok || bad "isi runs.jsonl"
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1])]
by = {r["name"]: r for r in rows}
assert by["a1"]["status"] == "DONE" and by["a1"]["tier"] == "light" and by["a1"]["tier_source"] == "auto" and by["a1"]["pr"] is True
assert by["a5"]["status"] == "LIMIT" and by["a6"]["status"] == "BLOCKED"
assert by["a4"]["tier_source"] == "manual" and by["a2"]["override"], by["a2"]
assert by["k1"]["ids"] == "PROJ-12" and "task" not in json.dumps(rows).lower()
PY
rep=$("$N" report); assert_contains "$rep" "Riwayat: 7 sesi" "report total"; assert_contains "$rep" "light/sonnet" "report per tier/model"
"$N" report --json | python3 -c '
import json, sys
d = json.load(sys.stdin)
assert d["total"]["n"] == 7 and abs(d["total"]["done"] - 5 / 7) < 1e-9, d["total"]
g = d["groups"]["tier/model"]["light/sonnet"]
assert g["n"] == 4 and g["done"] == 0.5 and g["limit"] == 0.25 and g["failed"] == 0.25, g
' && ok || bad "report --json: angka per kelompok"
assert_contains "$("$N" report --days 1)" "Riwayat: 7 sesi" "report --days"
"$N" report --foo >/dev/null 2>&1; [ $? -ne 0 ] && ok || bad "report opsi salah harus gagal"
E=$(mktemp -d); assert_contains "$(NESTED_STATE_DIR=$E "$N" report)" "belum ada riwayat" "report kosong"

# parent-branch: key generik
assert_contains "$("$N" parent-branch --repo "$REPO" --branch PROJ-12-export-csv --no-push 2>&1)" "status=created" "parent-branch PROJ"
assert_contains "$("$N" parent-branch --repo "$REPO" --branch IDS-958-x --no-push 2>&1)" "status=created" "parent-branch IDS"
"$N" parent-branch --repo "$REPO" --branch bad-branch --no-push >/dev/null 2>&1; [ $? -ne 0 ] && ok || bad "parent-branch tanpa key harus gagal"
assert_contains "$(git -C "$REPO" log --all --format=%s)" "PROJ-12: integration branch" "commit kosong parent"

# escalate: naik satu tier saat LIMIT/FAILED/DONE_NO_PR, di worktree yang sama
run e1 light limit 60 2.5 --tier auto --ids PROJ-1 --skill poteto-mode
assert_eq "$(cat "$H/nested/e1/status")" LIMIT "escalate: e1 LIMIT"
assert_contains "$("$N" escalate e1 --dry-run)" "e1-esc (tier medium, model sonnet" "escalate --dry-run"
assert_no_file "$H/nested/e1-esc" "dry-run tidak membuat sesi"
STUB_OUT="$H/args-e1esc" STUB_KIND=ok STUB_TURNS=30 STUB_COST=1.2 "$N" escalate e1 >"$H/out-e1esc" 2>&1
assert_eq "$(cat "$H/nested/e1-esc/status")" DONE "escalate: e1-esc selesai"
assert_eq "$(arg e1esc --model)" sonnet "escalate light->medium: model"
assert_eq "$(arg e1esc --max-turns)" 100 "escalate light->medium: turn"
assert_eq "$(arg e1esc --max-budget-usd)" 6 "escalate light->medium: biaya"
assert_eq "$(cat "$H/nested/e1-esc/worktree")" "$(cat "$H/nested/e1/worktree")" "escalate: worktree sama"
assert_eq "$(cat "$H/nested/e1-esc/branch")" "$(cat "$H/nested/e1/branch")" "escalate: cabang sama"
assert_contains "$(cat "$H/nested/e1-esc/prompt.md")" "ESCALATION NOTE" "escalate: catatan di prompt"
assert_contains "$(cat "$H/nested/e1-esc/prompt.md")" "status LIMIT" "escalate: status lama di catatan"
assert_contains "$(cat "$H/nested/e1-esc/prompt.md")" "poteto-mode" "escalate: --skill terbawa"
assert_contains "$(cat "$H/nested/e1-esc/prompt.md")" "PROJ-1: " "escalate: --ids terbawa"
assert_contains "$(tail -1 "$H/nested/runs.jsonl")" '"escalated_from": "e1"' "escalate: runs.jsonl mencatat asal"
assert_contains "$(tail -1 "$H/nested/runs.jsonl")" '"tier": "medium"' "escalate: runs.jsonl tier baru"
# sudah DONE: tidak dinaikkan
out=$("$N" escalate e1-esc 2>&1); [ $? -ne 0 ] && ok || bad "escalate DONE harus gagal"
assert_contains "$out" "status DONE" "escalate DONE: pesan"
# rantai: light -> medium -> heavy, nama bertambah, model & batas heavy
run e4 light limit 60 2.5 --tier auto
STUB_OUT="$H/args-e4a" STUB_KIND=limit "$N" escalate e4 >/dev/null 2>&1
assert_eq "$(cat "$H/nested/e4-esc/status")" LIMIT "escalate rantai: e4-esc LIMIT"
STUB_OUT="$H/args-e4b" STUB_KIND=ok "$N" escalate e4-esc >/dev/null 2>&1
assert_eq "$(cat "$H/nested/e4-esc2/status")" DONE "escalate rantai: e4-esc2 selesai"
assert_eq "$(arg e4b --model)" opus "escalate medium->heavy: model"
assert_eq "$(arg e4b --max-turns)" 150 "escalate medium->heavy: turn"
assert_eq "$(arg e4b --max-budget-usd)" 10 "escalate medium->heavy: biaya"
# heavy tidak bisa naik lagi; BLOCKED dan sesi tak dikenal ditolak
run e2h heavy limit 150 9 --tier auto
out=$("$N" escalate e2h 2>&1); [ $? -ne 0 ] && ok || bad "escalate heavy harus gagal"
assert_contains "$out" "tertinggi" "escalate heavy: pesan"
run e3b light block 3 0.1 --tier auto
out=$("$N" escalate e3b 2>&1); [ $? -ne 0 ] && ok || bad "escalate BLOCKED harus gagal"
assert_contains "$out" "status BLOCKED" "escalate BLOCKED: pesan"
"$N" escalate tidak-ada >/dev/null 2>&1; [ $? -ne 0 ] && ok || bad "escalate sesi hilang harus gagal"
"$N" escalate 'a;b' >/dev/null 2>&1; [ $? -ne 0 ] && ok || bad "escalate NAME berbahaya harus gagal"
"$N" escalate e1 --bogus >/dev/null 2>&1; [ $? -ne 0 ] && ok || bad "escalate opsi salah harus gagal"

rm -rf "$H" "$E"
finish
