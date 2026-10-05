#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_FILE="$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT_DIR"

if [[ ! -e "$ROOT_DIR/.git" ]]; then
  echo "[ERROR] Refusing to run: '$ROOT_DIR' is not a git repository root."
  exit 1
fi
if [[ ! -f "$SCRIPT_FILE" ]]; then
  echo "[ERROR] Cannot resolve this script path: $SCRIPT_FILE"
  exit 1
fi

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
for name in "${SUBMODULE_NAMES[@]:-}"; do
  [[ -z "$name" ]] && continue
  SUB_PATH["$name"]=$(git config -f .gitmodules --get "submodule.$name.path")
  SUB_URL["$name"]=$(git config -f .gitmodules --get "submodule.$name.url")
  SUBMODULE_PATHS+=("${SUB_PATH[$name]}")
done

if [[ ${#SUBMODULE_PATHS[@]} -eq 0 ]]; then
  echo "[INFO] No enabled submodules in .gitmodules (commented-out entries are ignored)."
  echo "[INFO] Uncomment a [submodule ...] block, then re-run this script to clone it."
fi

# Hard invariant: never delete this script, its directory, or repo metadata.
SCRIPT_DIR_NAME="$(basename "$SCRIPT_DIR")"
SCRIPT_REL="${SCRIPT_FILE#"$ROOT_DIR"/}"
SCRIPT_DIR_REL="${SCRIPT_DIR#"$ROOT_DIR"/}"
EXCLUDED_DIRS=("script" "scripts" "$SCRIPT_DIR_NAME" "docs" "deploy" ".sync-backup" ".git")

normalize_rel_path() {
  local dir="$1"
  dir="${dir//\\//}"
  dir="${dir%/}"
  dir="${dir#./}"
  if [[ "$dir" == "$ROOT_DIR" || "$dir" == "$ROOT_DIR/" ]]; then
    printf '.'
    return
  fi
  if [[ "$dir" == "$ROOT_DIR"/* ]]; then
    dir="${dir#"$ROOT_DIR"/}"
  fi
  printf '%s' "$dir"
}

# True for this script, its folder, repo root, and other protected paths.
is_excluded() {
  local dir
  dir="$(normalize_rel_path "$1")"
  local dir_lc="${dir,,}"
  local script_rel_lc="${SCRIPT_REL,,}"
  local script_dir_rel_lc="${SCRIPT_DIR_REL,,}"

  [[ -z "$dir" || "$dir" == "." || "$dir" == ".." ]] && return 0
  [[ "$dir_lc" == ".git" || "$dir_lc" == ".git/"* ]] && return 0
  [[ "$dir_lc" == "$script_rel_lc" || "$dir_lc" == "$script_dir_rel_lc" ]] && return 0
  [[ "$script_rel_lc" == "$dir_lc"/* ]] && return 0

  local ex
  for ex in "${EXCLUDED_DIRS[@]}"; do
    [[ "$dir_lc" == "${ex,,}" ]] && return 0
  done
  return 1
}

# Regular tracked files (100644/100755) are never "stale submodules".
# `git ls-files --error-unmatch -- scripts` matches scripts/sync.sh — that is NOT a gitlink.
has_regular_tracked_files() {
  local path="$1"
  git ls-files -s -- "$path" 2>/dev/null | awk '$1 != "160000" { found=1; exit } END { exit !found }'
}

is_gitlink() {
  local path="$1"
  local mode
  mode="$(git ls-files -s -- "$path" 2>/dev/null | awk 'NR==1 { print $1 }')"
  [[ "$mode" == "160000" ]]
}

# Last-line defense: never rm -rf this script, its dir, or regular tracked files.
safe_rm_rf() {
  local target abs
  for target in "$@"; do
    [[ -z "$target" || "$target" == "/" || "$target" == "." || "$target" == ".." ]] && continue
    if is_excluded "$target"; then
      echo "  [SKIP] Refusing rm -rf of protected path '$target'."
      continue
    fi
    if has_regular_tracked_files "$target"; then
      echo "  [SKIP] Refusing rm -rf of '$target' (contains regular tracked files, including possibly this script)."
      continue
    fi
    if [[ -e "$target" || -L "$target" ]]; then
      abs="$(cd "$(dirname -- "$target")" 2>/dev/null && pwd)/$(basename -- "$target")" || abs="$target"
      if [[ "$abs" == "$ROOT_DIR" || "$abs" == "$SCRIPT_DIR" || "$abs" == "$SCRIPT_FILE" ]]; then
        echo "  [SKIP] Refusing rm -rf of protected path '$target'."
        continue
      fi
      if [[ "$SCRIPT_FILE" == "$abs" || "$SCRIPT_FILE" == "$abs"/* ]]; then
        echo "  [SKIP] Refusing rm -rf of '$target' (contains this script)."
        continue
      fi
    fi
    rm -rf -- "$target"
  done
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
# Never `git rm` a regular directory — that would stage deletion of files like scripts/sync.sh.
unregister_stale_gitlink() {
  local dir="$1"
  if is_excluded "$dir"; then
    echo "  [SKIP] Refusing to remove protected directory '$dir'."
    return 1
  fi
  if has_regular_tracked_files "$dir"; then
    echo "  [SKIP] '$dir' has regular tracked files — not a stale submodule."
    return 1
  fi
  if ! is_gitlink "$dir" && [[ ! -e "$dir/.git" ]]; then
    echo "  [SKIP] '$dir' is not a submodule gitlink or checkout — leaving it alone."
    return 1
  fi
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
  git submodule deinit -f -- "$dir" 2>/dev/null || true
  if is_gitlink "$dir"; then
    git rm --cached -f -- "$dir" 2>/dev/null || true
  fi
  git config --remove-section "submodule.$dir" 2>/dev/null || true
  safe_rm_rf "$dir" "$ROOT_DIR/.git/modules/$dir"
}

# ── step 1: remove paths no longer listed in .gitmodules ──────────────────────
# Commented-out entries are ignored. Working trees are deleted (dirty ones are backed up first).

echo "==> Removing paths that are no longer in .gitmodules..."
stale_removed=false
declare -A SEEN_STALE=()

shopt -s nullglob
for dir_slash in */; do
  dir="${dir_slash%/}"
  is_excluded "$dir" && continue
  is_registered "$dir" && continue
  # Only real submodule leftovers: mode 160000 gitlink, or a checkout with .git.
  # Do NOT treat "any tracked file under this dir" as stale — that deleted scripts/sync.sh.
  if is_gitlink "$dir" || [[ -e "$dir/.git" ]]; then
    if unregister_stale_gitlink "$dir"; then
      SEEN_STALE["$dir"]=1
      stale_removed=true
    fi
  fi
done
shopt -u nullglob

# Index gitlinks whose folder was already deleted
while IFS= read -r path; do
  [[ -z "$path" ]] && continue
  is_excluded "$path" && continue
  is_registered "$path" && continue
  [[ -n "${SEEN_STALE[$path]:-}" ]] && continue
  if unregister_stale_gitlink "$path"; then
    stale_removed=true
  fi
done < <(git ls-files -s | awk '$1==160000 {print $4}')

if [[ "$stale_removed" == true ]]; then
  if [[ ! -f "$SCRIPT_FILE" ]]; then
    echo "[ERROR] This script disappeared during stale cleanup — restoring and aborting commit."
    git checkout HEAD -- "$SCRIPT_REL" "scripts/sync.sh" "script/sync.sh" 2>/dev/null || true
  elif git diff --cached --name-only --diff-filter=D | grep -qiE '(^|/)(script|scripts)/sync\.sh$|^script$|^scripts$'; then
    echo "[ERROR] Auto-commit would delete this script — unstaging that deletion."
    git reset HEAD -- "$SCRIPT_REL" scripts/sync.sh script/sync.sh script scripts 2>/dev/null || true
  else
    echo "==> Committing unregister of stale submodule gitlinks..."
    git commit -m "chore: unregister stale submodule gitlinks" || true
  fi
fi

# Rewrite Windows/WSL absolute gitdir pointers to relative paths so
# `git submodule` works from both Git for Windows and WSL.
rel_gitdir_for_submodule() {
  local path="$1"
  local name="$2"
  local prefix=""
  local rest="${path%/}"
  while [[ -n "$rest" ]]; do
    prefix="../$prefix"
    if [[ "$rest" == */* ]]; then
      rest="${rest#*/}"
    else
      rest=""
    fi
  done
  printf '%s.git/modules/%s' "$prefix" "$name"
}

normalize_submodule_gitdirs() {
  local name path gitfile current expected
  echo "==> Normalizing submodule gitdir pointers (relative, Windows/WSL-safe)..."
  for name in "${SUBMODULE_NAMES[@]:-}"; do
    [[ -z "$name" ]] && continue
    path="${SUB_PATH[$name]}"
    gitfile="$path/.git"
    [[ -f "$gitfile" ]] || continue
    expected="$(rel_gitdir_for_submodule "$path" "$name")"
    current="$(tr -d '\r' < "$gitfile" | awk 'BEGIN { IGNORECASE=1 } $1=="gitdir:" { print $2; exit }')"
    current="${current//\\//}"
    current="${current%$'\r'}"
    if [[ -z "$current" ]]; then
      echo "  [WARN] $gitfile has no gitdir: line — skipping"
      continue
    fi
    if [[ "$current" == "$expected" ]]; then
      echo "  [OK] $path -> $expected"
      continue
    fi
    echo "  -> $path/.git: $current -> $expected"
    printf 'gitdir: %s\n' "$expected" > "$gitfile"
  done
}

# ── step 2: sync URLs ──────────────────────────────────────────────────────────

normalize_submodule_gitdirs
echo "==> Syncing git submodule URLs from .gitmodules..."
if ! git submodule sync --recursive; then
  echo "[WARN] git submodule sync failed — continuing with clone/update."
fi

# Latest commit only — skip full history (sitebase is 200k+ objects).
CLONE_FLAGS=(--depth 1 --single-branch --no-tags)

# Clone a submodule listed in .gitmodules even if it was never `git submodule add`'d.
ensure_submodule() {
  local name="$1"
  local path="$2"
  local url="$3"

  if [[ -z "$path" || -z "$url" ]]; then
    echo "  [ERROR] Incomplete .gitmodules entry for '$name' — skipping."
    return 0
  fi
  if is_excluded "$path"; then
    echo "  [SKIP] Refusing to clone over protected path: $path"
    return 0
  fi

  git config "submodule.$name.url" "$url" || true
  git config "submodule.$name.active" true || true

  if [[ -e "$path/.git" ]]; then
    echo "  [OK] $name already present at $path"
    return 0
  fi

  if [[ -d "$path" ]] && [[ -n "$(ls -A "$path" 2>/dev/null)" ]]; then
    echo "  [WARN] '$path' exists but is not a git checkout — skipping clone to avoid overwrite."
    return 0
  fi

  echo "  -> Cloning $name (shallow): $url -> $path"
  git config "submodule.$name.shallow" true || true
  if git submodule add -f --depth 1 -- "$url" "$path"; then
    return 0
  fi

  echo "  [INFO] git submodule add failed (entry may already be in .gitmodules) — cloning directly..."
  safe_rm_rf "$path"
  if git clone "${CLONE_FLAGS[@]}" -- "$url" "$path"; then
    git add "$path" || true
    return 0
  fi
  echo "  [ERROR] Failed to clone $name from $url"
  return 0
}

# ── step 3: clone / re-register submodules listed in .gitmodules ──────────────

echo "==> Ensuring every enabled submodule is cloned..."
for name in "${SUBMODULE_NAMES[@]:-}"; do
  [[ -z "$name" ]] && continue
  path="${SUB_PATH[$name]}"
  url="${SUB_URL[$name]}"
  registered_url=$(git config -f .git/config --get "submodule.$name.url" 2>/dev/null || true)

  if [[ -n "$registered_url" && "$registered_url" != "$url" && -e "$path/.git" ]]; then
    if is_excluded "$path"; then
      echo "  [SKIP] Refusing to delete/re-register protected path: $path"
      continue
    fi
    if repo_is_mid_operation "$path"; then
      echo "  [ERROR] '$path' is mid-rebase/merge — skipping re-registration."
      continue
    fi
    if submodule_is_dirty "$path"; then
      echo "  [WARN] '$path' has uncommitted changes — backing up before re-registration."
      backup_submodule "$path"
    fi
    echo "  -> Re-registering submodule: $path -> $url"
    git submodule deinit -f -- "$path" 2>/dev/null || true
    if is_gitlink "$path"; then
      git rm --cached -f -- "$path" 2>/dev/null || true
    fi
    safe_rm_rf "$path" ".git/modules/$name"
  fi

  ensure_submodule "$name" "$path" "$url"
done

# ── step 4: init new submodules ───────────────────────────────────────────────

echo "==> Initializing new submodules (shallow, skip existing)..."
if ! git submodule update --init --recursive --depth 1 --no-fetch 2>/dev/null; then
  git submodule update --init --recursive --depth 1 || echo "[WARN] submodule update --init failed (network?)"
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
    if git -C "$path" fetch --depth 1 --no-tags origin; then
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
    default_branch=$(git -C "$path" rev-parse --abbrev-ref HEAD 2>/dev/null || true)
    [[ "$default_branch" == "HEAD" || -z "$default_branch" ]] && default_branch="main"
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
    if ! git -C "$path" pull --rebase --depth 1 origin "$current_branch" 2>/dev/null; then
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

if [[ ! -f "$SCRIPT_FILE" ]]; then
  echo "[ERROR] This script was removed during sync — restoring from HEAD."
  git checkout HEAD -- "$SCRIPT_REL" "scripts/sync.sh" "script/sync.sh" 2>/dev/null || true
fi

echo ""
echo "Done."