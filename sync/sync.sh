#!/usr/bin/env bash
# =============================================================================
# TFS-GitLab Sync — git mirror + PR bridge + CodeRabbit comment feedback
#
# Environment variables (all required unless noted):
#   TFS_URL           Base URL incl. collection, e.g.
#                       https://tfs.company.com/tfs/DefaultCollection
#                       https://dev.azure.com/orgname
#   TFS_PROJECT       Team project name, e.g. MyProject
#   TFS_PAT           TFS / Azure DevOps Personal Access Token
#   TFS_REPOS         (optional) Comma-separated repo names to mirror.
#                     Leave empty to mirror ALL repos in TFS_PROJECT.
#   GITLAB_URL        Internal GitLab URL, e.g. http://gitlab:8081
#   GITLAB_TOKEN      GitLab PAT with api scope
#   GITLAB_NAMESPACE  (optional) GitLab group for mirrors. Default: tfs-mirrors
#   SYNC_INTERVAL     (optional) Seconds between cycles.   Default: 60
# =============================================================================
set -euo pipefail

# ── Configuration ─────────────────────────────────────────────────────────────
: "${TFS_URL:?TFS_URL is required}"
: "${TFS_PROJECT:?TFS_PROJECT is required}"
: "${TFS_PAT:?TFS_PAT is required}"
: "${GITLAB_URL:?GITLAB_URL is required}"
: "${GITLAB_TOKEN:?GITLAB_TOKEN is required}"

TFS_REPOS="${TFS_REPOS:-}"
GITLAB_NAMESPACE="${GITLAB_NAMESPACE:-tfs-mirrors}"
SYNC_INTERVAL="${SYNC_INTERVAL:-60}"
WORK_DIR="/repos"

# Embed in GitLab MR description to track TFS origin (never change format)
TFS_PR_TAG_PREFIX="<!-- TFS_PR_ID:"
TFS_PR_TAG_SUFFIX=" -->"
SYNC_TAG_PREFIX="<!-- LAST_SYNC:"
SYNC_TAG_SUFFIX=" -->"

# ── Logging ───────────────────────────────────────────────────────────────────
log()  { printf '[%s] %s\n'   "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"; }
warn() { printf '[%s] WARN %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >&2; }
die()  { warn "$*"; exit 1; }

# ── URL helpers ───────────────────────────────────────────────────────────────
url_encode() {
    python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1],safe=''))" "$1"
}

# Insert credentials into a URL:  inject_creds https://host/path user pass
inject_creds() {
    local url="$1" user="$2" pass="$3"
    local scheme="${url%%://*}"
    local rest="${url#*://}"
    printf '%s://%s:%s@%s' "$scheme" \
        "$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1],safe=''))" "$user")" \
        "$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1],safe=''))" "$pass")" \
        "$rest"
}

mask()  { mask2 "${1//$TFS_PAT/****}"; }
mask2() { echo "${1//$GITLAB_TOKEN/####}"; }

# ── TFS REST API ──────────────────────────────────────────────────────────────
# Usage: tfs_api <method> <path_relative_to_TFS_URL/TFS_PROJECT> [curl-opts...]
tfs_api() {
    local method="$1"; local rel_path="$2"; shift 2
    local auth
    auth=$(printf ':%s' "$TFS_PAT" | base64 | tr -d '\n')
    # --location-trusted keeps the Authorization header on every redirect hop.
    # Plain --location drops it, causing TF400813 (anonymous access) on TFS.
    curl -sf --location-trusted --insecure \
        -X "$method" \
        -H "Authorization: Basic ${auth}" \
        -H "Content-Type: application/json" \
        "$@" \
        "${TFS_URL}/${TFS_PROJECT}${rel_path}"
}

# ── GitLab REST API ───────────────────────────────────────────────────────────
# Usage: gl_api <method> <path_under_/api/v4> [curl-opts...]
gl_api() {
    local method="$1"; local path="$2"; shift 2
    curl -sf \
        -X "$method" \
        -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
        -H "Content-Type: application/json" \
        "$@" \
        "${GITLAB_URL}/api/v4${path}"
}

# ── Repository discovery ──────────────────────────────────────────────────────
get_tfs_repos() {
    if [ -n "$TFS_REPOS" ]; then
        echo "$TFS_REPOS" | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
    else
        tfs_api GET "/_apis/git/repositories?api-version=1.0" \
            | jq -r '.value[].name'
    fi
}

# ── GitLab namespace / project management ─────────────────────────────────────
ensure_gl_namespace() {
    local ns="$GITLAB_NAMESPACE"
    local existing
    # curl -sf returns exit code 22 on 404 (group not yet created); suppress that
    # with || true so set -e doesn't kill the script before we can create the group.
    existing=$(gl_api GET "/groups/$(url_encode "$ns")" 2>/dev/null | jq -r '.id // empty') || true
    if [ -n "$existing" ]; then
        echo "$existing"; return
    fi
    log "Creating GitLab group '${ns}'"
    gl_api POST "/groups" \
        -d "{\"name\":\"${ns}\",\"path\":\"${ns}\",\"visibility\":\"private\"}" \
        | jq -r '.id'
}

get_or_create_gl_project() {
    local repo_name="$1"
    local full_path="${GITLAB_NAMESPACE}/${repo_name}"
    local encoded; encoded="$(url_encode "$full_path")"

    local pid
    pid=$(gl_api GET "/projects/${encoded}" 2>/dev/null | jq -r '.id // empty')

    if [ -z "$pid" ]; then
        log "[${repo_name}] Creating GitLab project '${full_path}'"
        local group_id; group_id=$(ensure_gl_namespace)
        pid=$(gl_api POST "/projects" \
            -d "$(jq -n \
                --arg n  "$repo_name" \
                --arg gid "$group_id" \
                '{name:$n, path:$n, namespace_id:($gid|tonumber),
                  visibility:"private", initialize_with_readme:false,
                  merge_method:"merge"}')" \
            | jq -r '.id')
        log "[${repo_name}] GitLab project created (id=${pid})"
    fi
    echo "$pid"
}

# ── Git mirroring ─────────────────────────────────────────────────────────────
sync_git() {
    local repo_name="$1"
    local project_id="$2"
    local mirror_dir="${WORK_DIR}/${repo_name}.git"

    # Plain TFS URL — no embedded credentials.
    # Auth is passed via http.extraHeader so git sends it on every redirect hop,
    # matching the --location-trusted behaviour used in tfs_api().
    local tfs_url="${TFS_URL}/${TFS_PROJECT}/_git/${repo_name}"
    local tfs_auth; tfs_auth=$(printf ':%s' "$TFS_PAT" | base64 | tr -d '\n')

    local gl_host="${GITLAB_URL#*://}"
    local gl_scheme="${GITLAB_URL%%://*}"
    local gl_url="${gl_scheme}://oauth2:${GITLAB_TOKEN}@${gl_host}/${GITLAB_NAMESPACE}/${repo_name}.git"

    # Shorthand: run git with TFS auth header + SSL verification disabled (on-prem TFS)
    tfs_git() {
        git -c "http.extraHeader=Authorization: Basic ${tfs_auth}" \
            -c http.sslVerify=false \
            "$@"
    }

    if [ ! -d "$mirror_dir" ]; then
        log "[${repo_name}] Initial clone from TFS (this may take a while)..."
        tfs_git clone --mirror "$tfs_url" "$mirror_dir" 2>&1 \
            | sed "s|${TFS_PAT}|****|g" \
            || { warn "[${repo_name}] Clone failed"; return 1; }
    else
        log "[${repo_name}] Fetching updates from TFS..."
        tfs_git -C "$mirror_dir" remote update --prune 2>&1 \
            | sed "s|${TFS_PAT}|****|g" \
            || { warn "[${repo_name}] Fetch failed"; return 1; }
    fi

    # Reconfigure push remote (URL may change after restart)
    (cd "$mirror_dir" && git remote set-url --push origin "$gl_url" 2>/dev/null \
        || git remote add origin "$gl_url" 2>/dev/null || true)

    log "[${repo_name}] Pushing to GitLab..."
    GIT_DIR="$mirror_dir" git push --mirror \
        "$gl_url" 2>&1 \
        | sed "s|${GITLAB_TOKEN}|####|g" \
        || warn "[${repo_name}] Push to GitLab had errors (may be non-fatal)"
}

# ── PR bridge helpers ─────────────────────────────────────────────────────────

# Embed the TFS PR id marker inside a GitLab MR description
tag_description() {
    local base_desc="$1" tfs_pr_id="$2"
    printf '%s\n\n%s%s%s' "$base_desc" \
        "$TFS_PR_TAG_PREFIX" "$tfs_pr_id" "$TFS_PR_TAG_SUFFIX"
}

# Extract TFS PR id from MR description (returns empty string if not found)
extract_tfs_pr_id() {
    echo "$1" | grep -oP "(?<=${TFS_PR_TAG_PREFIX//\[/\\[})[0-9]+(?=${TFS_PR_TAG_SUFFIX// /\\ })" \
        2>/dev/null || true
}

extract_last_sync_id() {
    echo "$1" | grep -oP "(?<=${SYNC_TAG_PREFIX//\[/\\[})[0-9]+(?=${SYNC_TAG_SUFFIX// /\\ })" \
        2>/dev/null || echo "0"
}

replace_sync_id() {
    local desc="$1" new_id="$2"
    # Remove old tag then append new one
    desc=$(echo "$desc" | sed "s|${SYNC_TAG_PREFIX}[0-9]*${SYNC_TAG_SUFFIX}||g")
    printf '%s%s%s%s' "$desc" "$SYNC_TAG_PREFIX" "$new_id" "$SYNC_TAG_SUFFIX"
}

# Find GitLab MR iid for a given TFS PR id (returns empty if not found)
find_gl_mr() {
    local project_id="$1" tfs_pr_id="$2"
    gl_api GET "/projects/${project_id}/merge_requests?labels=tfs-pr&state=all&per_page=100" \
        2>/dev/null \
        | jq -r \
            --arg tag "${TFS_PR_TAG_PREFIX}${tfs_pr_id}${TFS_PR_TAG_SUFFIX}" \
            '.[] | select((.description // "") | contains($tag)) | .iid' \
        | head -1
}

# ── PR bridge: TFS → GitLab MR ────────────────────────────────────────────────
bridge_tfs_pr() {
    local repo_name="$1" project_id="$2" pr

    # Fetch all active TFS PRs for this repo
    local prs_json
    prs_json=$(tfs_api GET \
        "/_apis/git/repositories/${repo_name}/pullrequests?api-version=1.0&status=active" \
        2>/dev/null) || { warn "[${repo_name}] Could not fetch TFS PRs"; return; }

    local count; count=$(echo "$prs_json" | jq '.count // 0')
    [ "$count" -eq 0 ] && return

    while IFS= read -r pr; do
        [ -z "$pr" ] && continue

        local tfs_pr_id title source target description
        tfs_pr_id=$(echo "$pr" | jq -r '.pullRequestId')
        title=$(echo "$pr"       | jq -r '.title')
        source=$(echo "$pr"      | jq -r '.sourceRefName' | sed 's|refs/heads/||')
        target=$(echo "$pr"      | jq -r '.targetRefName' | sed 's|refs/heads/||')
        description=$(echo "$pr" | jq -r '.description // ""')

        local mr_iid; mr_iid=$(find_gl_mr "$project_id" "$tfs_pr_id")

        if [ -z "$mr_iid" ]; then
            # Create GitLab MR
            local full_desc; full_desc=$(tag_description \
                "**Mirrored from TFS PR #${tfs_pr_id}**\n\n${description}" \
                "$tfs_pr_id")
            log "[${repo_name}] Creating GitLab MR for TFS PR #${tfs_pr_id}: ${title}"
            local new_iid
            new_iid=$(gl_api POST "/projects/${project_id}/merge_requests" \
                -d "$(jq -n \
                    --arg t   "[TFS #${tfs_pr_id}] ${title}" \
                    --arg src "$source" \
                    --arg tgt "$target" \
                    --arg d   "$full_desc" \
                    '{title:$t, source_branch:$src, target_branch:$tgt,
                      description:$d, labels:"tfs-pr",
                      remove_source_branch:false}')" \
                2>/dev/null | jq -r '.iid // empty')
            [ -n "$new_iid" ] \
                && log "[${repo_name}] GitLab MR !${new_iid} created for TFS PR #${tfs_pr_id}" \
                || warn "[${repo_name}] Failed to create GitLab MR for TFS PR #${tfs_pr_id} (branches may not exist yet)"
        else
            # MR exists — sync CodeRabbit comments back to TFS
            sync_comments_to_tfs "$repo_name" "$project_id" "$mr_iid" "$tfs_pr_id"
        fi
    done < <(echo "$prs_json" | jq -c '.value[]')

    # Close GitLab MRs whose TFS PRs are no longer active
    close_orphaned_mrs "$repo_name" "$project_id"
}

# ── Comment feedback: GitLab → TFS ────────────────────────────────────────────
sync_comments_to_tfs() {
    local repo_name="$1" project_id="$2" mr_iid="$3" tfs_pr_id="$4"

    # Get current MR description (holds last-sync watermark)
    local mr_json
    mr_json=$(gl_api GET "/projects/${project_id}/merge_requests/${mr_iid}" \
        2>/dev/null) || return
    local mr_desc; mr_desc=$(echo "$mr_json" | jq -r '.description // ""')
    local last_sync_id; last_sync_id=$(extract_last_sync_id "$mr_desc")

    # Fetch all notes (comments) on the MR
    local notes
    notes=$(gl_api GET \
        "/projects/${project_id}/merge_requests/${mr_iid}/notes?per_page=100&sort=asc" \
        2>/dev/null | jq -c '.[]' 2>/dev/null) || return

    local max_id="$last_sync_id"
    local synced=0

    while IFS= read -r note; do
        [ -z "$note" ] && continue

        local note_id author body is_system
        note_id=$(echo "$note"  | jq -r '.id')
        author=$(echo "$note"   | jq -r '.author.username')
        body=$(echo "$note"     | jq -r '.body')
        is_system=$(echo "$note"| jq -r '.system')

        [ "$is_system" = "true" ] && continue
        # Only forward CodeRabbit review comments
        [[ "$author" != *"coderabbit"* ]] && continue
        # Skip already-synced notes
        [ "$note_id" -le "$last_sync_id" ] 2>/dev/null && continue

        local thread_body="**CodeRabbit AI Review (GitLab MR !${mr_iid}):**\n\n${body}"
        tfs_api POST \
            "/_apis/git/repositories/${repo_name}/pullrequests/${tfs_pr_id}/threads?api-version=1.0" \
            -d "$(jq -n --arg b "$thread_body" \
                '{comments:[{parentCommentId:0,content:$b,commentType:1}],status:1}')" \
            >/dev/null 2>&1 && synced=$((synced + 1)) \
            || warn "[${repo_name}] Failed to post comment to TFS PR #${tfs_pr_id}"

        [ "$note_id" -gt "$max_id" ] && max_id="$note_id"
    done <<< "$notes"

    # Update watermark in MR description if anything was synced
    if [ "$max_id" != "$last_sync_id" ] && [ "$synced" -gt 0 ]; then
        local new_desc; new_desc=$(replace_sync_id "$mr_desc" "$max_id")
        gl_api PUT "/projects/${project_id}/merge_requests/${mr_iid}" \
            -d "$(jq -n --arg d "$new_desc" '{description:$d}')" \
            >/dev/null 2>&1
        log "[${repo_name}] Forwarded ${synced} CodeRabbit comment(s) to TFS PR #${tfs_pr_id}"
    fi
}

# ── Close GitLab MRs when TFS PRs are resolved ────────────────────────────────
close_orphaned_mrs() {
    local repo_name="$1" project_id="$2"

    local open_mrs
    open_mrs=$(gl_api GET \
        "/projects/${project_id}/merge_requests?state=opened&labels=tfs-pr&per_page=100" \
        2>/dev/null | jq -c '.[]' 2>/dev/null) || return

    while IFS= read -r mr; do
        [ -z "$mr" ] && continue
        local mr_iid desc tfs_pr_id
        mr_iid=$(echo "$mr" | jq -r '.iid')
        desc=$(echo "$mr"   | jq -r '.description // ""')
        tfs_pr_id=$(extract_tfs_pr_id "$desc")
        [ -z "$tfs_pr_id" ] && continue

        local tfs_status
        tfs_status=$(tfs_api GET \
            "/_apis/git/repositories/${repo_name}/pullrequests/${tfs_pr_id}?api-version=1.0" \
            2>/dev/null | jq -r '.status // "notFound"') || tfs_status="notFound"

        if [ "$tfs_status" != "active" ]; then
            log "[${repo_name}] Closing GitLab MR !${mr_iid} (TFS PR #${tfs_pr_id} is '${tfs_status}')"
            gl_api PUT "/projects/${project_id}/merge_requests/${mr_iid}" \
                -d '{"state_event":"close"}' >/dev/null 2>&1
        fi
    done <<< "$open_mrs"
}

# ── Single-repo sync cycle ────────────────────────────────────────────────────
sync_repo() {
    local repo_name="$1"
    log "[${repo_name}] ──────────────────────────────────────"

    # Ensure GitLab project exists and get its id
    local project_id
    project_id=$(get_or_create_gl_project "$repo_name") \
        || { warn "[${repo_name}] Could not get/create GitLab project, skipping"; return; }

    # 1. Mirror git content
    sync_git "$repo_name" "$project_id" \
        || { warn "[${repo_name}] Git sync failed, skipping PR bridge"; return; }

    # 2. Bridge PRs and forward review comments
    bridge_tfs_pr "$repo_name" "$project_id"

    log "[${repo_name}] Done"
}

# ── Main loop ─────────────────────────────────────────────────────────────────
main() {
    mkdir -p "$WORK_DIR"

    log "════════════════════════════════════════"
    log "TFS-GitLab Sync starting"
    log "  TFS     : ${TFS_URL}/${TFS_PROJECT}"
    log "  GitLab  : ${GITLAB_URL}/${GITLAB_NAMESPACE}"
    log "  Interval: ${SYNC_INTERVAL}s"
    [ -n "$TFS_REPOS" ] \
        && log "  Repos   : ${TFS_REPOS}" \
        || log "  Repos   : all (auto-discover)"
    log "════════════════════════════════════════"

    # Ensure namespace exists before first cycle
    ensure_gl_namespace >/dev/null

    while true; do
        log "── Sync cycle start ─────────────────────"

        while IFS= read -r repo_name; do
            [ -z "$repo_name" ] && continue
            sync_repo "$repo_name" || warn "Sync failed for '${repo_name}'"
        done < <(get_tfs_repos)

        log "── Cycle complete — sleeping ${SYNC_INTERVAL}s ──"
        sleep "$SYNC_INTERVAL"
    done
}

main
