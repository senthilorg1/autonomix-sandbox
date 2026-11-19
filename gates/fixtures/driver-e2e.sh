#!/usr/bin/env bash
# End-to-end test of gates/run-gates.sh inside the ci-gates image against a simulated sandbox repository (a bare origin, main, pull request branches).
# Needs docker and the local image (default autonomix/ci-gates:local, `infra/local/scripts/s16-gates-image.sh build`). Nothing leaves this machine.
#   gates/fixtures/driver-e2e.sh            all cases
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"; IMAGE="${IMAGE:-autonomix/ci-gates:local}"; REPO_NAME="fixture/fixture"
W="$(mktemp -d)"; trap 'chmod -R u+w "$W" 2>/dev/null; rm -rf -- "${W:?}"' EXIT
G="git -c user.name=t -c user.email=t@e.test -c commit.gpgsign=false"
git init -q --bare "$W/origin.git"; git clone -q "$W/origin.git" "$W/work" 2>/dev/null; cd "$W/work" || exit 2
$G checkout -q -b main
S="$ROOT/docs/s4-sandbox/s4-2-5"; cp -r "$S/closure-manifest.yaml" "$S/backend" "$S/gates" . ; mkdir -p .github/workflows
cp "$ROOT/gates/run-gates.sh" gates/run-gates.sh
$G add -A; $G commit -qm base; $G push -q origin main; BASE="$(git rev-parse HEAD)"
fails=0
# case <name> <expected: pass|fail> <gate that must fail, or ""> <setup function>
run_case() {
  local name="$1" expect="$2" gate="$3" setup="$4"
  cd "$W/work" && $G checkout -q -B "pr-$RANDOM" "$BASE" && "$setup" && $G add -A && $G commit -qm "$name" && local head; head="$(git rev-parse HEAD)"
  git fetch -q origin 2>/dev/null; rm -rf "$W/reports"; mkdir -p "$W/reports"
  docker run --rm --user "$(id -u):$(id -g)" --tmpfs /home/runner:exec,mode=1777 -e HOME=/home/runner -e RUNNER_TEMP=/home/runner/tmp -e REPORTS=/reports \
    -e BASE="$BASE" -e HEAD="$head" -e GITHUB_REPOSITORY="$REPO_NAME" -e GIT_CONFIG_COUNT=1 -e GIT_CONFIG_KEY_0=safe.directory -e GIT_CONFIG_VALUE_0='*' \
    -v "$W/work:/w" -v "$W/reports:/reports" -w /w --entrypoint bash "$IMAGE" -c 'mkdir -p /home/runner/tmp; bash gates/run-gates.sh' > "$W/out.txt" 2>&1
  local rc=$?
  local ok=1
  if [[ $expect == pass ]]; then [[ $rc -eq 0 ]] || ok=0; else [[ $rc -ne 0 ]] || ok=0; fi
  if [[ -n $gate ]]; then grep -q "^FAIL  $gate" "$W/out.txt" || ok=0; fi
  if [[ $ok -eq 1 ]]; then echo "ok    $name"; else echo "BAD   $name (exit $rc, wanted $expect ${gate:+with $gate failing})"; sed 's/^/        /' "$W/out.txt" | tail -n 25; fails=$((fails+1)); fi
}
wf() { mkdir -p .github/workflows; cat > ".github/workflows/trusted-candidate-build.yml" <<E2
name: trusted-candidate-build
on:
  pull_request:
permissions: {}
jobs:
  build:
    permissions:
      contents: read
      id-token: write
    uses: $1
E2
}
c_clean() { printf '\n// a clean change\n' >> backend/demo-svc/main.go; }
c_own()   { wf "$REPO_NAME/.github/workflows/trusted-candidate-build-reusable.yml@main"; }
c_foreign() { wf "evil/repo/.github/workflows/trusted-candidate-build-reusable.yml@main"; }
c_longref() { wf "$REPO_NAME/.github/workflows/trusted-candidate-build-reusable.yml@refs/heads/main"; }
c_rel_own()     { wf "$REPO_NAME/.github/workflows/release-promote-reusable.yml@main"; }
c_rel_foreign() { wf "evil/repo/.github/workflows/release-promote-reusable.yml@main"; }
c_rel_longref() { wf "$REPO_NAME/.github/workflows/release-promote-reusable.yml@refs/heads/main"; }
c_rel_and_tag() { c_rel_own; c_tag; }
c_otherfile() { wf "$REPO_NAME/.github/workflows/other.yml@main"; }
c_tag()   { mkdir -p .github/workflows; cat > .github/workflows/x.yml <<'E3'
name: x
on: workflow_dispatch
permissions:
  contents: read
jobs:
  j:
    runs-on: arc-untrusted
    steps:
      - uses: actions/checkout@v4
        with:
          persist-credentials: false
E3
}
c_own_and_tag() { c_own; c_tag; }
run_case "clean change passes every gate"                                 pass ""        c_clean
run_case "own trusted reusable workflow at @main is allowed"             pass ""        c_own
run_case "the same file name in another repository is refused"           fail semgrep   c_foreign
run_case "the long ref @refs/heads/main is refused"                      fail semgrep   c_longref
run_case "another workflow of this repository at @main is refused"       fail semgrep   c_otherfile
run_case "an action pinned to a tag is refused"                          fail semgrep   c_tag
run_case "the allowed form does not hide a tag in the same change"       fail semgrep   c_own_and_tag
run_case "own release promotion reusable workflow at @main is allowed"     pass ""        c_rel_own
run_case "the release workflow name in another repository is refused"     fail semgrep   c_rel_foreign
run_case "the release workflow at the long ref is refused"                fail semgrep   c_rel_longref
run_case "the release form does not hide a tag in the same change"        fail semgrep   c_rel_and_tag
echo; if [[ $fails -eq 0 ]]; then echo "driver e2e: all cases as expected"; else echo "driver e2e: $fails case(s) differ"; fi
[[ $fails -eq 0 ]]
