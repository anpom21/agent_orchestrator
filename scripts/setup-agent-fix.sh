#!/usr/bin/env bash
#
# setup-agent-fix.sh — install, check, commit and push a label-triggered Claude workflow.
#
# Expects agent-fix.yml in the same folder as this script. Run it from inside
# the target repo (or pass --repo-dir). It will:
#   1. Check prerequisites (git, gh, gh login)
#   2. Copy agent-fix.yml into the repo's .github/workflows/ and check it's valid YAML
#   3. Check the Claude GitHub App is installed (opens the install page if not)
#   4. Check the secrets it uses (offers to set missing ones, incl. Claude API key
#      or a Pro/Max subscription token via `claude setup-token`)
#   5. Create the trigger label if it doesn't exist
#   6. If it calls a reusable workflow in another repo, check that's reachable
#   7. Commit and push the workflow to the default branch
#   8. Optionally (--test) open a test issue, label it and watch the run
#
# Usage:
#   scripts/setup-agent-fix.sh [--repo-dir DIR] [--workflow PATH] [--label NAME] [--test] [--yes]
#
# Requires: git, gh (logged in with `gh auth login`). Optional: python3 + PyYAML, claude.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SOURCE_WORKFLOW="$SCRIPT_DIR/agent-fix.yml"
REPO_DIR="."
WORKFLOW=".github/workflows/agent-fix.yml"
LABEL=""
RUN_TEST=0
ASSUME_YES=0

# ---------- output helpers ----------
if [[ -t 1 ]]; then
  RED=$'\e[31m'; GREEN=$'\e[32m'; YELLOW=$'\e[33m'; BOLD=$'\e[1m'; RESET=$'\e[0m'
else
  RED=""; GREEN=""; YELLOW=""; BOLD=""; RESET=""
fi
step() { printf '\n%s==> %s%s\n' "$BOLD" "$*" "$RESET"; }
ok()   { printf '  %s✔%s %s\n' "$GREEN" "$RESET" "$*"; }
warn() { printf '  %s!%s %s\n' "$YELLOW" "$RESET" "$*"; WARNINGS=$((WARNINGS + 1)); }
fail() { printf '  %s✘%s %s\n' "$RED" "$RESET" "$*"; exit 1; }
WARNINGS=0

confirm() {
  [[ $ASSUME_YES -eq 1 ]] && return 0
  local reply
  read -r -p "  $1 [y/N] " reply
  [[ "$reply" =~ ^[Yy]$ ]]
}

usage() { sed -n '2,21p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

# ---------- args ----------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo-dir) REPO_DIR="$2"; shift 2 ;;
    --workflow) WORKFLOW="$2"; shift 2 ;;
    --label)    LABEL="$2"; shift 2 ;;
    --test)     RUN_TEST=1; shift ;;
    --yes|-y)   ASSUME_YES=1; shift ;;
    -h|--help)  usage 0 ;;
    *) echo "Unknown option: $1" >&2; usage 1 ;;
  esac
done

# ---------- 1. prerequisites ----------
step "Checking prerequisites"
command -v git >/dev/null || fail "git is not installed"
command -v gh  >/dev/null || fail "GitHub CLI (gh) is not installed: https://cli.github.com"
gh auth status >/dev/null 2>&1 || fail "gh is not logged in. Run: gh auth login"
ok "git and gh are available, gh is logged in"

cd "$REPO_DIR"
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || fail "$REPO_DIR is not a git repository"
cd "$(git rev-parse --show-toplevel)"

REPO=$(gh repo view --json nameWithOwner -q .nameWithOwner) \
  || fail "Couldn't find the GitHub repo for this directory (is 'origin' a GitHub remote?)"
DEFAULT_BRANCH=$(gh repo view --json defaultBranchRef -q .defaultBranchRef.name)
OWNER="${REPO%%/*}"
ok "Repo: $REPO (default branch: $DEFAULT_BRANCH)"

# ---------- 2. workflow file ----------
step "Installing workflow file"
[[ -f "$SOURCE_WORKFLOW" ]] || fail "Template not found: $SOURCE_WORKFLOW (put agent-fix.yml next to this script)"
WORKFLOW_ACTION="Add"
if [[ ! -f "$WORKFLOW" ]]; then
  mkdir -p "$(dirname "$WORKFLOW")"
  cp "$SOURCE_WORKFLOW" "$WORKFLOW"
  ok "Copied $SOURCE_WORKFLOW → $WORKFLOW"
elif cmp -s "$SOURCE_WORKFLOW" "$WORKFLOW"; then
  ok "$WORKFLOW is already identical to the template"
else
  warn "$WORKFLOW already exists and differs from the template:"
  diff -u "$WORKFLOW" "$SOURCE_WORKFLOW" | sed 's/^/      /' || true
  if confirm "Overwrite it with the template?"; then
    cp "$SOURCE_WORKFLOW" "$WORKFLOW"
    WORKFLOW_ACTION="Update"
    ok "Overwrote $WORKFLOW"
  else
    ok "Keeping the existing $WORKFLOW"
  fi
fi

if command -v python3 >/dev/null && python3 -c 'import yaml' 2>/dev/null; then
  if python3 -c 'import sys, yaml; yaml.safe_load(open(sys.argv[1]))' "$WORKFLOW" 2>/tmp/yaml_err.$$; then
    ok "YAML is valid"
  else
    cat /tmp/yaml_err.$$ >&2; rm -f /tmp/yaml_err.$$
    fail "YAML syntax error in $WORKFLOW"
  fi
  rm -f /tmp/yaml_err.$$
else
  warn "python3 + PyYAML not available; skipping YAML syntax check"
fi

grep -qE '^[[:space:]]*issues[[:space:]]*:' "$WORKFLOW" \
  || warn "Workflow doesn't seem to trigger on 'issues' events — labeling an issue may not start it"

# Work out the trigger label from the `if:` condition, unless given with --label
if [[ -z "$LABEL" ]]; then
  LABEL=$(grep -oE "label\.name *== *['\"][^'\"]+['\"]" "$WORKFLOW" | head -1 \
          | sed -E "s/.*== *['\"]([^'\"]+)['\"].*/\1/" || true)
fi
if [[ -n "$LABEL" ]]; then
  ok "Trigger label: '$LABEL'"
else
  warn "Couldn't find a 'label.name == ...' condition. Pass --label NAME to create the label."
fi

# ---------- 3. Claude GitHub App ----------
step "Checking the Claude GitHub App is installed on $REPO"
APP_INSTALL_URL="https://github.com/apps/claude/installations/select_target"

# Prints 'yes', 'no', or 'unknown' (gh token can't list app installations)
claude_app_status() {
  local ids id
  ids=$(gh api --paginate user/installations \
          -q '.installations[] | select(.app_slug == "claude") | .id' 2>/dev/null) || { echo unknown; return; }
  for id in $ids; do
    if gh api --paginate "user/installations/$id/repositories" -q '.repositories[].full_name' 2>/dev/null \
         | grep -qixF "$REPO"; then
      echo yes; return
    fi
  done
  echo no
}

open_url() {
  local opener
  for opener in xdg-open open wslview; do
    command -v "$opener" >/dev/null && { "$opener" "$1" >/dev/null 2>&1 & return 0; }
  done
  return 1
}

APP_STATUS=$(claude_app_status)
if [[ "$APP_STATUS" == "yes" ]]; then
  ok "Claude GitHub App has access to $REPO"
elif [[ $ASSUME_YES -eq 1 ]]; then
  # Installing an app needs a person to approve it in the browser
  warn "Claude GitHub App not confirmed on $REPO. Install it: $APP_INSTALL_URL"
else
  if [[ "$APP_STATUS" == "no" ]]; then
    echo "  The Claude GitHub App doesn't have access to $REPO yet."
  else
    echo "  Couldn't check app installations with your gh token."
  fi
  echo "  Installing a GitHub App needs your approval in the browser:"
  echo "    1. Pick the account/org that owns $REPO"
  echo "    2. Choose 'Only select repositories' and add ${REPO#*/} (or keep 'All repositories')"
  echo "    3. Click Install / Save"
  if confirm "Open $APP_INSTALL_URL now?"; then
    open_url "$APP_INSTALL_URL" || echo "  Couldn't open a browser — go to: $APP_INSTALL_URL"
    read -r -p "  Press Enter once you've installed it... " _
    APP_STATUS=$(claude_app_status)
    case "$APP_STATUS" in
      yes)     ok "Claude GitHub App now has access to $REPO" ;;
      no)      warn "Still no access to $REPO — check the repo is selected in the app's settings" ;;
      unknown) ok "Can't verify with your gh token; assuming you installed it" ;;
    esac
  else
    warn "Skipped. Install later: $APP_INSTALL_URL"
  fi
fi

# ---------- 4. secrets ----------
step "Checking repository secrets"
load_secrets() {
  local repo_s org_s
  repo_s=$(gh secret list --repo "$REPO" --json name -q '.[].name' 2>/dev/null || true)
  org_s=$(gh secret list --org "$OWNER" --json name -q '.[].name' 2>/dev/null || true)
  ALL_SECRETS=$(printf '%s\n%s\n' "$repo_s" "$org_s")
}
load_secrets

has_secret() { grep -qxF "$1" <<<"$ALL_SECRETS"; }

# Replace one secret name with another in the workflow file
rewrite_secret_ref() {
  sed -i.bak "s/secrets\.$1\([^A-Za-z0-9_]\)/secrets.$2\1/g" "$WORKFLOW" && rm -f "$WORKFLOW.bak"
}

# Switch the claude-code-action input from an API key to a subscription OAuth token
use_oauth_token_in_workflow() {
  sed -i.bak 's/anthropic_api_key: *\${{ *secrets\.ANTHROPIC_API_KEY *}}/claude_code_oauth_token: ${{ secrets.CLAUDE_CODE_OAUTH_TOKEN }}/' \
    "$WORKFLOW" && rm -f "$WORKFLOW.bak"
}

offer_set_secret() {
  local name="$1"
  if confirm "Set $name now? (you'll paste the value; it isn't echoed)"; then
    gh secret set "$name" --repo "$REPO" && ok "$name set"
  else
    warn "$name is missing — the workflow will fail without it"
  fi
}

# Claude credentials: an API key (pay per use) or a Pro/Max subscription token
setup_claude_credentials() {
  if has_secret CLAUDE_CODE_OAUTH_TOKEN; then
    if confirm "Found CLAUDE_CODE_OAUTH_TOKEN. Use it (your Claude subscription) instead of ANTHROPIC_API_KEY?"; then
      use_oauth_token_in_workflow; ok "Workflow now uses CLAUDE_CODE_OAUTH_TOKEN"; return
    fi
  fi
  if [[ $ASSUME_YES -eq 1 ]]; then
    warn "No Claude credentials secret. Set one: gh secret set ANTHROPIC_API_KEY --repo $REPO"; return
  fi
  echo "  No Claude credentials found. How should the workflow authenticate?"
  echo "    1) Anthropic API key (pay per use, from console.anthropic.com)"
  echo "    2) Claude Pro/Max subscription token (generated with 'claude setup-token')"
  echo "    3) Skip for now"
  local choice; read -r -p "  Choice [1-3]: " choice
  case "$choice" in
    1)
      gh secret set ANTHROPIC_API_KEY --repo "$REPO" && ok "ANTHROPIC_API_KEY set" ;;
    2)
      if command -v claude >/dev/null; then
        echo "  Running 'claude setup-token' — log in, then copy the token it prints."
        claude setup-token || true
      else
        echo "  Claude Code isn't installed here. Run 'claude setup-token' on a machine that has it,"
        echo "  or install it: https://docs.claude.com/en/docs/claude-code/setup"
      fi
      echo "  Paste the token below."
      if gh secret set CLAUDE_CODE_OAUTH_TOKEN --repo "$REPO"; then
        ok "CLAUDE_CODE_OAUTH_TOKEN set"
        use_oauth_token_in_workflow; ok "Workflow now uses CLAUDE_CODE_OAUTH_TOKEN"
      fi ;;
    *)
      warn "No Claude credentials — the workflow will fail until you add one" ;;
  esac
}

NEEDED_SECRETS=$(grep -oE 'secrets\.[A-Za-z0-9_]+' "$WORKFLOW" | sed 's/secrets\.//' \
                 | grep -vx 'GITHUB_TOKEN' | sort -u || true)
# With `secrets: inherit` the names aren't in the file, so always check Claude credentials
grep -q 'secrets: *inherit' "$WORKFLOW" && NEEDED_SECRETS=$(printf '%s\nANTHROPIC_API_KEY\n' "$NEEDED_SECRETS")

# Loop on fd 3 so prompts inside it (confirm, gh secret set) still read from the terminal
while read -r s <&3; do
  [[ -z "$s" ]] && continue
  if has_secret "$s"; then ok "$s exists"; continue; fi
  case "$s" in
    ANTHROPIC_API_KEY|CLAUDE_CODE_OAUTH_TOKEN)
      if has_secret ANTHROPIC_API_KEY || has_secret CLAUDE_CODE_OAUTH_TOKEN; then
        # The other kind of credential exists; point the workflow at it
        if [[ "$s" == ANTHROPIC_API_KEY ]]; then use_oauth_token_in_workflow; other=CLAUDE_CODE_OAUTH_TOKEN
        else rewrite_secret_ref CLAUDE_CODE_OAUTH_TOKEN ANTHROPIC_API_KEY
             sed -i.bak 's/claude_code_oauth_token:/anthropic_api_key:/' "$WORKFLOW" && rm -f "$WORKFLOW.bak"
             other=ANTHROPIC_API_KEY; fi
        ok "Using existing $other for Claude"
      else
        setup_claude_credentials
      fi ;;
    FIREBASE_SERVICE_ACCOUNT)
      # `firebase init hosting:github` names it FIREBASE_SERVICE_ACCOUNT_<PROJECT>
      alt=$(grep -m1 '^FIREBASE_SERVICE_ACCOUNT_' <<<"$ALL_SECRETS" || true)
      if [[ -n "$alt" ]]; then
        rewrite_secret_ref "$s" "$alt"; ok "Using existing $alt for Firebase"
      else
        warn "$s not found. Easiest: run 'firebase init hosting:github' in this repo, then rerun this script."
        offer_set_secret "$s"
      fi ;;
    *)
      warn "$s not found"; offer_set_secret "$s" ;;
  esac
done 3<<<"$NEEDED_SECRETS"

# ---------- 5. label ----------
if [[ -n "$LABEL" ]]; then
  step "Checking labels"
  EXISTING_LABELS=$(gh label list --repo "$REPO" --limit 500 --json name -q '.[].name')
  ensure_label() {  # name color description
    if grep -qxF "$1" <<<"$EXISTING_LABELS"; then
      ok "Label '$1' exists"
    else
      gh label create "$1" --repo "$REPO" --color "$2" --description "$3" >/dev/null
      ok "Created label '$1'"
    fi
  }
  ensure_label "$LABEL" 7057ff "Ask Claude to attempt a fix"
  # Claude adds this when an issue is too complex to fix automatically
  if grep -q 'needs-human' "$WORKFLOW"; then
    ensure_label needs-human d93f0b "Claude decided this needs a human"
  fi
fi

# ---------- 6. reusable workflow ----------
CALLED=$(grep -oE 'uses: *[^/ ]+/[^/ ]+/\.github/workflows/[^@ ]+@[^ ]+' "$WORKFLOW" \
         | sed -E 's/uses: *//' || true)
if [[ -n "$CALLED" ]]; then
  step "Checking reusable workflow(s)"
  while read -r ref; do
    [[ -z "$ref" ]] && continue
    target_repo=$(cut -d/ -f1-2 <<<"$ref")
    path_and_ref=$(cut -d/ -f3- <<<"$ref")
    path="${path_and_ref%@*}"; gitref="${path_and_ref##*@}"
    if gh api "repos/$target_repo/contents/$path?ref=$gitref" >/dev/null 2>&1; then
      ok "$target_repo/$path exists on '$gitref'"
    else
      warn "$target_repo/$path not found on '$gitref' — runs will fail until it's pushed there"
    fi
    if [[ "$target_repo" != "$REPO" ]]; then
      vis=$(gh repo view "$target_repo" --json visibility -q .visibility 2>/dev/null || echo UNKNOWN)
      if [[ "$vis" != "PUBLIC" ]]; then
        access=$(gh api "repos/$target_repo/actions/permissions/access" -q .access_level 2>/dev/null || echo unknown)
        if [[ "$access" == "none" ]]; then
          warn "$target_repo is private and doesn't share its workflows."
          echo "      Fix: $target_repo → Settings → Actions → General → Access"
        else
          ok "$target_repo workflow access: $access"
        fi
      fi
    fi
  done <<<"$CALLED"
fi

# ---------- 7. commit & push ----------
step "Committing and pushing"
CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
if [[ "$CURRENT_BRANCH" != "$DEFAULT_BRANCH" ]]; then
  warn "You're on '$CURRENT_BRANCH', not '$DEFAULT_BRANCH'."
  echo "      Issue-triggered workflows only run from the default branch, so it won't fire until merged."
  confirm "Push to '$CURRENT_BRANCH' anyway?" || fail "Aborted. Switch with: git checkout $DEFAULT_BRANCH"
fi

git add "$WORKFLOW"
if git diff --cached --quiet -- "$WORKFLOW"; then
  ok "No changes to commit in $WORKFLOW"
else
  git commit -m "$WORKFLOW_ACTION Claude agent fix workflow" -- "$WORKFLOW" >/dev/null
  ok "Committed $WORKFLOW"
fi

if [[ -n "$(git log "@{u}.." --oneline 2>/dev/null || echo unpushed)" ]]; then
  git push -u origin "$CURRENT_BRANCH"
  ok "Pushed to origin/$CURRENT_BRANCH"
else
  ok "Already up to date with remote"
fi

# ---------- 8. optional test ----------
if [[ $RUN_TEST -eq 1 ]]; then
  [[ -z "$LABEL" ]] && fail "--test needs a label (couldn't detect one; pass --label)"
  step "Opening a test issue"
  START_TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  ISSUE_URL=$(gh issue create --repo "$REPO" \
    --title "Test: Claude agent fix workflow" \
    --body "Test issue created by setup-agent-fix.sh. Please add a short comment saying the workflow works, and do not change any code." )
  ISSUE_NUM="${ISSUE_URL##*/}"
  ok "Created $ISSUE_URL"
  sleep 2   # let the issue settle before labeling so 'labeled' fires as its own event
  gh issue edit "$ISSUE_NUM" --repo "$REPO" --add-label "$LABEL" >/dev/null
  ok "Added label '$LABEL'"

  echo "  Waiting for the workflow run to start..."
  RUN_ID=""
  for _ in $(seq 1 15); do
    sleep 4
    RUN_ID=$(gh run list --repo "$REPO" --workflow "$(basename "$WORKFLOW")" --event issues \
               --limit 1 --json databaseId,createdAt \
               -q "[.[] | select(.createdAt >= \"$START_TS\")][0].databaseId // empty" 2>/dev/null || true)
    [[ -n "$RUN_ID" ]] && break
  done
  if [[ -n "$RUN_ID" ]]; then
    ok "Run started: https://github.com/$REPO/actions/runs/$RUN_ID"
    gh run watch "$RUN_ID" --repo "$REPO" --exit-status \
      && ok "Run succeeded" || warn "Run failed — see: gh run view $RUN_ID --repo $REPO --log-failed"
  else
    warn "No run appeared after ~60s. Check https://github.com/$REPO/actions"
  fi
fi

# ---------- summary ----------
step "Done"
if [[ $WARNINGS -eq 0 ]]; then
  ok "Everything looks good."
else
  printf '  %s%d warning(s)%s above — review them before relying on the workflow.\n' "$YELLOW" "$WARNINGS" "$RESET"
fi
[[ $RUN_TEST -eq 0 && -n "$LABEL" ]] && echo "  To test: open an issue in $REPO and add the '$LABEL' label (or rerun with --test)."
exit 0
