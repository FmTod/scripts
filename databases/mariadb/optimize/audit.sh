#!/bin/bash
#
# MariaDB Telemetry Audit — v3
# Run as root on the target DB host. Read-only: issues no writes.
# Requires: working local MariaDB client auth (~/.my.cnf or root socket access).
# Recommended: sysstat for iostat  ->  apt-get install -y sysstat
#
# v3 changes (post-OOM incident on mariadb-new-read-replica-2):
#   [13] SCHEMA SCALE       -> table count drives table_open_cache /
#                              table_definition_cache MEMORY cost; a 65k-table
#                              instance was the root cause of the v2-tuned OOM.
#   [14] KERNEL OOM HISTORY -> surfaces prior OOM kills of mysqld/mariadbd so
#                              the tuner knows the box has already hit the wall.
#   [2]  adds vm.overcommit + CommitLimit for real headroom math.
#   [8]  adds explicit UPTIME CONFIDENCE flag: counters < 7 days are warm-up
#        data and must not be treated as steady state.
#   [10] extracts "Dictionary memory allocated" as a named scalar for trending.
#
set -o pipefail

# ---- client detection ------------------------------------------------------
if command -v mariadb >/dev/null 2>&1; then CLIENT=mariadb
elif command -v mysql >/dev/null 2>&1; then CLIENT=mysql
else echo "FATAL: no mariadb/mysql client in PATH." >&2; exit 1; fi
MYSQL="$CLIENT --connect-timeout=5"

# ---- connectivity guard ----------------------------------------------------
if ! $MYSQL -e "SELECT 1;" >/dev/null 2>&1; then
    echo "FATAL: cannot connect to MariaDB. Configure ~/.my.cnf or run with local access." >&2
    exit 1
fi
q()  { $MYSQL -e "$1" 2>/dev/null; }            # tabular
qs() { $MYSQL -N -B -e "$1" 2>/dev/null; }      # scalar / no header

DATADIR=$(qs "SELECT @@datadir;")
MPID=$(pgrep -o -x mariadbd 2>/dev/null || pgrep -o -x mysqld 2>/dev/null)
UPTIME_S=$(qs "SHOW GLOBAL STATUS LIKE 'Uptime';" | awk '{print $2}')

echo "======================================"
echo "    MARIADB TELEMETRY AUDIT REPORT (v3)"
echo "======================================"
echo "Host    : $(hostname -f 2>/dev/null || hostname)"
echo "Date    : $(date -Is)"
echo "Server  : $(qs "SELECT @@version;")   pid=${MPID:-unknown}   datadir=$DATADIR"

# ---------------------------------------------------------------------------
echo -e "\n[1. CPU & LOAD]"
echo "CPUs (nproc): $(nproc)"
lscpu 2>/dev/null | grep -E '^(CPU\(s\)|Thread|Core|Socket|Model name)' || true
echo "loadavg     : $(cat /proc/loadavg)"

# ---------------------------------------------------------------------------
echo -e "\n[2. MEMORY (machine-parseable)]"
free -m
echo "MemTotal_kB   : $(awk '/MemTotal/{print $2}' /proc/meminfo)"
echo "CommitLimit_kB: $(awk '/CommitLimit/{print $2}' /proc/meminfo)"
echo "Committed_kB  : $(awk '/Committed_AS/{print $2}' /proc/meminfo)"
echo "overcommit    : $(cat /proc/sys/vm/overcommit_memory 2>/dev/null)"
echo "swappiness    : $(cat /proc/sys/vm/swappiness 2>/dev/null)"
echo "THP enabled   : $(cat /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null)"

echo -e "\n[3. TOP MEMORY CONSUMERS (RSS, full command)]"
ps -eo user,pid,pcpu,pmem,rss,args --sort=-rss 2>/dev/null \
  | awk 'NR==1{print;next} NR<=7{printf "%-9s %-7s %-5s %-5s %-9s %s\n",$1,$2,$3,$4,$5/1024"MB",$6" "$7}'

echo -e "\n[4. SWAP — state + active rate]"
swapon --show 2>/dev/null
echo "--- vmstat si/so over 3s (nonzero si/so = swapping NOW) ---"
vmstat 1 3
echo "--- cumulative ---"
vmstat -s | grep -i swap

# ---------------------------------------------------------------------------
echo -e "\n[5. STORAGE BACKING DATADIR (drives innodb_io_capacity / flush_method)]"
findmnt -no SOURCE,FSTYPE,TARGET --target "$DATADIR" 2>/dev/null
echo "rotational per disk (0 = SSD/NVMe, 1 = HDD):"
for d in /sys/block/*/queue/rotational; do
    [ -e "$d" ] || continue
    echo "  $(echo "$d" | cut -d/ -f4): $(cat "$d")"
done
lsblk -d -o NAME,ROTA,TYPE,SIZE,MODEL 2>/dev/null
echo "--- iostat (await + %util under load -> safe io_capacity ceiling) ---"
if command -v iostat >/dev/null 2>&1; then
    iostat -dxm 1 5
else
    echo "  iostat MISSING. Install sysstat: apt-get install -y sysstat"
    echo "  WITHOUT THIS, innodb_io_capacity CANNOT be tuned safely."
fi

# ---------------------------------------------------------------------------
echo -e "\n[6. TOPOLOGY & REPLICATION (MariaDB multi-source aware)]"
q "SHOW GLOBAL VARIABLES WHERE Variable_name IN
   ('read_only','super_read_only','log_bin','log_slave_updates',
    'wsrep_on','wsrep_cluster_address','gtid_strict_mode','server_id');"
echo "--- SHOW ALL SLAVES STATUS (vertical) ---"
q "SHOW ALL SLAVES STATUS\G" | grep -E \
  "Connection_name|Master_Host|Slave_IO_Running|Slave_SQL_Running|Seconds_Behind_Master|Last_.*Error|Relay_Log_Space|Using_Gtid|Parallel_Mode"
echo "--- SHOW MASTER STATUS (empty if log_bin=OFF, expected on a replica) ---"
q "SHOW MASTER STATUS;"

# ---------------------------------------------------------------------------
echo -e "\n[7. ACTIVE CONFIG — sizing + durability + threads]"
q "SHOW GLOBAL VARIABLES WHERE Variable_name IN (
    'version','innodb_buffer_pool_size','innodb_buffer_pool_instances',
    'innodb_buffer_pool_chunk_size','innodb_log_buffer_size',
    'innodb_log_file_size','innodb_log_files_in_group',
    'innodb_flush_log_at_trx_commit','sync_binlog','innodb_flush_method',
    'innodb_flush_neighbors','innodb_io_capacity','innodb_io_capacity_max',
    'innodb_read_io_threads','innodb_write_io_threads',
    'max_connections','thread_cache_size','table_open_cache','table_definition_cache',
    'slave_parallel_threads','slave_parallel_mode',
    'query_cache_type','query_cache_size','performance_schema');"

echo -e "\n[7b. PER-CONNECTION BUFFERS (compute EXACT per-thread footprint)]"
echo "    worst-case per conn ~= sort + read + read_rnd + join + thread_stack + net + binlog_cache"
q "SHOW GLOBAL VARIABLES WHERE Variable_name IN (
    'sort_buffer_size','read_buffer_size','read_rnd_buffer_size','join_buffer_size',
    'thread_stack','net_buffer_length','max_allowed_packet','binlog_cache_size',
    'tmp_table_size','max_heap_table_size','key_buffer_size','bulk_insert_buffer_size');"

# ---------------------------------------------------------------------------
echo -e "\n[8. CONNECTION WORKLOAD]"
q "SHOW GLOBAL STATUS WHERE Variable_name IN (
    'Uptime','Max_used_connections','Max_used_connections_time',
    'Threads_connected','Threads_running','Threads_created','Connections',
    'Aborted_clients','Aborted_connects','Slow_queries');"
if [ -n "$UPTIME_S" ] && [ "$UPTIME_S" -lt 604800 ]; then
    echo ">>> UPTIME CONFIDENCE: LOW — uptime ${UPTIME_S}s < 7 days."
    echo ">>> Workload counters above/below are WARM-UP data, not steady state."
    echo ">>> Do NOT size max_connections or caches from these numbers alone."
else
    echo ">>> UPTIME CONFIDENCE: OK (>= 7 days of counters)."
fi

echo -e "\n[9. EFFICIENCY COUNTERS (validate cache/tmp/sort sizing decisions)]"
q "SHOW GLOBAL STATUS WHERE Variable_name IN (
    'Innodb_buffer_pool_read_requests','Innodb_buffer_pool_reads',
    'Innodb_buffer_pool_wait_free','Innodb_buffer_pool_pages_total',
    'Innodb_buffer_pool_pages_free','Innodb_buffer_pool_pages_dirty',
    'Open_tables','Open_table_definitions','Opened_tables','Opened_table_definitions',
    'Table_open_cache_hits','Table_open_cache_misses','Table_open_cache_overflows',
    'Created_tmp_tables','Created_tmp_disk_tables','Sort_merge_passes',
    'Handler_read_rnd_next','Innodb_row_lock_waits','Innodb_row_lock_time_avg',
    'Innodb_log_waits','Innodb_os_log_written');"

# ---------------------------------------------------------------------------
echo -e "\n[10. INNODB STATE (memory + redo/checkpoint window)]"
INNODB=$(q "SHOW ENGINE INNODB STATUS\G")
echo "$INNODB" | sed -n '/BUFFER POOL AND MEMORY/,/ROW OPERATIONS/p'
echo "--- LOG / checkpoint ---"
echo "$INNODB" | sed -n '/^LOG$/,/^BUFFER POOL AND MEMORY/p'
DICT_BYTES=$(echo "$INNODB" | awk '/Dictionary memory allocated/{print $4}')
echo "Dictionary_memory_MiB: $(awk -v b="${DICT_BYTES:-0}" 'BEGIN{printf "%.1f", b/1048576}')"
echo ">>> Trend this value across audits. On instances with many tables it grows"
echo ">>> toward the table working set and is NOT bounded by the buffer pool."

# ---------------------------------------------------------------------------
echo -e "\n[11. ACTUAL ALLOCATIONS via performance_schema (best-effort)]"
if [ "$(qs "SELECT @@performance_schema;")" = "1" ]; then
    q "SELECT SUBSTRING_INDEX(event_name,'/',2) AS area,
              ROUND(SUM(current_number_of_bytes_used)/1024/1024,1) AS MiB
       FROM performance_schema.memory_summary_global_by_event_name
       WHERE current_number_of_bytes_used > 0
       GROUP BY area ORDER BY MiB DESC LIMIT 15;"
else
    echo "  performance_schema=OFF — memory instrumentation unavailable."
fi

# ---------------------------------------------------------------------------
echo -e "\n[12. SERVER FILE-DESCRIPTOR LIMIT]"
if [ -n "$MPID" ] && [ -r "/proc/$MPID/limits" ]; then
    grep -i 'open files' "/proc/$MPID/limits"
else
    echo "  mysqld pid not found / not readable — check with: cat /proc/<pid>/limits"
fi

# ---------------------------------------------------------------------------
echo -e "\n[13. SCHEMA SCALE (table-cache memory cost driver — v3)]"
echo "    table_open_cache/table_definition_cache raises MUST be budgeted as"
echo "    cache_size x ~50-100 KiB + projected dictionary growth vs this count."
q "SELECT COUNT(*) AS total_tables,
          SUM(engine='InnoDB') AS innodb_tables,
          SUM(engine IS NOT NULL AND engine <> 'InnoDB') AS other_engine_tables,
          COUNT(DISTINCT table_schema) AS schemas
   FROM information_schema.tables
   WHERE table_schema NOT IN ('mysql','information_schema','performance_schema','sys');"
q "SELECT COUNT(*) AS total_partitions
   FROM information_schema.partitions
   WHERE table_schema NOT IN ('mysql','information_schema','performance_schema','sys')
     AND partition_name IS NOT NULL;"

# ---------------------------------------------------------------------------
echo -e "\n[14. KERNEL OOM HISTORY (v3 — has this box already hit the wall?)]"
OOM_LINES=$( (journalctl -k --no-pager 2>/dev/null || dmesg 2>/dev/null) \
             | grep -iE "out of memory|oom-kill|killed process" | tail -n 10 )
if [ -n "$OOM_LINES" ]; then
    echo "$OOM_LINES"
    echo ">>> PRIOR OOM EVENTS DETECTED. Any tuning MUST reduce, not grow, the"
    echo ">>> worst-case footprint until the cause is identified and budgeted."
else
    echo "  No OOM events found in kernel log (current boot / retained journal)."
fi

echo -e "\n[END OF REPORT]"
