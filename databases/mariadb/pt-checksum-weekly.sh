#!/usr/bin/env bash
#
# pt-checksum-weekly.sh
# Runs pt-table-checksum on the master, then alerts to Discord if any chunk
# differs on the replica (or if the run itself failed). Long alerts are split
# across multiple Discord messages instead of being truncated.
#
# Prerequisites:
#   - Percona Toolkit installed (pt-table-checksum), plus: jq, curl, mariadb client
#   - percona.dsns row pointing at the replica (see notes below)
#   - /etc/percona/ptcheck.cnf  (chmod 600)  ->  [client] user=... password=...
#   - Discord webhook URL (Server Settings -> Integrations -> Webhooks)
#
# Run as root (for ulimit + socket access). Schedule via cron, e.g.:
#   /etc/cron.d/pt-table-checksum
#   0 3 * * 0 root /usr/bin/flock -n /run/ptcheck.lock /usr/local/bin/pt-checksum-weekly.sh

set -uo pipefail

# ----------------------------- config ---------------------------------------
CNF=/etc/percona/ptcheck.cnf
MASTER_HOST=192.168.128.36
REPLICA_HOST=192.168.128.39
LOGDIR=/var/log/pt-table-checksum

# Webhook: hardcode here, or keep it in a root-only file and source it, e.g.
#   echo 'DISCORD_WEBHOOK=https://discord.com/api/webhooks/XXXX/YYYY' > /etc/percona/discord.env
#   chmod 600 /etc/percona/discord.env  ;  then uncomment the next line:
# [ -r /etc/percona/discord.env ] && . /etc/percona/discord.env
DISCORD_WEBHOOK="${DISCORD_WEBHOOK:-https://discord.com/api/webhooks/XXXX/YYYY}"

# Per-message text budget. Discord's hard cap is 2000 chars; we leave headroom
# for the code-fence markers and a safety margin.
DISCORD_LIMIT=1850

LOG="$LOGDIR/$(date +%F_%H%M).log"
mkdir -p "$LOGDIR"

# --------------------------- discord helpers --------------------------------

# Post a single message. Content MUST already be < 2000 chars.
# jq does the JSON escaping so quotes/newlines/backticks can't break the payload.
post_discord() {
    curl -s -H "Content-Type: application/json" \
        -d "$(jq -n --arg c "$1" '{content:$c}')" \
        "$DISCORD_WEBHOOK" >/dev/null
    sleep 1   # stay under Discord's webhook rate limit
}

# Post multi-line text as one or more fenced code-block messages, splitting on
# line boundaries so no line is ever cut in half. Each chunk is independently
# wrapped in its own ``` fence, so a split never breaks the formatting.
post_discord_block() {
    local text="$1" chunk="" line
    while IFS= read -r line; do
        if [ $(( ${#chunk} + ${#line} + 1 )) -gt "$DISCORD_LIMIT" ] && [ -n "$chunk" ]; then
            post_discord $'```\n'"$chunk"$'```'
            chunk=""
        fi
        chunk+="$line"$'\n'
    done <<< "$text"
    [ -n "$chunk" ] && post_discord $'```\n'"$chunk"$'```'
}

# ----------------------------- run checksum ---------------------------------
ulimit -n 1048576 2>/dev/null || true   # the many tenant tablespaces

pt-table-checksum \
    --defaults-file="$CNF" --socket=/run/mysqld/mysqld.sock \
    --recursion-method=dsn=h=${MASTER_HOST},D=percona,t=dsns \
    --no-check-binlog-format \
    --chunk-size=1000 --max-load="Threads_running=40" \
    --ignore-tables-regex='(cache|cache_locks|sessions|jobs|failed_jobs|password_resets|personal_access_tokens)$' \
    >"$LOG" 2>&1
RC=$?

# Count differing chunks from the replica's copy of the checksum results.
# If the query itself fails (e.g. replica unreachable), DIFFS is empty and the
# alert still fires via the ${DIFFS:-1} fallback below.
DIFFS=$(mysql --defaults-file="$CNF" -h "$REPLICA_HOST" -N -e \
    "SELECT COUNT(*) FROM percona.checksums
     WHERE master_cnt<>this_cnt OR master_crc<>this_crc
        OR ISNULL(master_crc)<>ISNULL(this_crc);" 2>>"$LOG")

# ------------------------------- alert --------------------------------------
if [ "${DIFFS:-1}" -gt 0 ] || [ "$RC" -ne 0 ]; then

    HEADER=$(printf '**Replica drift / checksum alert** on `%s`\nTime: %s\nChecksum exit: %s | Differing chunks: %s\nFull log: `%s`' \
        "$(hostname)" "$(date '+%Y-%m-%d %H:%M:%S')" "$RC" "${DIFFS:-unknown}" "$LOG")
    post_discord "$HEADER"

    TABLES=$(mysql --defaults-file="$CNF" -h "$REPLICA_HOST" -N -e \
        "SELECT CONCAT(db,'.',tbl,'  (',COUNT(*),' chunks)')
         FROM percona.checksums
         WHERE master_cnt<>this_cnt OR master_crc<>this_crc
         GROUP BY db, tbl ORDER BY db, tbl;" 2>>"$LOG")

    [ -n "$TABLES" ] && post_discord_block "$TABLES"
fi

# ----------------------------- housekeeping ---------------------------------
find "$LOGDIR" -name '*.log' -mtime +60 -delete
