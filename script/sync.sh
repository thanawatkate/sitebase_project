
#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

# ── lock: prevent concurrent runs ─────────────────────────────────────────────
LOCKFILE="$ROOT_DIR/.sync-submodules.lock"
exec 9>"$LOCKFILE"
if ! flock -n 9; then
  echo "[ERROR] Another instance of sync-submodules is already running. Exiting."
  exit 1
fi
trap 'rm -f "$LOCKFILE"' EXIT

# ── helpers ────────────────────────────────────────────────────────────────────

# Returns 0 (true) if the given path has ANY uncommitted/untracked changes
submodule_is_dirty() {
  local path="$1"
  [[ ! -d "$path/.git" && ! -f "$path/.git" ]] && return 1
  pushd "$path" > /dev/null
  local dirty=1
  if ! git diff --quiet          2>/dev/null || \
     ! git diff --cached --quiet 2>/dev/null || \
     [[ -n "$(git ls-files --others --exclude-standard)" ]]; then
    dirty=0
  fi
  popd > /dev/null
  return $dirty
}

# Returns 0 (true) if the repo is currently mid-rebase/merge/cherry-pick
repo_is_mid_operation() {
  local path="$1"
  local git_dir
  git_dir=$(git -C "$path" rev-parse --git-dir 2>/dev/null) || return 1
  [[ -d "$git_dir/rebase-merge" || -d "$git_dir/rebase-apply" || \
     -f "$git_dir/MERGE_HEAD"   || -f "$git_dir/CHERRY_PICK_HEAD" ]]
}

# Backs up a dirty submodule to .sync-backup/<dir>-<timestamp>/
# Uses rsync if available (faster, supports large repos), falls back to cp
backup_submodule() {
  local path="$1"
  local timestamp
  timestamp=$(date +%Y%m%d_%H%M%S)
  local backup_dir="$ROOT_DIR/.sync-backup/${path}-${timestamp}"
  echo "  [BACKUP] Saving '$path' -> '$backup_dir' ..."
  mkdir -p "$backup_dir"
  if command -v rsync &>/dev/null; then
    rsync -a --exclude='.git/' "$path/" "$backup_dir/"
  else
    cp -a "$path/." "$backup_dir/"
  fi
  echo "  [BACKUP] Restore: cp -a '${backup_dir}/.' '${ROOT_DIR}/${path}/'"
}

# Resolve default branch from local remote-tracking ref (no network needed)
get_default_branch() {
  git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|refs/remotes/origin/||' || echo "main"
}

# ── read .gitmodules ───────────────────────────────────────────────────────────

if [[ ! -f .gitmodules ]]; then
  echo "[INFO] No .gitmodules found. Nothing to do."
  exit 0
fi

mapfile -t SUBMODULE_NAMES < <(git config -f .gitmodules --get-regexp 'submodule\..*\.path' | sed -E 's/^submodule\.(.+)\.path .*/\1/')

declare -A SUB_PATH SUB_URL
SUBMODULE_PATHS=()
for name in "${SUBMODULE_NAMES[@]}"; do
  SUB_PATH["$name"]=$(git config -f .gitmodules --get "submodule.$name.path")
  SUB_URL["$name"]=$(git config -f .gitmodules --get "submodule.$name.url")
  SUBMODULE_PATHS+=("${SUB_PATH[$name]}")
done

# Build exclusion list: always-safe dirs + the script dir itself
SCRIPT_DIR="$(basename "$(dirname "${BASH_SOURCE[0]}")")"
EXCLUDED_DIRS=("$SCRIPT_DIR" "docs" "deploy" ".sync-backup")

is_excluded() {
  local dir="$1"
  for ex in "${EXCLUDED_DIRS[@]}"; do
    [[ "$dir" == "$ex" ]] && return 0
  done
  return 1
}

is_registered() {
  local dir="$1"
  local sub
  for sub in "${SUBMODULE_PATHS[@]:-}"; do
    [[ "$sub" == "$dir" ]] && return 0
  done
  return 1
}

# Unregister a gitlink that is no longer in .gitmodules, then delete the folder.
unregister_stale_gitlink() {
  local dir="$1"
  if [[ -e "$dir/.git" ]] && repo_is_mid_operation "$dir"; then
    echo "  [ERROR] '$dir' is mid-rebase/merge — skipping unregister."
    return 1
  fi
  if [[ -e "$dir/.git" ]] && submodule_is_dirty "$dir"; then
    echo "  [WARN] '$dir' has uncommitted changes — backing up before removal."
    backup_submodule "$dir"
  fi
  echo "  -> Removing '$dir' (no longer in .gitmodules)"
  git add .gitmodules 2>/dev/null || true
  git submodule deinit -f "$dir" 2>/dev/null || true
  git rm --cached -f "$dir" 2>/dev/null || true
  git config --remove-section "submodule.$dir" 2>/dev/null || true
  rm -rf "$dir" "$ROOT_DIR/.git/modules/$dir"
}

# ── step 1: remove paths no longer listed in .gitmodules ──────────────────────
# Commented-out entries are ignored. Working trees are deleted (dirty ones are backed up first).

echo "==> Removing paths that are no longer in .gitmodules..."
stale_removed=false
declare -A SEEN_STALE=()

for dir_slash in */; do
  dir="${dir_slash%/}"
  is_excluded "$dir" && continue
  is_gitlink=0
  if git rev-parse --verify HEAD &>/dev/null; then
    is_gitlink=$(git ls-tree HEAD "$dir" 2>/dev/null | awk '{print $1}' | grep -c '^160000$' || true)
  fi
  in_index=0
  git ls-files --error-unmatch -- "$dir" &>/dev/null && in_index=1 || true
  if is_registered "$dir"; then
    continue
  fi
  if [[ "$is_gitlink" -gt 0 ]] || [[ "$in_index" -eq 1 ]] || [[ -e "$dir/.git" ]]; then
    unregister_stale_gitlink "$dir"
    SEEN_STALE["$dir"]=1
    stale_removed=true
  fi
done

# Index gitlinks whose folder was already deleted
while IFS= read -r path; do
  [[ -z "$path" ]] && continue
  is_registered "$path" && continue
  [[ -n "${SEEN_STALE[$path]:-}" ]] && continue
  unregister_stale_gitlink "$path"
  stale_removed=true
done < <(git ls-files -s | awk '$1==160000 {print $4}')

if [[ "$stale_removed" == true ]]; then
  echo "==> Committing unregister of stale submodule gitlinks..."
  git commit -m "chore: unregister stale submodule gitlinks" || true
fi

# ── step 2: sync URLs ──────────────────────────────────────────────────────────

echo "==> Syncing git submodule URLs from .gitmodules..."
git submodule sync --recursive

# ── step 3: re-register renamed/url-changed submodules ────────────────────────

echo "==> Detecting new/renamed submodules and re-registering them..."
for name in "${SUBMODULE_NAMES[@]}"; do
  path="${SUB_PATH[$name]}"
  url="${SUB_URL[$name]}"
  registered_url=$(git config -f .git/config --get "submodule.$name.url" 2>/dev/null || true)
  if [[ -z "$registered_url" || "$registered_url" != "$url" ]]; then
    # Guard: abort if mid-operation
    if [[ -d "$path" ]] && repo_is_mid_operation "$path"; then
      echo "  [ERROR] '$path' is mid-rebase/merge — skipping re-registration."
      continue
    fi
    # Guard: backup if dirty
    if [[ -d "$path" ]] && submodule_is_dirty "$path"; then
      echo "  [WARN] '$path' has uncommitted changes — backing up before re-registration."
      backup_submodule "$path"
    fi
    echo "  -> Re-registering submodule: $path -> $url"
    git submodule deinit -f "$path" 2>/dev/null || true
    git rm --cached "$path" 2>/dev/null || true
    rm -rf "$path" ".git/modules/$name"
    git submodule add -f "$url" "$path"
  fi
done

# ── step 4: init new submodules ───────────────────────────────────────────────

echo "==> Initializing new submodules (skip existing)..."
if ! git submodule update --init --recursive --no-fetch 2>/dev/null; then
  git submodule update --init --recursive || echo "[WARN] submodule update --init failed (network?)"
fi

# ── step 5: pull latest (preserving local changes) ────────────────────────────

echo "==> Pulling latest on each submodule's default branch (preserving local changes)..."
# Loop paths from .gitmodules only — git submodule foreach also walks leftover index gitlinks.

restore_stash() {
  local path="$1"
  local name="$2"
  if [[ "${3:-}" == true ]]; then
    echo "  -> $name: restoring local changes..."
    git -C "$path" stash pop || echo "  [WARN] $name: stash pop failed — run: git stash pop in $path"
  fi
}

fetch_origin() {
  local path="$1"
  local tries=3
  local i
  for i in $(seq 1 "$tries"); do
    if git -C "$path" fetch origin; then
      return 0
    fi
    echo "  [WARN] $path: fetch failed ($i/$tries) — retrying..."
    sleep "$i"
  done
  return 1
}

pull_registered_submodule() {
  local path="$1"
  local name="$path"
  if [[ ! -e "$path/.git" ]]; then
    echo "  [SKIP] $name: working tree missing"
    return 0
  fi
  if repo_is_mid_operation "$path"; then
    echo "  [SKIP] $name: mid-rebase/merge — skipping pull to avoid data loss."
    return 0
  fi

  local default_branch
  default_branch=$(git -C "$path" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|refs/remotes/origin/||')
  if [[ -z "$default_branch" ]]; then
    default_branch=$(git -C "$path" remote show origin 2>/dev/null | awk '/HEAD branch/ {print $NF}')
    [[ -z "$default_branch" ]] && default_branch="main"
  fi

  local stashed=false is_tracked_dirty=false has_untracked
  if ! git -C "$path" diff --quiet 2>/dev/null || ! git -C "$path" diff --cached --quiet 2>/dev/null; then
    is_tracked_dirty=true
  fi
  has_untracked=$(git -C "$path" ls-files --others --exclude-standard | head -1)

  if [[ "$is_tracked_dirty" == true || -n "$has_untracked" ]]; then
    echo "  -> $name: stashing local changes (including untracked files)..."
    if git -C "$path" stash push --include-untracked -m "sync-submodules auto-stash"; then
      stashed=true
    else
      echo "  [WARN] $name: stash failed — skipping pull to preserve changes."
      return 0
    fi
  fi

  if ! fetch_origin "$path"; then
    echo "  [ERROR] $name: cannot reach origin (DNS/network/SSH) — skipping"
    restore_stash "$path" "$name" "$stashed"
    return 0
  fi

  local current_branch
  current_branch=$(git -C "$path" symbolic-ref --short HEAD 2>/dev/null || echo "DETACHED")
  if [[ "$current_branch" == "DETACHED" ]]; then
    git -C "$path" merge --ff-only "origin/$default_branch" 2>/dev/null || \
      echo "  [WARN] $name: cannot fast-forward detached HEAD — manual merge required."
  else
    if ! git -C "$path" pull --rebase origin "$current_branch" 2>/dev/null; then
      echo "  [ERROR] $name: pull --rebase failed. Aborting rebase and restoring stash."
      git -C "$path" rebase --abort 2>/dev/null || true
      restore_stash "$path" "$name" "$stashed"
      return 0
    fi
  fi

  restore_stash "$path" "$name" "$stashed"
}

for path in "${SUBMODULE_PATHS[@]+"${SUBMODULE_PATHS[@]}"}"; do
  pull_registered_submodule "$path"
done

# ── summary ───────────────────────────────────────────────────────────────────

echo ""
echo "==> Submodule status:"
git submodule status --recursive

echo ""
echo "Done."
