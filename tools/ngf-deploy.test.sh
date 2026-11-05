#!/bin/sh
# Exercises tools/ngf-deploy against a fake `gh` that answers from a small
# table of releases, statuses and deployments, and records every
# `gh workflow run` it is asked for. Checks when a deploy is started, skipped
# or refused, without touching GitHub.
set -eu

here=$(cd "$(dirname "$0")" && pwd)
t=$(mktemp -d)
trap 'rm -rf "$t"' EXIT
mkdir "$t/bin"

# The fake gh. Its answers are already what the real gh prints after -q.
# FAKE_STATUSES: the tag's commit statuses ("staging/smoke=success ...").
# $t/jobs records each job looked up, to check how many lookups were needed.
# $t/deploys: "<env> <deployment id> <state> <run> <job> <version> <deployed>".
cat > "$t/bin/gh" <<'EOF'
#!/bin/sh
t=$FAKE_DIR
case "$1 $2" in
"auth status") exit 0 ;;
"release view") echo "$FAKE_LATEST"; exit 0 ;;
"workflow run") shift 2; echo "$*" >> "$t/started"; echo 1 >> "$t/runs"; exit 0 ;;
"run list") wc -l < "$t/runs" | tr -d ' '; exit 0 ;;
"run watch") exit "${FAKE_WATCH_RC:-0}" ;;
"run view") echo "deploy step: refused by the fake"; exit 0 ;;
esac
[ "$1" = api ] || { echo "fake gh: unexpected $*" >&2; exit 1; }
case $2 in
graphql)
    # What ngf-deploy's -q turns the answer into: facts, then deployments.
    # A tag given with -v exists unless it is FAKE_MISSING_TAG.
    tag=''
    for a in "$@"; do case $a in tag=refs/tags/*) tag=${a#tag=refs/tags/} ;; esac; done
    echo "deploy_yml=true"
    echo "latest=$FAKE_LATEST"
    if [ "$tag" = "${FAKE_MISSING_TAG:-}" ]; then echo "sha="; else echo "sha=0123456789abcdef"; fi
    echo "statuses=$FAKE_STATUSES"
    awk '{ print "dep", $1, $2, $3, $4, $5 }' "$t/deploys" ;;
*/actions/jobs/*)
    job=${2##*/}
    echo "$job" >> "$t/jobs"
    awk -v j="$job" '$5 == j { print $6, $7 }' "$t/deploys" ;;
*) echo "fake gh: unexpected $*" >&2; exit 1 ;;
esac
EOF
chmod +x "$t/bin/gh"

export PATH="$t/bin:$PATH" FAKE_DIR="$t"
fail() { echo "FAIL: $*"; echo "--- output"; cat "$t/out"; exit 1; }

# <expected exit> <args...>: runs ngf-deploy for ninja-monitor with a clean
# record of started runs.
run() {
    want=$1
    shift
    : > "$t/started"
    : > "$t/jobs"
    echo 1 > "$t/runs"
    rc=0
    ${NGF_SH:-sh} "$here/ngf-deploy" ninja-monitor "$@" > "$t/out" 2>&1 || rc=$?
    [ "$rc" = "$want" ] || fail "ngf-deploy $* exited $rc, want $want"
}
started() { [ -s "$t/started" ]; }
says() { grep -q -- "$1" "$t/out" || fail "output lacks: $1"; }

export FAKE_LATEST=v1.1.0 FAKE_STATUSES='staging/smoke=success'

echo 'prod v1.0.0 live (an older success went inactive), latest v1.1.0 passed staging: deploys'
cat > "$t/deploys" <<'EOF'
prod 30 success 300 3000 v1.0.0 true
prod 20 inactive 200 2000 v0.9.0 true
staging 10 success 100 1000 v1.1.0 true
EOF
run 0
started || fail "no deploy started"
says 'live      v1.0.0 on prod'
grep -q 'env=prod -f version=v1.1.0$' "$t/started" || fail "started: $(cat "$t/started")"

echo 'v1.1.0 already live on prod: nothing started'
echo 'prod 40 success 400 4000 v1.1.0 true' > "$t/deploys"
run 0
started && fail "started a deploy of a version already live"
says 'already live on prod; nothing to do'

echo 'same, with -f: deploys again'
run 0 -f
started || fail "-f did not deploy"

echo 'a deploy of v1.1.0 is waiting for approval: nothing started'
cat > "$t/deploys" <<'EOF'
prod 50 waiting 500 5000 v1.1.0 false
prod 30 success 300 3000 v1.0.0 true
EOF
run 0
started && fail "started a second deploy while one waits"
says 'already under way: https://github.com/NinjaGoldfinch/ninja-monitor/actions/runs/500'
says 'live      v1.0.0 on prod'

echo 'a failed prod deploy (rolled back on the host) is not live'
cat > "$t/deploys" <<'EOF'
prod 60 failure 600 6000 v1.1.0 false
prod 30 success 300 3000 v1.0.0 true
EOF
run 0
says 'live      v1.0.0 on prod'
started || fail "no deploy started"

echo 'staging: the deploy went live but its smoke test failed; v1.1.0 counts as live there'
echo 'staging 70 failure 700 7000 v1.1.0 true' > "$t/deploys"
run 0 -e staging
says 'live      v1.1.0 on staging'
started && fail "redeployed what is live on staging"

echo 'prod, v1.1.0 never passed staging: refused before anything starts'
echo 'prod 30 success 300 3000 v1.0.0 true' > "$t/deploys"
FAKE_STATUSES='staging/smoke=failure' run 1
started && fail "started a deploy that the gate refuses"
says 'refused: v1.1.0 has passed neither staging'

echo 'same with -b: deploys with break_glass'
FAKE_STATUSES='' run 0 -b 'host on fire'
grep -q "break_glass=host on fire" "$t/started" || fail "break_glass not passed: $(cat "$t/started")"

echo 'rollback to v1.0.0, which was live in prod before (prod/deployed): deploys'
echo 'prod 40 success 400 4000 v1.1.0 true' > "$t/deploys"
FAKE_STATUSES='prod/deployed=success' run 0 -v v1.0.0
started || fail "rollback not started"

echo 'no deployments at all: live unknown, deploys'
: > "$t/deploys"
run 0
says 'live      unknown on prod'
started || fail "no deploy started"

echo '-w and the run fails: exit 1 with the failed log'
FAKE_WATCH_RC=1 run 1 -w
says 'did not deploy'
says 'refused by the fake'

echo '-d prints the gh commands'
run 0 -d
says '\[debug\] gh api graphql -F owner=NinjaGoldfinch -F repo=ninja-monitor'

echo '-v with a tag that does not exist: refused, not the latest release'
FAKE_MISSING_TAG=v9.9.9 run 1 -v v9.9.9
says 'ninja-monitor has no tag v9.9.9'
started && fail "started a deploy of a missing tag"

echo 'only the jobs needed are looked up: the newest prod deployment is live'
cat > "$t/deploys" <<'EOF2'
prod 90 success 900 9000 v1.1.0 true
prod 80 inactive 800 8000 v1.0.0 true
prod 70 inactive 700 7000 v0.9.0 true
staging 60 success 600 6000 v1.1.0 true
EOF2
run 0
[ "$(cat "$t/jobs")" = 9000 ] || fail "looked up jobs: $(tr '\n' ' ' < "$t/jobs")"

echo 'all: each repository is checked and reported in order'
: > "$t/started"
echo 1 > "$t/runs"
sh "$here/ngf-deploy" all > "$t/out" 2>&1 || fail "ngf-deploy all failed"
[ "$(grep -c 'already live on prod' "$t/out")" = 3 ] || fail "not every repository reported"
grep ' -> prod$' "$t/out" | cut -d' ' -f1 | tr '\n' ' ' | grep -q 'ninja-monitor riot-proxy ninjagoldfinch-lol' \
    || fail "repositories out of order"

echo 'bad arguments'
run 1 -b
run 1 -e staging -b 'why'
run 1 -v

echo "ngf-deploy: all tests passed"
