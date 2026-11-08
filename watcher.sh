#!/usr/bin/env bash
# ============================================================
# watchplex.sh -- Plex Permissions Watcher
# Supports incremental (rsync/close_write) and atomic moves
# (qBittorrent mv-style) via IN_MOVED_TO + IN_CREATE
# ============================================================

# ------------------------------------------------------------
# TOGGLES
# ------------------------------------------------------------
LOGGING=true          # Master switch: write to log file at all
DRY_RUN=false         # If true, print actions but do not chmod/chown

# Log verbosity -- controls what is written to log AND stdout
# ERROR   : failures and retries only
# INFO    : + startup messages, sweep summaries, watch start     [default]
# VERBOSE : + every individual file/dir successfully fixed
# DEBUG   : + every raw inotify event, skips, retry attempts
LOG_LEVEL="INFO"

# ------------------------------------------------------------
# OWNERSHIP
# User and group that files and directories are chown'd to.
# These apply to every WATCH_CONFIG entry below that does not
# name its own owner/group. Both must already exist on the
# system (check with:  id USERNAME   and   getent group GROUPNAME).
# Numeric IDs also work.
# ------------------------------------------------------------
WATCH_USER="auguss82"
WATCH_GROUP="auguss82"

# ------------------------------------------------------------
# LOG FILE
# ------------------------------------------------------------
LOG_DIR="/var/log/watchplex"         # Parent log directory -- change here to relocate everything
LOG_FILE="${LOG_DIR}/watchplex.log"   # Derived from LOG_DIR
LOG_MAX_BYTES=10485760                # Rotate when log exceeds this size (10 MB)
LOG_MAX_BACKUPS=1                     # Number of rotated backups to keep (.1, .2, ...)

# ------------------------------------------------------------
# WATCH CONFIG
# key   = base directory (watched recursively)
# value = "dir_perms:file_perms"                     -> uses WATCH_USER:WATCH_GROUP
#         "dir_perms:file_perms:owner:group"         -> overrides the owner/group
#                                                       for this directory only
# An empty owner or group field also falls back to the defaults,
# e.g. "775:664:otheruser:" keeps WATCH_GROUP.
# ------------------------------------------------------------
declare -A WATCH_CONFIG
WATCH_CONFIG=(
    ["/dvr/qb"]="775:664"
    ["/dvr/plex"]="777:666"
)

# ------------------------------------------------------------
# EXCLUDE PATHS
# Subtrees or files inside a watch root that should never be
# touched by fix_one. Prevents feedback loops where writing
# a log file or fixing a file triggers another event.
# Matched as a prefix against the event path.
# ------------------------------------------------------------
EXCLUDE_PATHS=(
    # "/dvr/qb/logs"  # example -- add paths here if logs ever move back inside a watch root
)

# ------------------------------------------------------------
# STARTUP SWEEP
# ------------------------------------------------------------
SWEEP_ON_STARTUP=true   # Run fix_all on each watch root at startup

# ------------------------------------------------------------
# INOTIFY EVENTS
# Space-separated list of inotify events to watch.
# close_write : rsync / incremental write finishes
# create      : new file or dir appears (any method)
# moved_to    : qBittorrent atomic mv into watched dir
# NOTE: attrib is intentionally excluded -- chmod/chown fires
# ATTRIB which would re-trigger fix_one in an endless loop.
# ------------------------------------------------------------
INOTIFY_EVENTS="close_write create moved_to"

# ------------------------------------------------------------
# RETRY / TIMING
# ------------------------------------------------------------
MAX_RETRIES=3          # Attempts per fix_one before giving up
RETRY_DELAY=5          # Seconds between fix_one retry attempts
RESTART_DELAY=5        # Seconds before restarting inotifywait after exit
MAX_RESTART_ATTEMPTS=5 # Max consecutive inotifywait restarts before giving up (0 = unlimited)

# ------------------------------------------------------------
# LOCK FILE -- prevents duplicate instances
# ------------------------------------------------------------
LOCK_FILE="/opt/scripts/watchplex/watchplex.lock"

# ------------------------------------------------------------
# TEMP-FILE FILTER PATTERNS  (matching paths are skipped)
# ------------------------------------------------------------
TMPFILE_SUFFIX='\.[a-zA-Z0-9]{6}$'
TMPFILE_DOUBLE_DOT='^\..*\.'
TMPFILE_TMPNAME='::TMPNAME'

# ------------------------------------------------------------
# BINARIES
# ------------------------------------------------------------
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
INOTIFYWAIT=/usr/bin/inotifywait
CHMOD=/bin/chmod
CHOWN=/bin/chown
FIND=/usr/bin/find

# ============================================================
# DIRECTORIES
# ============================================================
mkdir -p "$LOG_DIR"

# ============================================================
# LOGGING
# ============================================================
_level_rank() {
    case "$1" in
        ERROR)   echo 0 ;;
        INFO)    echo 1 ;;
        VERBOSE) echo 2 ;;
        DEBUG)   echo 3 ;;
        *)       echo 1 ;;
    esac
}

_log() {
    local level="$1"; shift
    local want_rank cur_rank
    want_rank=$(_level_rank "$level")
    cur_rank=$(_level_rank "$LOG_LEVEL")
    (( want_rank > cur_rank )) && return 0

    local ts msg
    ts="$(date '+%Y-%m-%d %H:%M:%S')"
    msg="[$ts] [$(printf '%-7s' "$level")] $*"

    echo "$msg"

    [[ "$LOGGING" != true ]] && return 0

    [[ ! -f "$LOG_FILE" ]] && touch "$LOG_FILE"

    local size
    size=$(stat -c%s "$LOG_FILE" 2>/dev/null || echo 0)
    if (( size >= LOG_MAX_BYTES )); then
        local i
        for (( i=LOG_MAX_BACKUPS; i>=1; i-- )); do
            local older=$(( i - 1 ))
            local src="${LOG_FILE}.${older}"
            local dst="${LOG_FILE}.${i}"
            [[ "$older" -eq 0 ]] && src="$LOG_FILE"
            if [[ -f "$src" ]]; then
                if (( i <= LOG_MAX_BACKUPS )); then
                    mv "$src" "$dst"
                else
                    rm -f "$src"
                fi
            fi
        done
        echo "[$ts] [INFO   ] Log rotated" >> "$LOG_FILE"
    fi

    echo "$msg" >> "$LOG_FILE"
}

log_error()   { _log "ERROR"   "$@"; }
log_info()    { _log "INFO"    "$@"; }
log_verbose() { _log "VERBOSE" "$@"; }
log_debug()   { _log "DEBUG"   "$@"; }

# ============================================================
# LOCK -- prevent duplicate instances
# ============================================================
cleanup_lock() {
    rm -f "$LOCK_FILE"
}

if [[ -f "$LOCK_FILE" ]]; then
    LOCK_PID=$(cat "$LOCK_FILE" 2>/dev/null)
    if [[ -n "$LOCK_PID" ]] && kill -0 "$LOCK_PID" 2>/dev/null; then
        log_error "Another instance is already running (PID ${LOCK_PID}) -- exiting"
        exit 1
    else
        log_debug "Stale lock file found (PID ${LOCK_PID}) -- cleaning up"
        rm -f "$LOCK_FILE"
    fi
fi

echo $$ > "$LOCK_FILE"
trap cleanup_lock EXIT

# ============================================================
# STRICT MODE + ERR TRAP
# ============================================================
set -Eeuo pipefail
[[ "$LOG_LEVEL" == "DEBUG" ]] && trap 'log_error "Line $LINENO exited with status $?"' ERR

# ============================================================
# CONFIG HELPERS
# ============================================================
get_dir_perm()  { echo "${WATCH_CONFIG[$1]}" | cut -d: -f1; }
get_file_perm() { echo "${WATCH_CONFIG[$1]}" | cut -d: -f2; }

# Owner and group for a watch root: the entry's own fields if given,
# otherwise the WATCH_USER / WATCH_GROUP defaults. Prints "owner:group".
get_owner() {
    local _dp _fp o g
    IFS=: read -r _dp _fp o g <<< "${WATCH_CONFIG[$1]}"
    echo "${o:-$WATCH_USER}:${g:-$WATCH_GROUP}"
}

# ============================================================
# STARTUP CHECKS
# ============================================================
startup_checks() {
    local ok=true

    [[ -x "$INOTIFYWAIT" ]] || {
        log_error "inotifywait not found at $INOTIFYWAIT -- install inotify-tools"
        ok=false
    }

    local dir owner o g
    for dir in "${!WATCH_CONFIG[@]}"; do
        [[ -d "$dir" ]] || {
            log_error "Watch directory does not exist: $dir"
            ok=false
        }

        # The owner and group that will be applied must exist, otherwise
        # every chown would fail and be retried forever.
        owner="$(get_owner "$dir")"
        o="${owner%%:*}"
        g="${owner#*:}"
        id -u "$o" &>/dev/null || {
            log_error "User '$o' (for $dir) does not exist -- check WATCH_USER / WATCH_CONFIG"
            ok=false
        }
        getent group "$g" &>/dev/null || {
            log_error "Group '$g' (for $dir) does not exist -- check WATCH_GROUP / WATCH_CONFIG"
            ok=false
        }
    done

    [[ "$ok" == true ]] || exit 1
}

# ============================================================
# EXCLUDE PATH CHECK
# Returns 0 (skip) if path starts with any EXCLUDE_PATHS entry
# ============================================================
is_excluded() {
    local path="$1"
    for excl in "${EXCLUDE_PATHS[@]}"; do
        if [[ "$path" == "$excl"* ]]; then
            log_debug "Skipping excluded path: $path (matches $excl)"
            return 0
        fi
    done
    return 1
}

# ============================================================
# TEMP-FILE FILTER
# Returns 0 = skip, 1 = process
# ============================================================
is_tmpfile() {
    local path="$1"
    local filename
    filename="$(basename "$path")"

    if [[ "$filename" =~ $TMPFILE_SUFFIX ]]; then
        log_debug "Skipping tmp (suffix): $path"
        return 0
    fi
    if [[ "$filename" =~ $TMPFILE_DOUBLE_DOT ]]; then
        log_debug "Skipping tmp (double-dot): $path"
        return 0
    fi
    if [[ "$path" =~ $TMPFILE_TMPNAME ]]; then
        log_debug "Skipping tmp (TMPNAME): $path"
        return 0
    fi
    return 1
}

# ============================================================
# FIX ONE PATH  (file or directory tree, with retries)
# ============================================================
fix_one() {
    local base="$1"
    local path="$2"
    local context="${3:-inotify}"

    if [[ -z "${WATCH_CONFIG[$base]:-}" ]]; then
        log_error "No config for base directory: $base"
        return 1
    fi

    is_excluded "$path" && return 0
    is_tmpfile  "$path" && return 0
    [[ -e "$path" ]] || { log_debug "Path gone before fix: $path"; return 0; }

    local dir_perm file_perm ownership
    dir_perm=$(get_dir_perm  "$base")
    file_perm=$(get_file_perm "$base")
    ownership=$(get_owner     "$base")

    local attempt=0 success=false errors=""

    while (( attempt < MAX_RETRIES )); do
        attempt=$(( attempt + 1 ))
        errors=""

        if [[ "$DRY_RUN" == true ]]; then
            log_info "[DRY-RUN][$context] Would fix: $path (dirs=$dir_perm files=$file_perm owner=$ownership)"
            success=true
            break
        fi

        if [[ -d "$path" ]]; then
            log_debug "[$context] Fixing directory tree: $path (attempt $attempt/$MAX_RETRIES)"
            errors=$(
                {
                    $FIND "$path" -type d \
                        -exec $CHMOD "$dir_perm"  {} + \
                        -exec $CHOWN "$ownership" {} + 2>&1
                    $FIND "$path" -type f \
                        -exec $CHMOD "$file_perm" {} + \
                        -exec $CHOWN "$ownership" {} + 2>&1
                } | grep -v "^$" || true
            )
        elif [[ -f "$path" ]]; then
            log_debug "[$context] Fixing file: $path (attempt $attempt/$MAX_RETRIES)"
            errors=$(
                {
                    $CHMOD "$file_perm" "$path" 2>&1
                    $CHOWN "$ownership" "$path" 2>&1
                } | grep -v "^$" || true
            )
        fi

        if [[ -z "$errors" ]]; then
            success=true
            break
        else
            log_error "Attempt $attempt/$MAX_RETRIES failed for $path:"
            while IFS= read -r line; do
                log_error "  $line"
            done <<< "$errors"
            if (( attempt < MAX_RETRIES )); then
                log_error "Retrying in ${RETRY_DELAY}s..."
                sleep "$RETRY_DELAY"
            fi
        fi
    done

    if [[ "$success" == true ]]; then
        log_verbose "[$context] Fixed: $path (dirs=$dir_perm files=$file_perm owner=$ownership)"
    else
        log_error "All $MAX_RETRIES attempts failed for $path -- manual intervention required"
        return 1
    fi
}

# ============================================================
# FIX ALL -- full sweep of a watch root (used at startup)
# Excludes EXCLUDE_PATHS so any excluded dirs are not swept.
# ============================================================
fix_all() {
    local dir="$1"
    local dir_perm file_perm ownership
    dir_perm=$(get_dir_perm  "$dir")
    file_perm=$(get_file_perm "$dir")
    ownership=$(get_owner     "$dir")

    log_info "Startup sweep: $dir  (dirs=$dir_perm files=$file_perm owner=$ownership)"

    if [[ "$DRY_RUN" == true ]]; then
        log_info "[DRY-RUN] Would sweep: $dir"
        return 0
    fi

    # Build -prune expressions for each excluded path
    local prune_args=()
    for excl in "${EXCLUDE_PATHS[@]}"; do
        prune_args+=( -path "$excl" -prune -o )
    done

    local errors
    errors=$(
        {
            $FIND "$dir" "${prune_args[@]}" -type d \
                -exec $CHMOD "$dir_perm"  {} + \
                -exec $CHOWN "$ownership" {} + 2>&1
            $FIND "$dir" "${prune_args[@]}" -type f \
                -exec $CHMOD "$file_perm" {} + \
                -exec $CHOWN "$ownership" {} + 2>&1
        } | grep -v "^$" || true
    )

    if [[ -n "$errors" ]]; then
        while IFS= read -r line; do
            log_error "[startup] $line"
        done <<< "$errors"
    else
        log_info "Startup sweep complete: $dir"
    fi
}

# ============================================================
# WATCH LOOP
#
# Events are driven by INOTIFY_EVENTS toggle.
# ATTRIB is intentionally excluded -- chmod/chown fires ATTRIB
# which would re-trigger fix_one in an endless loop.
#
#   close_write -- rsync / incremental write finishes
#   create      -- new file or dir appears (any method)
#   moved_to    -- qBittorrent atomic mv into watched dir
#
# IN_MOVED_TO fires when rename(2)/mv lands a file inside the
# watched tree -- i.e. every qBittorrent category save-path move.
# ============================================================
watch_dir() {
    local DIR="$1"
    local restart_count=0

    # Build -e flags from INOTIFY_EVENTS toggle
    local event_args=()
    for evt in $INOTIFY_EVENTS; do
        event_args+=( -e "$evt" )
    done

    log_info "Watching $DIR  [${INOTIFY_EVENTS}]"

    while true; do
        $INOTIFYWAIT -m -r -q \
            "${event_args[@]}" \
            --format '%e %w%f' \
            "$DIR" 2>/dev/null |
        while IFS=' ' read -r EVENT FPATH; do
            log_debug "Event: $EVENT -> $FPATH"

            is_excluded "$FPATH" && continue

            case "$EVENT" in
                CLOSE_WRITE|CLOSE_WRITE,CLOSE)
                    fix_one "$DIR" "$FPATH" "close_write"
                    ;;
                CREATE|CREATE,ISDIR)
                    fix_one "$DIR" "$FPATH" "create"
                    ;;
                MOVED_TO|MOVED_TO,ISDIR)
                    log_debug "Atomic move landed: $FPATH"
                    fix_one "$DIR" "$FPATH" "atomic"
                    ;;
                *)
                    log_debug "Unhandled event '$EVENT': $FPATH"
                    ;;
            esac
        done

        restart_count=$(( restart_count + 1 ))

        if (( MAX_RESTART_ATTEMPTS > 0 && restart_count >= MAX_RESTART_ATTEMPTS )); then
            log_error "inotifywait for $DIR has restarted ${restart_count} times -- giving up"
            log_error "Manual intervention required: check if $DIR exists and is accessible"
            return 1
        fi

        log_error "inotifywait exited for $DIR (restart ${restart_count}/${MAX_RESTART_ATTEMPTS:-unlimited}) -- restarting in ${RESTART_DELAY}s..."
        sleep "$RESTART_DELAY"
    done
}

# ============================================================
# MAIN
# ============================================================

startup_checks

log_info "=========================================="
log_info "watchplex.sh starting"
log_info "  LOG_LEVEL        : $LOG_LEVEL  LOGGING: $LOGGING  DRY_RUN: $DRY_RUN"
log_info "  DEFAULT OWNER    : ${WATCH_USER}:${WATCH_GROUP}"
log_info "  SWEEP_ON_STARTUP : $SWEEP_ON_STARTUP"
log_info "  INOTIFY_EVENTS   : $INOTIFY_EVENTS"
log_info "  MAX_RESTARTS     : ${MAX_RESTART_ATTEMPTS} (0=unlimited)"
log_info "  MAX_RETRIES      : $MAX_RETRIES  RETRY_DELAY: ${RETRY_DELAY}s"
log_debug "  LOG_DIR          : $LOG_DIR"
log_debug "  LOG_FILE         : $LOG_FILE"
log_debug "  LOCK_FILE        : $LOCK_FILE"
log_debug "  PID              : $$"
log_verbose "  Watching         : ${!WATCH_CONFIG[*]}"
log_verbose "  Excluded         : ${EXCLUDE_PATHS[*]:-none}"
log_info "=========================================="

if [[ "$SWEEP_ON_STARTUP" == true ]]; then
    for DIR in "${!WATCH_CONFIG[@]}"; do
        fix_all "$DIR"
    done
else
    log_info "SWEEP_ON_STARTUP=false -- skipping initial sweep"
fi

for DIR in "${!WATCH_CONFIG[@]}"; do
    watch_dir "$DIR" &
done

wait
