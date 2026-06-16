# txn.sh — all-or-nothing filesystem transaction (source this; bash only).
#
# Usage:
#   . txn.sh
#   txn_begin
#   txn_track  PATH        # snapshot if present, mark for delete if absent (files we write)
#   txn_guard  PATH        # snapshot an existing file so it can be restored
#   txn_mkdir  DIR         # mkdir -p, remembering created levels
#   txn_on_commit 'CMD'    # destructive cleanup deferred until success only
#   ... mutate freely ...
#   txn_commit
#
# On ANY command failure (set -e), Ctrl-C, or kill, _txn_rollback restores every
# snapshotted file to its exact prior bytes/owner/mode/mtime (cp -a), deletes every
# file/dir the run created, and exits 1 — leaving the system as it was found.
# Nothing destructive happens until txn_commit, and txn_commit only runs once all
# mutations (including initramfs/bootloader regeneration) have succeeded.

_TXN_DIR=""
_TXN_N=0
_TXN_RESTORE=()    # "stash|orig"
_TXN_RMFILE=()     # files created this run -> delete on rollback
_TXN_RMDIR=()      # dirs created this run (parent-first) -> rmdir on rollback
_TXN_ONCOMMIT=()   # commands eval'd only on successful commit

txn_begin() {
  _TXN_DIR="$(mktemp -d "${TMPDIR:-/tmp}/edidtxn.XXXXXX")"
  trap '_txn_rollback' ERR INT TERM
}

txn_guard() {
  local p="$1" stash
  if [ -e "$p" ] || [ -L "$p" ]; then
    stash="$_TXN_DIR/stash.$_TXN_N"
    _TXN_N=$((_TXN_N + 1))
    cp -a "$p" "$stash"
    _TXN_RESTORE+=("$stash|$p")
  fi
}

txn_will_create() {
  local p="$1"
  if [ ! -e "$p" ] && [ ! -L "$p" ]; then
    _TXN_RMFILE+=("$p")
  fi
}

# guard-if-present AND remove-if-created: for any file we are about to write
txn_track() { txn_guard "$1"; txn_will_create "$1"; }

txn_mkdir() {
  local d="$1" cur stack=()
  if [ -d "$d" ]; then return 0; fi
  cur="$d"
  while [ ! -d "$cur" ]; do
    stack=("$cur" ${stack[@]+"${stack[@]}"})
    cur="$(dirname "$cur")"
  done
  mkdir -p "$d"
  _TXN_RMDIR+=(${stack[@]+"${stack[@]}"})
}

txn_on_commit() { _TXN_ONCOMMIT+=("$1"); }

_txn_rollback() {
  trap - ERR INT TERM
  set +e
  echo "!! FAILURE — rolling back to the original state..." >&2
  local entry stash orig f i
  for entry in ${_TXN_RESTORE[@]+"${_TXN_RESTORE[@]}"}; do
    stash="${entry%%|*}"; orig="${entry#*|}"
    rm -rf "$orig"; cp -a "$stash" "$orig"
  done
  for f in ${_TXN_RMFILE[@]+"${_TXN_RMFILE[@]}"}; do rm -f "$f"; done
  for ((i = ${#_TXN_RMDIR[@]} - 1; i >= 0; i--)); do rmdir "${_TXN_RMDIR[i]}" 2>/dev/null; done
  rm -rf "$_TXN_DIR"
  echo "!! Rollback complete. No files were changed, moved, or deleted." >&2
  exit 1
}

txn_commit() {
  local c
  for c in ${_TXN_ONCOMMIT[@]+"${_TXN_ONCOMMIT[@]}"}; do eval "$c" || true; done
  trap - ERR INT TERM
  rm -rf "$_TXN_DIR"
}
