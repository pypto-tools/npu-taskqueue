# Time-limited priority queue ledger.
#
# The ledger is stored beside the queue configuration as
# <taskqueue.conf without its .conf suffix>-priority.conf, so it inherits that
# directory's root ownership and update rules. Each data line is
#
#   <user> <expiry_epoch> <granted_epoch>
#
# The scheduler compares expiry on every tick, so a grant takes effect and
# lapses without a timer or daemon restart. Malformed, expired and superseded
# lines grant nothing. Only the root-only `task-submit --priority` command
# writes this file; the daemon's configuration-directory ownership check makes
# that directory unavailable to ordinary users.

PRIORITY_GRANT_MAX_DAYS=14

# The daemon sources this module inside load_scheduler(). Keep username keys
# associative after that function returns.
declare -gA PRIORITY_GRANT_UNTIL=()

# Populate PRIORITY_GRANT_UNTIL[user]=expiry_epoch with unexpired grants.
priority_load_grants() {
    local line user expiry now
    PRIORITY_GRANT_UNTIL=()
    [[ -n "${PRIORITY_FILE:-}" && -r "$PRIORITY_FILE" ]] || return 0
    printf -v now '%(%s)T' -1
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line#"${line%%[![:space:]]*}"}"
        [[ -n "$line" && "$line" != \#* ]] || continue
        read -r user expiry _ <<< "$line"
        [[ "$user" =~ ^[A-Za-z0-9._-]+$ && "$expiry" =~ ^[0-9]+$ ]] || continue
        (( expiry > now )) && PRIORITY_GRANT_UNTIL["$user"]="$expiry"
    done < "$PRIORITY_FILE"
    return 0
}

# Print a user's unexpired expiry, or fail when no grant is active.
priority_expiry_of() {
    local user="$1"
    priority_load_grants
    [[ -n "${PRIORITY_GRANT_UNTIL[$user]:-}" ]] || return 1
    printf '%s' "${PRIORITY_GRANT_UNTIL[$user]}"
}

priority_ledger_dir() {
    local dir="${PRIORITY_FILE%/*}"
    [[ "$dir" != "$PRIORITY_FILE" ]] || dir="."
    printf '%s' "$dir"
}

# Replace the ledger atomically, keeping every other user's line. The caller is
# root, which is also what makes the chown to root:root meaningful.
priority_write_grant() {
    local user="$1" expiry="$2" granted="$3"
    local dir tmp line first
    [[ -n "${PRIORITY_FILE:-}" ]] || return 1
    dir=$(priority_ledger_dir)
    (
        flock -x 9 || exit 1
        tmp=$(mktemp "$dir/.priority.XXXXXX") || exit 1
        {
            printf '# user expiry_epoch granted_epoch\n'
            if [[ -r "$PRIORITY_FILE" ]]; then
                while IFS= read -r line || [[ -n "$line" ]]; do
                    [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
                    read -r first _ <<< "$line"
                    [[ "$first" == "$user" ]] && continue
                    printf '%s\n' "$line"
                done < "$PRIORITY_FILE"
            fi
            printf '%s %s %s\n' "$user" "$expiry" "$granted"
        } > "$tmp" || { rm -f "$tmp"; exit 1; }
        chmod 0644 "$tmp" && chown 0:0 "$tmp" && mv -f "$tmp" "$PRIORITY_FILE" || {
            rm -f "$tmp"
            exit 1
        }
    ) 9>>"$dir/.priority.lock"
}

# Remove a user's line. Returns non-zero when the ledger held no such user.
priority_remove_grant() {
    local user="$1"
    local dir tmp line first found=0
    [[ -n "${PRIORITY_FILE:-}" && -r "$PRIORITY_FILE" ]] || return 1
    dir=$(priority_ledger_dir)
    (
        flock -x 9 || exit 1
        tmp=$(mktemp "$dir/.priority.XXXXXX") || exit 1
        {
            printf '# user expiry_epoch granted_epoch\n'
            while IFS= read -r line || [[ -n "$line" ]]; do
                [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
                read -r first _ <<< "$line"
                if [[ "$first" == "$user" ]]; then
                    found=1
                    continue
                fi
                printf '%s\n' "$line"
            done < "$PRIORITY_FILE"
        } > "$tmp" || { rm -f "$tmp"; exit 1; }
        if (( found == 0 )); then
            rm -f "$tmp"
            exit 1
        fi
        chmod 0644 "$tmp" && chown 0:0 "$tmp" && mv -f "$tmp" "$PRIORITY_FILE" || {
            rm -f "$tmp"
            exit 1
        }
    ) 9>>"$dir/.priority.lock"
}
