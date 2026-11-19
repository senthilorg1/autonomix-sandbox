#!/usr/bin/env bash
# Stage 1 and 2 gate driver (S4.2.5). Runs inside the ci-gates image on the arc-untrusted scale set, in a checkout of the pull request (fetch-depth 0). 
# The workflow runs the copy of this script that is on the main ref, never the pull request's own copy. Gate configuration comes from the image (GATES_DIR),
# the coverage baseline from the main ref. A gate whose tool cannot start FAILS; a gate with no input in the tree PASSES and says so.
# Env: BASE, HEAD (full commit ids of the pull request's base and head), MAIN_REF (default refs/heads/main), GATES_DIR (default /opt/gates), REPORTS (default $RUNNER_TEMP/reports).
set -uo pipefail
GATES_DIR="${GATES_DIR:-/opt/gates}"; MAIN_REF="${MAIN_REF:-refs/heads/main}"; REPORTS="${REPORTS:-${RUNNER_TEMP:-/tmp}/reports}"
: "${BASE:?BASE is required}" "${HEAD:?HEAD is required}"
[[ $BASE =~ ^[0-9a-f]{40}$ && $HEAD =~ ^[0-9a-f]{40}$ ]] || { echo "BASE and HEAD must be full commit ids" >&2; exit 2; }
source "$GATES_DIR/lib.sh"; source "$GATES_DIR/licenses.env"
mkdir -p "$REPORTS/cov"; SUMMARY="${GITHUB_STEP_SUMMARY:-/dev/null}"
export GOPROXY="${GOPROXY:-https://proxy.golang.org}" GOSUMDB="${GOSUMDB:-sum.golang.org}" GOFLAGS=-mod=readonly
PY=/opt/venvs/checkov/bin/python
gate() { local n="$1"; shift; GATE_LOG="$REPORTS/$n.log"; : > "$GATE_LOG"; gate_run "$n" "$@"; local rc=$?; [[ $rc -ne 0 ]] && sed 's/^/      | /' "$GATE_LOG" | tail -n 25; return $rc; }
note() { echo "NOTE  $*"; }
nogate() { echo "PASS  $1 (no input in this tree)"; }

# refs: the manifest and the baseline are read from main, the tree under test is HEAD
git update-ref "$MAIN_REF" "refs/remotes/origin/${MAIN_REF#refs/heads/}" 2>/dev/null || git rev-parse --verify -q "$MAIN_REF" >/dev/null || { echo "cannot find $MAIN_REF"; exit 2; }
MB="$(git merge-base "$BASE" "$HEAD")" || { echo "no merge base"; exit 2; }   # diffs run against the merge base, so changes that landed on main meanwhile are not blamed on the PR
git checkout -q --detach "$HEAD"
echo "base $BASE  head $HEAD  merge-base $MB"

# services of the manifest on main
SERVICES="$(git show "$MAIN_REF:closure-manifest.yaml" | $PY -c 'import sys,yaml;m=yaml.safe_load(sys.stdin)
for n,s in sorted(m["services"].items()): print(n,s["root"])')" || { echo "FAIL  manifest on $MAIN_REF unreadable"; exit 1; }
[[ -n $SERVICES ]] || { echo "FAIL  manifest on $MAIN_REF lists no service"; exit 1; }

# every Go module in the tree must be a declared service (an undeclared module has no closure and no hash)
undeclared() { local d bad=0; while read -r d; do d="${d%/go.mod}"; [[ $d == go.mod ]] && d=.; grep -qE "^[^ ]+ $d\$" <<<"$SERVICES" || { echo "module $d is not declared in closure-manifest.yaml on $MAIN_REF"; bad=1; }; done < <(git ls-tree -r --name-only "$HEAD" | grep -E '(^|/)go\.mod$'); return $bad; }
gate undeclared-modules undeclared

# Stage 1
gate secrets betterleaks git --config "$GATES_DIR/gitleaks.toml" --no-banner --log-opts="$MB..$HEAD" .
RULES=(--config "$GATES_DIR/semgrep/rules"); for v in "$GATES_DIR"/semgrep/vendor/*/; do RULES+=(--config "$v"); done
# Semgrep runs without --error (a tool failure is still a non-zero exit) and the findings are judged here, because exactly one form of an unpinned `uses:` is allowed:
# this repository's own trusted reusable workflow at the short ref `main` (contract 16 section 8, spike 1: `refs/heads/main` is refused at parse time, a SHA is impossible
# for a workflow that must always be the one on main). Any other unpinned reference, including the same file name in another repository, still fails.
semgrep_scan() {
  semgrep scan --metrics=off --disable-version-check --quiet --baseline-commit "$MB" "${RULES[@]}" --sarif --output "$REPORTS/semgrep.sarif" . || return 1
  $PY - "$REPORTS/semgrep.sarif" "${GITHUB_REPOSITORY:-}" <<'PYEOF'
import json,re,sys
sarif,repo=sys.argv[1],sys.argv[2]
allowed=re.compile(r'^\s*-?\s*uses:\s*["\']?'+re.escape(repo)+r'/\.github/workflows/trusted-candidate-build-reusable\.yml@main["\']?\s*(#.*)?$') if repo else None
left=0
for run in json.load(open(sarif)).get("runs",[]):
    for r in run.get("results",[]):
        loc=r["locations"][0]["physicalLocation"]
        if r["ruleId"].endswith("autonomix.action-not-pinned-to-sha") and allowed:
            try:
                line=open(loc["artifactLocation"]["uri"]).read().split("\n")[loc["region"]["startLine"]-1]
            except (OSError,IndexError,KeyError):
                line=""
            if allowed.match(line):
                print("exempt: %s:%s (the trusted reusable workflow of this repository at main)"%(loc["artifactLocation"]["uri"],loc["region"]["startLine"]))
                continue
        left+=1
        print("%s:%s %s: %s"%(loc["artifactLocation"]["uri"],loc["region"].get("startLine"),r["ruleId"],r["message"]["text"]))
sys.exit(1 if left else 0)
PYEOF
}
gate semgrep semgrep_scan
while read -r n root; do
  gate "closure-$n" closure-hash-tool check --service "$n" --commit "$HEAD" --main-ref "$MAIN_REF" && { h="$(closure-hash-tool hash --service "$n" --commit "$HEAD" --main-ref "$MAIN_REF")"; echo "      closure hash of $n: $h"; echo "closure $n $h" >> "$REPORTS/closure-hashes.txt"; }
  gate "govulncheck-$n" bash -c "cd '$root' && govulncheck ./..."
  gate "licenses-$n" bash -c "cd '$root' && go-licenses check ./... --disallowed_types='$DISALLOWED_TYPES' --ignore \"\$(go list -m)\""
done <<<"$SERVICES"
mapfile -t DF < <(git ls-files 'Dockerfile*' '**/Dockerfile*' '*.Dockerfile' '**/*.Dockerfile' | sort -u)
if [[ ${#DF[@]} -gt 0 ]]; then gate hadolint hadolint --config "$GATES_DIR/hadolint.yaml" "${DF[@]}"; else nogate hadolint; fi
if git ls-files '*.yaml' '*.yml' | grep -vE '^(\.github/|gates/)' | xargs -r grep -lE '^apiVersion:' >/dev/null 2>&1; then gate checkov checkov --config-file "$GATES_DIR/checkov.yaml" -d . --skip-path '\.github' --skip-path gates; else nogate checkov; fi
mapfile -t MG < <(git ls-files '**/migrations/*.sql' 'migrations/*.sql' | sort -u)
if [[ ${#MG[@]} -gt 0 ]]; then gate migrations squawk "${MG[@]}"; else nogate migrations; fi
mapfile -t LK < <(git ls-files '**/package-lock.json' 'package-lock.json' '**/pubspec.lock' 'pubspec.lock' | sort -u)
if [[ ${#LK[@]} -gt 0 ]]; then for f in "${LK[@]}"; do gate "osv-$f" osv-scanner scan source --lockfile "$f"; done; else nogate osv-scanner; fi
gate test-integrity gate-tool test-integrity --repo . --base "$MB" --head "$HEAD"

# Stage 2: tests and the coverage ratchet (baseline from main)
RACE=""; if command -v gcc >/dev/null 2>&1; then RACE="-race"; export CGO_ENABLED=1; else note "the race detector is unavailable: this image has no C compiler (tracked, needs a new image version)"; fi
NAMES=""
while read -r n root; do
  NAMES="${NAMES:+$NAMES,}$n"
  gate "tests-$n" bash -c "cd '$root' && go test -count=1 $RACE -coverpkg=./... -coverprofile='$REPORTS/cov/$n.out' ./..."
done <<<"$SERVICES"
git show "$MAIN_REF:gates/coverage-baseline.json" > "$REPORTS/baseline.json" 2>/dev/null || { echo "FAIL  gates/coverage-baseline.json is missing on $MAIN_REF"; GATE_FAILS=$((GATE_FAILS+1)); }
[[ -s $REPORTS/baseline.json ]] && gate coverage-ratchet gate-tool coverage-ratchet --baseline "$REPORTS/baseline.json" --profiles "$REPORTS/cov" --services "$NAMES"

{ echo "### Gates: $([[ $GATE_FAILS -eq 0 ]] && echo passed || echo "$GATE_FAILS failed")"; echo; echo '```'; [[ -f $REPORTS/closure-hashes.txt ]] && cat "$REPORTS/closure-hashes.txt"; echo '```'; } >> "$SUMMARY"
echo; echo "gates failed: $GATE_FAILS"
[[ $GATE_FAILS -eq 0 ]]
