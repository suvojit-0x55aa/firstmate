#!/usr/bin/env bash
# fm-pr-attestation-await.sh - wait for a pull request body to carry a
# no-mistakes pipeline attestation bound to the PR's current head commit.
#
# `git push no-mistakes` publishes in two steps: it pushes the commit, then
# re-signs the PR body with an attestation naming the new head. GitHub captures
# the `pull_request` `synchronize` payload at push time, so a gate that judges
# that payload reads the *previous* head's attestation and fails with
# "Pipeline attestation head_sha does not match the current PR head" - and no
# later event re-runs that job, so the check stays red even once the pipeline
# signs the new head seconds afterwards. That publish-order window is what this
# script closes: it polls the live pull request until the attestation names the
# head the forge currently has, then hands those live facts to the gate.
#
# It never decides compliance. The gate action owns the verdict, so a body that
# never binds is still judged, and still fails, against the live head.
#
# Usage:
#   fm-pr-attestation-await.sh --repo <owner/name> --pr <number> [options]
#
# Options:
#   --timeout-seconds <n>   stop waiting after n seconds (default 300)
#   --interval-seconds <n>  seconds between polls (default 10)
#   -h, --help              print this header
#
# When GITHUB_OUTPUT is set, the live pull request facts are appended to it as
# step outputs: body (heredoc-delimited), head-sha, head-ref, author. When the
# pull request cannot be read at all, nothing is written and the caller keeps
# whatever the workflow event payload already gave it.
#
# Exit status is 0 whenever the wait ran, bound or not; 2 for a usage error.
set -eu

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF="$SELF_DIR/fm-pr-attestation-await.sh"

usage() {
  sed -n '2,30{s/^# \{0,1\}//;p;}' "$SELF"
}

die() {
  printf 'fm-pr-attestation-await.sh: %s\n' "$1" >&2
  exit 2
}

note() {
  printf 'fm-pr-attestation-await.sh: %s\n' "$1"
}

REPO=
PR=
TIMEOUT=300
INTERVAL=10

require_count() {
  case "$2" in
    '' | *[!0-9]*) die "$1 requires a whole number of seconds" ;;
  esac
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo)
      [ "$#" -ge 2 ] || die "--repo requires an owner/name"
      REPO=$2
      shift 2
      ;;
    --pr)
      [ "$#" -ge 2 ] || die "--pr requires a pull request number"
      PR=$2
      shift 2
      ;;
    --timeout-seconds)
      [ "$#" -ge 2 ] || die "--timeout-seconds requires a value"
      require_count --timeout-seconds "$2"
      TIMEOUT=$2
      shift 2
      ;;
    --interval-seconds)
      [ "$#" -ge 2 ] || die "--interval-seconds requires a value"
      require_count --interval-seconds "$2"
      INTERVAL=$2
      shift 2
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      die "unknown argument '$1'"
      ;;
  esac
done

[ -n "$REPO" ] || die "--repo is required"
[ -n "$PR" ] || die "--pr is required"
case "$PR" in
  '' | *[!0-9]*) die "--pr requires a whole number" ;;
esac
[ "$INTERVAL" -gt 0 ] || die "--interval-seconds must be greater than zero"

# python3 parses the attestation, exactly as the gate action does. gh reads the
# live pull request. Missing either is not a compliance verdict, so fall back to
# the caller's event payload rather than failing the gate for a tooling gap.
for tool in gh python3; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    note "$tool not found; leaving the gate to judge the workflow event payload"
    exit 0
  fi
done

WORK=$(mktemp -d "${TMPDIR:-/tmp}/fm-pr-attestation.XXXXXX") || die "could not create a work directory"
trap 'rm -rf "$WORK"' EXIT
FACTS="$WORK/facts"
mkdir -p "$FACTS"

PARSER="$WORK/parse.py"
cat > "$PARSER" <<'PY'
"""Split a pull request API snapshot into the facts the gate judges.

The attestation is located exactly as the shared gate verifier locates it, so a
body this script reports as bound is a body that verifier accepts as bound.
"""

import json
import os
import sys

MARKER = "<!-- no-mistakes-pipeline-attestation:v1 "
CLOSING = " -->"


def text(value):
    return value if isinstance(value, str) else ""


def attested_head(body):
    start = body.find(MARKER)
    if start < 0:
        return ""
    start += len(MARKER)
    end = body.find(CLOSING, start)
    if end < 0:
        return ""
    try:
        payload = json.loads(body[start:end])
    except ValueError:
        return ""
    if not isinstance(payload, dict):
        return ""
    return text(payload.get("head_sha"))


def main():
    snapshot, outdir = sys.argv[1], sys.argv[2]
    try:
        with open(snapshot, "r", encoding="utf-8") as handle:
            pull = json.load(handle)
    except (OSError, ValueError):
        return 1
    if not isinstance(pull, dict):
        return 1

    head = pull.get("head") if isinstance(pull.get("head"), dict) else {}
    user = pull.get("user") if isinstance(pull.get("user"), dict) else {}
    body = text(pull.get("body"))

    fields = {
        "body": body,
        "head_sha": text(head.get("sha")).strip(),
        "head_ref": text(head.get("ref")).strip(),
        "author": text(user.get("login")).strip(),
        "attested": attested_head(body).strip(),
    }
    for name, value in fields.items():
        with open(os.path.join(outdir, name), "w", encoding="utf-8") as handle:
            handle.write(value)
    return 0


sys.exit(main())
PY

read_fact() {
  [ -f "$FACTS/$1" ] || return 1
  cat "$FACTS/$1"
}

emit_outputs() {
  local delim
  [ -n "${GITHUB_OUTPUT:-}" ] || return 0
  delim="fm-pr-body-$(python3 -c 'import secrets; print(secrets.token_hex(16))')"
  {
    printf 'head-sha=%s\n' "$(read_fact head_sha)"
    printf 'head-ref=%s\n' "$(read_fact head_ref)"
    printf 'author=%s\n' "$(read_fact author)"
    printf 'body<<%s\n' "$delim"
    read_fact body
    printf '\n%s\n' "$delim"
  } >> "$GITHUB_OUTPUT"
}

started=$(date +%s)
deadline=$((started + TIMEOUT))
have_facts=0
bound=0

while :; do
  if gh api "repos/$REPO/pulls/$PR" > "$WORK/snapshot.json" 2>"$WORK/snapshot.err"; then
    if python3 "$PARSER" "$WORK/snapshot.json" "$FACTS"; then
      have_facts=1
      head_sha=$(read_fact head_sha)
      attested=$(read_fact attested)
      if [ -n "$head_sha" ] && [ "$attested" = "$head_sha" ]; then
        bound=1
      fi
    fi
  fi

  [ "$bound" -eq 0 ] || break
  now=$(date +%s)
  [ "$now" -lt "$deadline" ] || break
  remaining=$((deadline - now))
  if [ "$INTERVAL" -lt "$remaining" ]; then
    sleep "$INTERVAL"
  else
    sleep "$remaining"
  fi
done

waited=$(($(date +%s) - started))

if [ "$have_facts" -eq 0 ]; then
  note "could not read ${REPO}#${PR} after ${waited}s; leaving the gate to judge the workflow event payload"
  exit 0
fi

emit_outputs

if [ "$bound" -eq 1 ]; then
  note "attestation binds to the live PR head $(read_fact head_sha) after ${waited}s"
  exit 0
fi

attested=$(read_fact attested)
[ -n "$attested" ] || attested='(none)'
note "attestation still names ${attested} after ${waited}s; the gate will judge the live body against head $(read_fact head_sha)"
exit 0
