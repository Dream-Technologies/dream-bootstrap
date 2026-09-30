#!/bin/bash
# Minimal MacBook onboarding. The private repository's setup.sh owns the dev environment.
set -euo pipefail

usage() {
  cat <<'HELP'
Usage: /bin/bash bootstrap.sh [repo-name ...]
Clones dream-core by default. Every repo belongs to Dream-Technologies.
Run in Terminal as your normal macOS user; installation may ask for your password.

Download this public script, then run it:
  curl --fail --location --output bootstrap.sh https://raw.githubusercontent.com/Dream-Technologies/dream-bootstrap/main/bootstrap.sh
  /bin/bash bootstrap.sh

Optional repositories:
  /bin/bash bootstrap.sh dream-core another-repo-name

Installs Apple Command Line Tools, Homebrew, and GitHub CLI; signs in with your
personal GitHub account; clones into ~/dream. Run each repository's setup.sh later.
HELP
}

fail() { printf '\nError: %s\n' "$*" >&2; exit 1; }
pause() {
  local reply
  printf 'Press Return to continue, or type q to cancel: ' >&3
  IFS= read -r reply <&3 || fail 'Input ended; rerun in Terminal when ready.'
  case "$reply" in '' ) ;; * ) fail 'Cancelled. You can rerun this script later.' ;; esac
}
step() { printf '\nStep %s of 6: %s\n' "$1" "$2"; }

if [ "$#" -eq 1 ] && { [ "$1" = --help ] || [ "$1" = -h ]; }; then
  usage; exit 0
fi
repos=("$@")
[ "${#repos[@]}" -gt 0 ] || repos=(dream-core)
for repo in "${repos[@]}"; do
  [[ "$repo" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]] ||
    fail "Invalid repo name: '$repo'. Use a name only, such as dream-core."
done
[ "$(uname -s)" = Darwin ] || fail 'This script requires macOS.'
[ "$(id -u)" -ne 0 ] || fail 'Run as your normal macOS user, without sudo.'
[ -n "${HOME:-}" ] && [ -d "$HOME" ] || fail 'Your home directory is unavailable.'
if ! { exec 3<>/dev/tty; } 2>/dev/null; then
  fail 'Open Terminal, download this script to a file, and run /bin/bash bootstrap.sh.'
fi

# gh prioritizes these over saved browser credentials. Never reuse inherited tokens.
if [ -n "${GH_TOKEN:-}" ] || [ -n "${GITHUB_TOKEN:-}" ]; then
  printf 'Ignoring inherited GitHub tokens; this run uses your personal browser sign-in.\n'
fi
unset GH_TOKEN GITHUB_TOKEN
installer=
trap '[ -z "$installer" ] || rm -f "$installer"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

step 1 'Apple Command Line Tools (includes Git)'
printf 'If prompted, click Install in the macOS dialog and wait until it finishes.\n'
pause
if ! xcode-select -p >/dev/null 2>&1; then
  xcode-select --install || fail 'Could not open the installer. Open System Settings > General > Software Update, install Command Line Tools, then rerun.'
  printf 'Finish the Command Line Tools installation before continuing.\n'
  pause
  xcode-select -p >/dev/null 2>&1 || fail 'Command Line Tools are still unavailable. Finish installation, then rerun.'
fi
git --version >/dev/null || fail 'Git is unavailable. Finish Command Line Tools installation, then rerun.'

step 2 'Homebrew'
printf 'Homebrew installs GitHub CLI. Its installer may ask for your Mac login password.\n'
pause
case "$(uname -m)" in
  arm64) brew_path=/opt/homebrew/bin/brew ;;
  x86_64) brew_path=/usr/local/bin/brew ;;
  *) fail 'This Mac architecture is unsupported.' ;;
esac
if command -v brew >/dev/null 2>&1; then
  brew_path=$(command -v brew)
elif [ ! -x "$brew_path" ]; then
  installer=$(mktemp /tmp/dream-bootstrap.XXXXXX) || fail 'Could not create a temporary installer file.'
  curl --fail --location --silent --show-error --proto '=https' \
    --output "$installer" https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh ||
    fail 'Homebrew download failed. Check your internet connection, then rerun.'
  /bin/bash "$installer" <&3 || fail 'Homebrew installation failed. Resolve the installer message above, then rerun.'
fi
brew_environment=$("$brew_path" shellenv) || fail 'Homebrew is unavailable after installation.'
eval "$brew_environment"
profile_dir=${ZDOTDIR:-$HOME}
mkdir -p "$profile_dir" || fail 'Could not create your zsh profile directory.'
profile="$profile_dir/.zprofile"
printf -v profile_line 'eval "$(%q shellenv)"' "$brew_path"
if ! [ -f "$profile" ] || ! grep -Fqx "$profile_line" "$profile"; then
  printf '\n%s\n' "$profile_line" >> "$profile" || fail 'Could not update your zsh profile.'
fi

step 3 'GitHub CLI'
printf 'Install GitHub CLI (gh) for browser sign-in and private repository access.\n'
pause
if ! command -v gh >/dev/null 2>&1; then
  "$brew_path" install gh || fail 'GitHub CLI installation failed. Resolve the Homebrew message above, then rerun.'
fi
gh --version >/dev/null || fail 'GitHub CLI is unavailable.'

step 4 'Your personal GitHub account'
printf 'Use your own GitHub account in the browser. Create one at https://github.com/signup if needed.\n'
printf 'Accept your Dream-Technologies invitation at https://github.com/notifications.\n'
printf 'GitHub CLI will display a code; copy it and follow its browser sign-in prompts.\n'
pause
if ! gh auth status --hostname github.com >/dev/null 2>&1; then
  gh auth login --hostname github.com --git-protocol https --web <&3 ||
    fail 'GitHub sign-in failed. Check your connection and finish browser sign-in, then rerun.'
fi
login=$(gh api user --hostname github.com --jq .login) || fail 'Could not identify the signed-in GitHub account.'
printf 'Signed in as %s. Type yes only if this is YOUR personal GitHub account: ' "$login" >&3
IFS= read -r confirmation <&3 || fail 'Account confirmation ended.'
[ "$confirmation" = yes ] ||
  fail 'Account not confirmed. Run gh auth logout --hostname github.com, then rerun and sign in with your own account.'
gh auth setup-git --hostname github.com || fail 'Could not configure GitHub credentials for HTTPS Git.'

valid_clone() {
  local destination=$1 repo=$2 origin prefix
  [ -d "$destination" ] && [ -e "$destination/.git" ] || return 1
  prefix=$(git -C "$destination" rev-parse --show-prefix 2>/dev/null) || return 1
  [ -z "$prefix" ] || return 1
  origin=$(git -C "$destination" remote get-url origin 2>/dev/null) || return 1
  case "$origin" in
    "https://github.com/Dream-Technologies/$repo"|"https://github.com/Dream-Technologies/$repo.git"|\
    "git@github.com:Dream-Technologies/$repo"|"git@github.com:Dream-Technologies/$repo.git") return 0 ;;
    *) return 1 ;;
  esac
}

step 5 'Repository access and clones'
printf 'Repositories go in ~/dream. Existing matching clones keep all their files and branches.\n'
pause
# Check all destinations and access before creating any clone.
for repo in "${repos[@]}"; do
  destination="$HOME/dream/$repo"
  if [ -e "$destination" ] || [ -L "$destination" ]; then
    valid_clone "$destination" "$repo" ||
      fail "$destination already exists and is not the matching repository. Move it to a safe location yourself, then rerun."
  fi
  gh repo view "Dream-Technologies/$repo" --json nameWithOwner >/dev/null 2>&1 ||
    fail "No access to Dream-Technologies/$repo. Accept your GitHub organization invitation and ask your onboarding contact for repository access, then rerun."
done
mkdir -p "$HOME/dream" || fail 'Could not create ~/dream.'
for repo in "${repos[@]}"; do
  destination="$HOME/dream/$repo"
  if [ -e "$destination" ]; then
    printf 'Keeping existing clone: %s\n' "$destination"
  else
    git clone -- "https://github.com/Dream-Technologies/$repo.git" "$destination" ||
      fail "Clone failed for $repo. Check access and your connection; inspect $destination before rerunning."
  fi
done

step 6 'Verify and finish'
printf 'Verify the clones, then show the command for the next onboarding stage.\n'
pause
for repo in "${repos[@]}"; do
  destination="$HOME/dream/$repo"
  valid_clone "$destination" "$repo" || fail "Could not verify $destination."
  if [ "$repo" = dream-core ] && [ ! -f "$destination/setup.sh" ]; then
    fail 'dream-core/setup.sh is missing. Ask your onboarding contact to check the repository.'
  fi
  printf 'Ready: %s\n' "$destination"
  if [ -f "$destination/setup.sh" ]; then
    printf 'Open a new Terminal window (Command+N) to load Homebrew, then run:\n  cd %q && ./setup.sh\n' "$destination"
  fi
done
printf '\nBootstrap complete. Repository setup remains your next step.\n'
