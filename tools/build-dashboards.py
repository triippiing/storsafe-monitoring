#!/usr/bin/env python3
"""Generates the Grafana dashboards in monitoring/dashboards/:
Fleet, Activity, Instance, Patch management, Events. Re-run after changing metrics or layout."""
import json, os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT_DIR = os.path.join(ROOT, 'monitoring', 'dashboards')
DS = {"type": "prometheus", "uid": "${datasource}"}
REFS = "ABCDEFGHIJKLMNOP"
INSTANCE_URL = "/d/storsafe-instance/storsafe-instance?var-server=${__data.fields.server}"
OKFAIL = [{"type": "value", "options": {"1": {"text": "OK", "color": "green"}, "0": {"text": "FAIL", "color": "red"}}}]
YESNO = [{"type": "value", "options": {"1": {"text": "Yes", "color": "red"}, "0": {"text": "No", "color": "green"}}}]
GREEN_RED = [{"color": "green", "value": None}, {"color": "red", "value": 1}]
RED_GREEN = [{"color": "red", "value": None}, {"color": "green", "value": 1}]
BLUE = [{"color": "blue", "value": None}]
STATE_COLORS = [
    {"type": "regex", "options": {"pattern": ".*(error|fail|stopped|suspended|offline|incomplete|cancel).*", "result": {"color": "red"}}},
    {"type": "regex", "options": {"pattern": ".*(running|deduplicating|repli|preparing|queued|pending|waiting|scanning).*", "result": {"color": "orange"}}},
    {"type": "regex", "options": {"pattern": "^(idle|completed|online|normal|notconfigured|empty|loaded|ready)$", "result": {"color": "green"}}},
]


class Dashboard:
    def __init__(self, title, uid, server_filter, server_var, time_from="now-24h", refresh="1m", description=""):
        self.title, self.uid, self.S, self.server_var = title, uid, server_filter, server_var
        self.time_from, self.refresh, self.description = time_from, refresh, description
        self.panels, self._id, self._y, self._x, self._h = [], 0, 0, 0, 0

    def nid(self):
        self._id += 1
        return self._id

    def place(self, w, h):
        if self._x + w > 24:
            self._y += self._h
            self._x, self._h = 0, 0
        pos = {"h": h, "w": w, "x": self._x, "y": self._y}
        self._x += w
        self._h = max(self._h, h)
        return pos

    def row(self, title, collapsed=False):
        self._y += self._h
        self._x, self._h = 0, 0
        self.panels.append({"type": "row", "title": title, "id": self.nid(), "collapsed": collapsed,
                            "gridPos": {"h": 1, "w": 24, "x": 0, "y": self._y}, "panels": []})
        self._y += 1

    def target(self, expr, ref, legend=None, table=False):
        t = {"datasource": DS, "refId": ref, "expr": expr}
        if legend:
            t["legendFormat"] = legend
        if table:
            t.update({"format": "table", "instant": True})
        return t

    def text(self, title, content, w=24, h=3):
        self.panels.append({"type": "text", "title": title, "id": self.nid(), "gridPos": self.place(w, h),
                            "options": {"mode": "markdown", "content": content}})

    def ts(self, title, exprs, unit=None, w=12, h=8, stack=False, bars=False, desc=None, legend_right=True, min0=True):
        defaults = {"custom": {"fillOpacity": 80 if bars else 15, "lineWidth": 1, "showPoints": "never"}}
        if stack:
            defaults["custom"]["stacking"] = {"mode": "normal"}
        if bars:
            defaults["custom"]["drawStyle"] = "bars"
        if unit:
            defaults["unit"] = unit
        if min0:
            defaults["min"] = 0
        legend = {"displayMode": "table", "placement": "right", "calcs": ["lastNotNull"]} if legend_right else {"displayMode": "list", "placement": "bottom"}
        p = {"type": "timeseries", "title": title, "id": self.nid(), "datasource": DS, "gridPos": self.place(w, h),
             "targets": [self.target(e, REFS[i], l) for i, (e, l) in enumerate(exprs)],
             "fieldConfig": {"defaults": defaults, "overrides": []}, "options": {"legend": legend, "tooltip": {"mode": "multi", "sort": "desc"}}}
        if desc:
            p["description"] = desc
        self.panels.append(p)

    def stat(self, title, exprs, unit=None, w=4, h=4, mappings=None, thresholds=None, desc=None, decimals=None, links=None, sparkline=False, text_mode=None):
        defaults = {"color": {"mode": "thresholds"}, "thresholds": {"mode": "absolute", "steps": thresholds or BLUE}}
        if unit:
            defaults["unit"] = unit
        if mappings:
            defaults["mappings"] = mappings
        if decimals is not None:
            defaults["decimals"] = decimals
        if links:
            defaults["links"] = links
        p = {"type": "stat", "title": title, "id": self.nid(), "datasource": DS, "gridPos": self.place(w, h),
             "targets": [self.target(e, REFS[i], l) for i, (e, l) in enumerate(exprs)],
             "fieldConfig": {"defaults": defaults, "overrides": []},
             "options": {"reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": False},
                         "colorMode": "background", "graphMode": "area" if sparkline else "none",
                         "textMode": text_mode or ("value_and_name" if len(exprs) > 1 or "{{" in (exprs[0][1] or "") else "value"), "wideLayout": True}}
        if desc:
            p["description"] = desc
        self.panels.append(p)

    def table(self, title, exprs, rename=None, units=None, hide=None, w=24, h=8, sort=None, desc=None, merge=True,
              order=None, color_cols=None, links=None, bool_cols=None, bar_cols=None, filterable=False, hide_time=True):
        """exprs: list of PromQL (table format, instant). Value columns are 'Value #<ref>' (or 'Value' for one query);
        rename maps ref -> column name (None drops the column). order lists column names first-to-last."""
        exclude = {"__name__": True, "instance": True, "job": True}
        if hide_time:
            exclude["Time"] = True
        for x in (hide or []):
            exclude[x] = True
        ren = {}
        for ref, name in (rename or {}).items():
            col = "Value #%s" % ref if len(exprs) > 1 else "Value"
            if name is None:
                exclude[col] = True
            else:
                ren[col] = name
        overrides = []
        for name, unit in (units or {}).items():
            overrides.append({"matcher": {"id": "byName", "options": name}, "properties": [{"id": "unit", "value": unit}]})
        for name in (color_cols or []):
            overrides.append({"matcher": {"id": "byName", "options": name}, "properties": [
                {"id": "custom.cellOptions", "value": {"type": "color-text"}}, {"id": "mappings", "value": STATE_COLORS}]})
        for name in (bool_cols or []):
            overrides.append({"matcher": {"id": "byName", "options": name}, "properties": [
                {"id": "custom.cellOptions", "value": {"type": "color-text"}}, {"id": "mappings", "value": OKFAIL}]})
        for name, (lo, hi) in (bar_cols or {}).items():
            overrides.append({"matcher": {"id": "byName", "options": name}, "properties": [
                {"id": "custom.cellOptions", "value": {"type": "gauge", "mode": "basic"}}, {"id": "min", "value": lo}, {"id": "max", "value": hi},
                {"id": "thresholds", "value": {"mode": "absolute", "steps": [{"color": "green", "value": None}, {"color": "orange", "value": 80}, {"color": "red", "value": 90}]}}]})
        if links:
            overrides.append({"matcher": {"id": "byName", "options": "server"}, "properties": [{"id": "links", "value": links}]})
        tr = []
        if merge and len(exprs) > 1:
            # Merge joins rows only when every shared column matches. Raw series carry __name__ (which differs per
            # query) and Time, so drop both first or the rows from each query land one under the other.
            tr.append({"id": "filterFieldsByName", "options": {"exclude": {"pattern": "^(__name__|Time)$"}}})
            tr.append({"id": "merge", "options": {}})
        org = {"excludeByName": exclude, "renameByName": ren}
        if order:
            org["indexByName"] = {name: i for i, name in enumerate(order)}
        tr.append({"id": "organize", "options": org})
        if sort:
            tr.append({"id": "sortBy", "options": {"sort": [{"field": sort[0], "desc": sort[1]}]}})
        p = {"type": "table", "title": title, "id": self.nid(), "datasource": DS, "gridPos": self.place(w, h),
             "targets": [self.target(e, REFS[i], table=True) for i, e in enumerate(exprs)],
             "fieldConfig": {"defaults": {"custom": {"filterable": filterable}}, "overrides": overrides},
             "options": {"showHeader": True, "cellHeight": "sm", "footer": {"show": False}}, "transformations": tr}
        if desc:
            p["description"] = desc
        self.panels.append(p)

    def build(self):
        variables = [{"name": "datasource", "type": "datasource", "query": "prometheus", "label": "Data source",
                      "current": {"text": "StorSafe Prometheus", "value": "storsafe-prometheus"}}]
        if self.server_var == "multi":
            variables.append({"name": "server", "type": "query", "datasource": DS, "query": {"query": "label_values(storsafe_up, server)", "refId": "A"},
                              "definition": "label_values(storsafe_up, server)", "includeAll": True, "multi": True, "sort": 1,
                              "current": {"text": "All", "value": "$__all"}, "refresh": 2, "label": "Server"})
        elif self.server_var == "single":
            variables.append({"name": "server", "type": "query", "datasource": DS, "query": {"query": "label_values(storsafe_up, server)", "refId": "A"},
                              "definition": "label_values(storsafe_up, server)", "includeAll": False, "multi": False, "sort": 1,
                              "refresh": 2, "label": "Server"})
        return {
            "title": self.title, "uid": self.uid, "schemaVersion": 39, "version": 1, "editable": True, "graphTooltip": 1,
            "refresh": self.refresh, "time": {"from": self.time_from, "to": "now"}, "tags": ["storsafe"], "description": self.description,
            "links": [{"title": "StorSafe dashboards", "type": "dashboards", "tags": ["storsafe"], "asDropdown": False, "includeVars": True, "keepTime": True}],
            "templating": {"list": variables}, "panels": self.panels,
        }


def write(d):
    path = os.path.join(OUT_DIR, d.uid + ".json")
    with open(path, 'w') as f:
        json.dump(d.build(), f, indent=2)
    print("%-28s %3d panels  %s" % (d.title, sum(1 for p in d.panels if p['type'] != 'row'), path))


# ============================================================================ Fleet
def fleet():
    S = 'server=~"$server"'
    d = Dashboard("StorSafe Fleet", "storsafe-fleet", S, "multi", description="One row per appliance; red rows need attention. Click a server name to open its Instance page.")
    d.row("Estate")
    d.stat("Appliances", [(f'count(storsafe_up{{{S}}})', None)], w=3)
    d.stat("API down", [(f'count(storsafe_up{{{S}}} == 0) or vector(0)', None)], w=3, thresholds=GREEN_RED)
    d.stat("Failed checks", [(f'count(storsafe_check_success{{{S}}} == 0) or vector(0)', None)], w=3, thresholds=GREEN_RED)
    d.stat("Failover not normal", [(f'count(storsafe_failover_healthy{{{S}}} == 0) or vector(0)', None)], w=3, thresholds=GREEN_RED)
    d.stat("LUNs / repo devices offline", [(f'(count(storsafe_physicaldevice_online{{{S}}} == 0) or vector(0)) + (count(storsafe_dedupe_repository_disk_online{{{S}}} == 0) or vector(0))', None)], w=3, thresholds=GREEN_RED)
    d.stat("Errors + criticals, 24h", [(f'sum(increase(storsafe_events_total{{{S},severity=~"error|critical"}}[24h])) or vector(0)', None)], w=3, thresholds=GREEN_RED, decimals=0)
    d.stat("Warnings, 24h", [(f'sum(increase(storsafe_events_total{{{S},severity="warning"}}[24h])) or vector(0)', None)], w=3, decimals=0,
           thresholds=[{"color": "green", "value": None}, {"color": "orange", "value": 1}])
    d.stat("Collector last run", [(f'time() - storsafe_collector_last_run_timestamp_seconds', None)], "s", w=3,
           thresholds=[{"color": "green", "value": None}, {"color": "orange", "value": 600}, {"color": "red", "value": 900}], desc="Time since the collector last completed a full run.")

    d.row("Appliances")
    d.table("Fleet status", [
        f'max by (server) (storsafe_up{{{S}}})',
        f'sum by (server) (1 - storsafe_check_success{{{S}}})',
        f'max by (server) (storsafe_failover_healthy{{{S}}})',
        f'100 * sum by (server) (storsafe_storagepool_used_bytes{{{S}}}) / sum by (server) (storsafe_storagepool_size_bytes{{{S}}})',
        f'sum by (server) (1 - storsafe_physicaldevice_online{{{S}}}) + (sum by (server) (1 - storsafe_dedupe_repository_disk_online{{{S}}}) or 0 * max by (server) (storsafe_up{{{S}}}))',
        f'sum by (server) (storsafe_dedupe_24h_scanned_bytes{{{S}}}) / sum by (server) (storsafe_dedupe_24h_unique_bytes{{{S}}} > 0)',
        f'max by (server) (storsafe_dedupe_queue_jobs_total{{{S}}})',
        f'sum by (server) (storsafe_replication_queue_jobs_total{{{S}}})',
        f'sum by (server) (increase(storsafe_events_total{{{S},severity=~"error|critical"}}[24h]))',
        f'sum by (server) (increase(storsafe_events_total{{{S},severity="warning"}}[24h]))',
        f'min by (server) (time() - storsafe_replica_newest_replicated_timestamp_seconds{{{S}}})',
        f'max by (server) (abs(storsafe_time_offset_seconds{{{S}}}))',
        f'max by (server, version, build) (storsafe_info{{{S}}})',
    ], rename={"A": "API", "B": "Failed checks", "C": "Failover OK", "D": "Pool used %", "E": "Devices offline", "F": "Dedupe ratio 24h", "G": "Dedupe queue",
               "H": "Repl queue", "I": "Err+crit 24h", "J": "Warn 24h", "K": "Newest replica age", "L": "Clock offset", "M": None},
        units={"Newest replica age": "s", "Clock offset": "s", "Dedupe ratio 24h": "none"}, bool_cols=["API", "Failover OK"], bar_cols={"Pool used %": (0, 100)},
        order=["server", "API", "Failed checks", "Failover OK", "Devices offline", "Pool used %", "Dedupe ratio 24h", "Dedupe queue", "Repl queue", "Err+crit 24h", "Warn 24h", "Newest replica age", "Clock offset", "version", "build"],
        sort=("Failed checks", True), h=16, links=[{"title": "Open instance", "url": INSTANCE_URL}], filterable=True,
        desc="Dedupe ratio = scanned / unique over completed runs in the last 24 h. Devices offline counts LUNs and repository devices. Newest replica age is the time since the most recently updated replica tape on that appliance.")

    d.row("Trends")
    d.ts("Pool used %", [(f'100 * sum by (server) (storsafe_storagepool_used_bytes{{{S}}}) / sum by (server) (storsafe_storagepool_size_bytes{{{S}}})', "{{server}}")], "percent", w=12)
    d.ts("Errors and criticals per hour", [(f'sum by (server) (increase(storsafe_events_total{{{S},severity=~"error|critical"}}[1h]))', "{{server}}")], "none", w=12, bars=True, stack=True)
    d.ts("Dedupe queue depth", [(f'storsafe_dedupe_queue_jobs_total{{{S}}}', "{{server}}")], "none", w=12)
    d.ts("Replication queue depth", [(f'sum by (server) (storsafe_replication_queue_jobs_total{{{S}}})', "{{server}}")], "none", w=12)
    write(d)


# ============================================================================ Activity
def activity():
    S = 'server=~"$server"'
    d = Dashboard("StorSafe Activity", "storsafe-activity", S, "multi", refresh="30s", description="Live jobs across the estate: deduplication, replication and repository maintenance.")
    d.row("Now")
    d.stat("Dedupe jobs active", [(f'count(storsafe_dedupe_job_info{{{S},state=~"deduplicating|indexrepli|uniquereplicating|preparing.*|pending"}}) or vector(0)', None)], w=4)
    d.stat("Dedupe jobs queued", [(f'count(storsafe_dedupe_job_info{{{S},state=~"queued|tapeindrive|uniquerepliqueued"}}) or vector(0)', None)], w=4)
    d.stat("Dedupe jobs paused / suspended", [(f'count(storsafe_dedupe_job_info{{{S},state=~"paused|suspended|stopping"}}) or vector(0)', None)], w=4, thresholds=[{"color": "green", "value": None}, {"color": "orange", "value": 1}])
    d.stat("Replication jobs running", [(f'count(storsafe_replication_job_info{{{S},state="running"}}) or vector(0)', None)], w=4)
    d.stat("Replication jobs waiting", [(f'count(storsafe_replication_job_info{{{S},state=~"waiting.*"}}) or vector(0)', None)], w=4, thresholds=[{"color": "green", "value": None}, {"color": "orange", "value": 1}])
    d.stat("Reclamation / prune running", [(f'count(storsafe_dedupe_maintenance_status{{{S},status="running"}}) or vector(0)', None)], w=4)

    d.row("Deduplication jobs")
    d.table("Dedupe jobs", [
        f'storsafe_dedupe_job_info{{{S}}}',
        f'storsafe_dedupe_job_progress_percent{{{S}}}',
        f'storsafe_dedupe_job_throughput_bytes_per_second{{{S}}}',
        f'storsafe_dedupe_job_scanned_bytes{{{S}}}',
        f'storsafe_dedupe_job_data_bytes{{{S}}}',
        f'storsafe_dedupe_job_undeduped_bytes{{{S}}}',
        f'storsafe_dedupe_job_first_seen_timestamp_seconds{{{S}}} * 1000',
    ], rename={"A": None, "B": "Progress %", "C": "Throughput", "D": "Scanned", "E": "Tape data", "F": "Un-deduped", "G": "First seen"},
        units={"Throughput": "Bps", "Scanned": "bytes", "Tape data": "bytes", "Un-deduped": "bytes", "First seen": "dateTimeAsIso"},
        bar_cols={"Progress %": (0, 100)}, color_cols=["state"], hide=["destination_drive"],
        order=["server", "policy", "barcode", "tape", "state", "drive", "Progress %", "Throughput", "Scanned", "Tape data", "Un-deduped", "First seen", "trigger", "replicationmode", "parser"],
        sort=("First seen", False), h=12, filterable=True, links=[{"title": "Open instance", "url": INSTANCE_URL}],
        desc="One row per tape in a deduplication queue. 'First seen' is when the collector first saw the job (the API has no start time; accurate to one collector interval). 'drive' is the drive the tape is being read from.")
    d.ts("Dedupe throughput by appliance", [(f'sum by (server) (storsafe_dedupe_job_throughput_bytes_per_second{{{S}}})', "{{server}}")], "Bps", w=12, h=7)
    d.ts("Dedupe jobs by state", [(f'count by (state) (storsafe_dedupe_job_info{{{S}}})', "{{state}}")], "none", w=12, h=7, stack=True)

    d.row("Replication jobs")
    d.table("Replication jobs", [
        f'storsafe_replication_job_info{{{S}}}',
        f'storsafe_replication_job_progress_percent{{{S}}}',
        f'storsafe_replication_job_throughput_bytes_per_second{{{S}}}',
        f'storsafe_replication_job_transmitted_bytes{{{S}}}',
        f'storsafe_replication_job_total_bytes{{{S}}}',
        f'storsafe_replication_job_remaining_seconds{{{S}}}',
        f'storsafe_replication_job_start_timestamp_seconds{{{S}}} * 1000',
        f'storsafe_replication_job_first_seen_timestamp_seconds{{{S}}} * 1000',
        f'storsafe_replication_job_next_retry_timestamp_seconds{{{S}}} * 1000 > 0',
        f'storsafe_replication_job_retries_left{{{S}}}',
    ], rename={"A": None, "B": "Progress %", "C": "Throughput", "D": "Transmitted", "E": "To replicate", "F": "Remaining", "G": "Started", "H": "First seen", "I": "Next retry", "J": "Retries left"},
        units={"Throughput": "Bps", "Transmitted": "bytes", "To replicate": "bytes", "Remaining": "s", "Started": "dateTimeAsIso", "First seen": "dateTimeAsIso", "Next retry": "dateTimeAsIso"},
        bar_cols={"Progress %": (0, 100)}, color_cols=["state"], hide=["targetip"],
        order=["server", "direction", "queue", "policy", "barcode", "tape", "source", "target", "state", "phase", "Progress %", "Throughput", "Transmitted", "To replicate", "Remaining", "Started", "First seen", "Next retry", "Retries left", "mode"],
        sort=("First seen", False), h=12, filterable=True, links=[{"title": "Open instance", "url": INSTANCE_URL}],
        desc="queue=dedupe: the replication leg of a deduplication job (outgoing, from the source). classic: a non-deduplicated tape (outgoing). unique: the unique-data phase as seen on the target (incoming, with the appliance's own start time). Replication uses no tape drive.")
    d.ts("Replication throughput by appliance", [(f'sum by (server) (storsafe_replication_job_throughput_bytes_per_second{{{S}}})', "{{server}}")], "Bps", w=12, h=7)
    d.ts("Replication jobs by state", [(f'count by (state) (storsafe_replication_job_info{{{S}}})', "{{state}}")], "none", w=12, h=7, stack=True)

    d.row("Repository maintenance (space reclamation and index pruning)")
    d.table("Reclamation and pruning running now", [
        f'storsafe_dedupe_maintenance_status{{{S},status="running"}} == 1',
        f'storsafe_dedupe_maintenance_running_since_timestamp_seconds{{{S}}} * 1000 > 0',
    ], rename={"A": None, "B": "Running since"}, units={"Running since": "dateTimeAsIso"},
        color_cols=["status"], order=["server", "process", "status", "Running since"],
        sort=("Running since", False), w=12, h=8, filterable=True, links=[{"title": "Open instance", "url": INSTANCE_URL}],
        desc="Only jobs with status 'running' are listed; the table is empty when no reclamation or prune is in progress. 'Running since' is when the collector first saw the run (the API gives only idle/running/failed, no start time or space figures).")
    d.table("Reclamation policy", [f'storsafe_reclamation_schedule_info{{{S}}}', f'storsafe_reclamation_policy_enabled{{{S},trigger="usage"}}',
                                   f'storsafe_reclamation_policy_enabled{{{S},trigger="schedule"}}', f'storsafe_reclamation_usage_check_interval_seconds{{{S}}}'],
            rename={"A": None, "B": "Usage trigger", "C": "Scheduled", "D": "Usage check every"}, units={"Usage check every": "s"}, hide=["trigger"],
            order=["server", "Usage trigger", "Usage check every", "Scheduled", "weekdays", "starttime"], w=12, h=8, bool_cols=["Usage trigger", "Scheduled"])
    d.ts("Reclamation / prune running (history)", [(f'count by (server, process) (storsafe_dedupe_maintenance_status{{{S},status="running"}})', "{{server}} {{process}}")], "none", w=24, h=7, bars=True)

    d.row("Policy runs and import/export")
    d.table("Latest policy run per appliance", [
        f'storsafe_dedupe_run_last_status{{{S}}} == 1',
        f'storsafe_dedupe_run_last_timestamp_seconds{{{S}}} * 1000',
        f'storsafe_dedupe_completed_run_ratio{{{S}}}',
        f'storsafe_dedupe_completed_run_scanned_bytes{{{S}}}',
        f'storsafe_dedupe_completed_run_unique_bytes{{{S}}}',
        f'storsafe_dedupe_completed_run_duration_seconds{{{S}}}',
        f'storsafe_dedupe_runs_24h{{{S},status="failed"}}',
    ], rename={"A": None, "B": "Last run", "C": "Ratio (completed)", "D": "Scanned", "E": "Unique", "F": "Duration", "G": "Failed runs 24h"},
        units={"Last run": "dateTimeAsIso", "Scanned": "bytes", "Unique": "bytes", "Duration": "s"}, color_cols=["status"], hide=["status_1"],
        order=["server", "policy", "status", "trigger", "Last run", "Ratio (completed)", "Scanned", "Unique", "Duration", "Failed runs 24h"],
        sort=("Last run", True), w=14, h=10, filterable=True, desc="Ratio, scanned, unique and duration are from the most recent completed run; status and trigger are from the most recent run of any status.")
    d.table("Import/export jobs", [f'storsafe_iejob_jobs_by_type{{{S}}} > 0'], rename={"A": "Jobs"}, color_cols=["status"], w=10, h=10, sort=("Jobs", True))
    write(d)


# ============================================================================ Instance
def instance():
    S = 'server="$server"'
    d = Dashboard("StorSafe Instance", "storsafe-instance", S, "single", description="Everything about one appliance. Pick the server at the top.")
    d.row("Health")
    d.stat("API", [(f'storsafe_up{{{S}}}', None)], w=3, mappings=OKFAIL, thresholds=RED_GREEN)
    d.stat("Failover", [(f'storsafe_failover_status{{{S}}} == 1', "{{status}}")], w=3, thresholds=BLUE)
    d.stat("Failed checks", [(f'count(storsafe_check_success{{{S}}} == 0) or vector(0)', None)], w=3, thresholds=GREEN_RED)
    d.stat("LUNs offline", [(f'count(storsafe_physicaldevice_online{{{S}}} == 0) or vector(0)', None)], w=3, thresholds=GREEN_RED)
    d.stat("Repo devices offline", [(f'count(storsafe_dedupe_repository_disk_online{{{S}}} == 0) or vector(0)', None)], w=3, thresholds=GREEN_RED)
    d.stat("Errors + criticals, 24h", [(f'sum(increase(storsafe_events_total{{{S},severity=~"error|critical"}}[24h])) or vector(0)', None)], w=3, thresholds=GREEN_RED, decimals=0)
    d.stat("Clock offset", [(f'storsafe_time_offset_seconds{{{S}}}', None)], "s", w=3, thresholds=[{"color": "green", "value": None}, {"color": "orange", "value": 60}])
    d.stat("Collected", [(f'time() - storsafe_check_last_success_timestamp_seconds{{{S},check="version"}}', None)], "s", w=3,
           thresholds=[{"color": "green", "value": None}, {"color": "orange", "value": 600}, {"color": "red", "value": 900}], desc="Time since this appliance was last collected.")
    d.table("Appliance", [f'storsafe_info{{{S}}}', f'storsafe_server_info{{{S}}}', f'storsafe_server_memory_bytes{{{S}}}', f'storsafe_server_cpus{{{S}}}'],
            rename={"A": None, "B": None, "C": "Memory", "D": "CPUs"}, units={"Memory": "bytes"}, hide=["description", "cloud", "virtual", "kernel"], h=4,
            order=["server", "hostname", "product", "version", "build", "role", "make", "model", "osversion", "Memory", "CPUs", "location"])

    d.row("Capacity")
    d.stat("Pool used", [(f'100 * sum(storsafe_storagepool_used_bytes{{{S}}}) / sum(storsafe_storagepool_size_bytes{{{S}}})', None)], "percent", w=4, decimals=1,
           thresholds=[{"color": "green", "value": None}, {"color": "orange", "value": 80}, {"color": "red", "value": 90}])
    d.stat("Pool free", [(f'sum(storsafe_storagepool_size_bytes{{{S}}}) - sum(storsafe_storagepool_used_bytes{{{S}}})', None)], "bytes", w=4)
    d.stat("Days until full (30d trend)", [(f'(sum(storsafe_storagepool_size_bytes{{{S}}}) - sum(storsafe_storagepool_used_bytes{{{S}}})) / clamp_min(deriv(sum(storsafe_storagepool_used_bytes{{{S}}})[30d:1h]), 1) / 86400', None)], "d", w=4, decimals=0,
           thresholds=[{"color": "red", "value": None}, {"color": "orange", "value": 30}, {"color": "green", "value": 90}], desc="Free space divided by the 30-day growth rate. Shows a very large number while usage is flat or falling; needs several days of data to settle.")
    d.stat("Alert threshold", [(f'storsafe_storage_threshold_percent{{{S}}}', None)], "percent", w=4)
    d.stat("Virtualized disk used", [(f'100 * storsafe_virtualized_disk_used_bytes{{{S}}} / storsafe_virtualized_disk_size_bytes{{{S}}}', None)], "percent", w=4, decimals=1,
           thresholds=[{"color": "green", "value": None}, {"color": "orange", "value": 80}, {"color": "red", "value": 90}])
    d.stat("Repository", [(f'storsafe_dedupe_repository_info{{{S}}}', "{{type}} {{mode}} {{nodetype}}")], w=4, thresholds=BLUE)
    d.ts("Storage pool used", [(f'storsafe_storagepool_used_bytes{{{S}}}', "{{pool}} used"), (f'storsafe_storagepool_size_bytes{{{S}}}', "{{pool}} size")], "bytes", w=12)
    d.ts("Virtualized disk", [(f'storsafe_virtualized_disk_used_bytes{{{S}}}', "used"), (f'storsafe_virtualized_disk_size_bytes{{{S}}}', "size")], "bytes", w=12)
    d.table("LUNs", [f'storsafe_physicaldevice_online{{{S}}}', f'storsafe_physicaldevice_size_bytes{{{S}}}', f'storsafe_physicaldevice_used_bytes{{{S}}}'],
            rename={"A": "Online", "B": "Size", "C": "Used"}, units={"Size": "bytes", "Used": "bytes"}, bool_cols=["Online"], sort=("Online", False), w=12, h=8)
    d.table("Repository devices", [f'storsafe_dedupe_repository_disk_online{{{S}}}', f'storsafe_dedupe_repository_disk_size_bytes{{{S}}}'],
            rename={"A": "Online", "B": "Size"}, units={"Size": "bytes"}, bool_cols=["Online"], sort=("Online", False), w=12, h=8)

    d.row("Deduplication")
    d.table("Policies", [f'storsafe_dedupe_policy_status{{{S}}} == 1', f'storsafe_dedupe_policy_tapes{{{S}}}', f'storsafe_dedupe_policy_suspended{{{S}}}',
                         f'storsafe_dedupe_policy_last_run_timestamp_seconds{{{S}}} * 1000 > 0', f'storsafe_dedupe_policy_next_run_timestamp_seconds{{{S}}} * 1000 > 0',
                         f'storsafe_dedupe_completed_run_ratio{{{S}}}', f'storsafe_dedupe_runs_24h{{{S},status="failed"}}'],
            rename={"A": None, "B": "Tapes", "C": "Suspended", "D": "Last run", "E": "Next run", "F": "Ratio (last completed)", "G": "Failed runs 24h"},
            units={"Last run": "dateTimeAsIso", "Next run": "dateTimeAsIso"}, color_cols=["status"], hide=["status_1"],
            order=["server", "policy", "status", "trigger", "Tapes", "Suspended", "Last run", "Next run", "Ratio (last completed)", "Failed runs 24h"], w=14, h=8)
    d.table("Reclamation / prune", [f'storsafe_dedupe_maintenance_status{{{S}}} == 1', f'storsafe_dedupe_maintenance_running_since_timestamp_seconds{{{S}}} * 1000 > 0',
                                    f'storsafe_dedupe_maintenance_last_run_end_timestamp_seconds{{{S}}} * 1000', f'storsafe_dedupe_maintenance_last_run_duration_seconds{{{S}}}'],
            rename={"A": None, "B": "Running since", "C": "Last run ended", "D": "Last duration"}, units={"Running since": "dateTimeAsIso", "Last run ended": "dateTimeAsIso", "Last duration": "s"},
            color_cols=["status"], order=["server", "process", "status", "Running since", "Last run ended", "Last duration"], w=10, h=8,
            desc="Status from the API (idle/running/failed). Times are tracked by the collector, to one collector interval.")
    d.ts("Dedupe ratio (N:1)", [(f'storsafe_dedupe_completed_run_ratio{{{S}}}', "{{policy}} last run"), (f'storsafe_dedupe_24h_ratio{{{S}}}', "{{policy}} 24h")], "none", w=12)
    d.ts("Scanned vs unique, last 24h", [(f'storsafe_dedupe_24h_scanned_bytes{{{S}}}', "{{policy}} scanned"), (f'storsafe_dedupe_24h_unique_bytes{{{S}}}', "{{policy}} unique")], "bytes", w=12)
    d.ts("Dedupe queue", [(f'storsafe_dedupe_queue_jobs{{{S}}}', "{{state}}")], "none", w=8, stack=True)
    d.ts("Data waiting for dedupe", [(f'storsafe_dedupe_queue_undeduped_bytes{{{S}}}', "waiting")], "bytes", w=8)
    d.ts("Dedupe throughput", [(f'storsafe_dedupe_queue_throughput_bytes_per_second{{{S}}}', "dedupe"), (f'sum(storsafe_dedupe_active_replication_throughput_bytes_per_second{{{S}}})', "replication")], "Bps", w=8)
    d.table("Dedupe jobs on this appliance", [f'storsafe_dedupe_job_info{{{S}}}', f'storsafe_dedupe_job_progress_percent{{{S}}}', f'storsafe_dedupe_job_throughput_bytes_per_second{{{S}}}',
                                              f'storsafe_dedupe_job_undeduped_bytes{{{S}}}', f'storsafe_dedupe_job_first_seen_timestamp_seconds{{{S}}} * 1000'],
            rename={"A": None, "B": "Progress %", "C": "Throughput", "D": "Un-deduped", "E": "First seen"}, units={"Throughput": "Bps", "Un-deduped": "bytes", "First seen": "dateTimeAsIso"},
            bar_cols={"Progress %": (0, 100)}, color_cols=["state"], hide=["destination_drive", "parser", "replicationmode", "trigger"],
            order=["policy", "barcode", "tape", "state", "drive", "Progress %", "Throughput", "Un-deduped", "First seen"], h=8)

    d.row("Replication")
    d.stat("Classic replication", [(f'storsafe_replication_suspended{{{S}}}', None)], w=4, mappings=[{"type": "value", "options": {"0": {"text": "Normal", "color": "green"}, "1": {"text": "SUSPENDED", "color": "red"}}}], thresholds=GREEN_RED)
    d.stat("Classic queue", [(f'storsafe_replication_queue_jobs_total{{{S},queue="classic"}}', None)], w=4)
    d.stat("Unique queue", [(f'storsafe_replication_queue_jobs_total{{{S},queue="unique"}}', None)], w=4)
    d.stat("Oldest unique job age", [(f'time() - (storsafe_unique_replication_oldest_job_start_timestamp_seconds{{{S}}} > 0)', None)], "s", w=4,
           thresholds=[{"color": "green", "value": None}, {"color": "orange", "value": 21600}, {"color": "red", "value": 43200}])
    d.stat("Newest replica age", [(f'min(time() - storsafe_replica_newest_replicated_timestamp_seconds{{{S}}})', None)], "s", w=4,
           thresholds=[{"color": "green", "value": None}, {"color": "orange", "value": 86400}, {"color": "red", "value": 172800}], desc="Time since the most recently updated replica tape held here.")
    d.stat("Replicas older than 24h", [(f'sum(storsafe_replica_tapes_not_replicated_within{{{S},age="24h"}})', None)], w=4, thresholds=[{"color": "green", "value": None}, {"color": "orange", "value": 1}])
    d.table("Replication jobs on this appliance", [f'storsafe_replication_job_info{{{S}}}', f'storsafe_replication_job_progress_percent{{{S}}}', f'storsafe_replication_job_throughput_bytes_per_second{{{S}}}',
                                                   f'storsafe_replication_job_remaining_seconds{{{S}}}', f'storsafe_replication_job_first_seen_timestamp_seconds{{{S}}} * 1000'],
            rename={"A": None, "B": "Progress %", "C": "Throughput", "D": "Remaining", "E": "First seen"}, units={"Throughput": "Bps", "Remaining": "s", "First seen": "dateTimeAsIso"},
            bar_cols={"Progress %": (0, 100)}, color_cols=["state"], hide=["targetip", "mode"],
            order=["direction", "queue", "policy", "barcode", "tape", "source", "target", "state", "phase", "Progress %", "Throughput", "Remaining", "First seen"], h=8)
    d.table("Policy targets", [f'storsafe_dedupe_policy_info{{{S}}}', f'storsafe_dedupe_policy_replication_suspended{{{S}}}'], rename={"A": None, "B": "Target suspended"}, w=8, h=8)
    d.table("Replication partners", [f'storsafe_dedupe_replication_partner_info{{{S}}}'], rename={"A": None}, w=8, h=8)
    d.table("Replica tapes by source", [f'storsafe_replica_tapes{{{S}}}', f'storsafe_replica_newest_replicated_timestamp_seconds{{{S}}} * 1000', f'storsafe_replica_oldest_replicated_timestamp_seconds{{{S}}} * 1000',
                                        f'storsafe_replica_tapes_not_replicated_within{{{S},age="24h"}}', f'storsafe_replica_tapes_not_replicated_within{{{S},age="7d"}}', f'storsafe_replica_tapes_not_replicated_within{{{S},age="never"}}'],
            rename={"A": "Replicas", "B": "Newest", "C": "Oldest", "D": "> 24h", "E": "> 7d", "F": "Never"}, units={"Newest": "dateTimeAsIso", "Oldest": "dateTimeAsIso"}, hide=["age"], w=8, h=8)
    d.ts("Replication queues", [(f'storsafe_replication_queue_jobs{{{S}}}', "{{queue}} {{state}}")], "none", w=12, stack=True)
    d.ts("Replicas not updated within", [(f'storsafe_replica_tapes_not_replicated_within{{{S}}}', "{{source}} {{age}}")], "none", w=12)

    d.row("Tapes and libraries")
    d.table("Virtual libraries", [f'storsafe_vtl_slots{{{S}}}', f'storsafe_vtl_tapes{{{S}}}', f'storsafe_vtl_drives{{{S}}}', f'storsafe_vtl_loaded_drives{{{S}}}',
                                  f'storsafe_vtl_tapes_empty{{{S}}}', f'storsafe_vtl_tape_used_bytes{{{S}}}', f'storsafe_vtl_tape_size_bytes{{{S}}}'],
            rename={"A": "Slots", "B": "Tapes", "C": "Drives", "D": "Loaded", "E": "Scratch", "F": "Used", "G": "Allocated"}, units={"Used": "bytes", "Allocated": "bytes"}, w=12, h=8)
    d.table("Physical libraries and drives", [f'storsafe_physical_drive_status{{{S}}} == 1', f'storsafe_physical_drive_disabled{{{S}}}'],
            rename={"A": None, "B": "Disabled"}, color_cols=["status"], w=12, h=8)
    d.table("Tapes by location", [f'storsafe_tapes{{{S}}}', f'storsafe_tapes_empty{{{S}}}', f'storsafe_tapes_used_bytes{{{S}}}', f'storsafe_tapes_size_bytes{{{S}}}'],
            rename={"A": "Tapes", "B": "Empty", "C": "Used", "D": "Allocated"}, units={"Used": "bytes", "Allocated": "bytes"}, w=8, h=8)
    d.table("Tape status counts", [f'storsafe_tapes_by_status{{{S}}}'], rename={"A": "Tapes"}, w=8, h=8, sort=("field", False))
    d.table("Import/export jobs", [f'storsafe_iejob_jobs_by_type{{{S}}} > 0'], rename={"A": "Jobs"}, color_cols=["status"], w=8, h=8)
    d.ts("Tape data used", [(f'storsafe_tapes_used_bytes{{{S}}}', "{{location}}")], "bytes", w=12, h=7)
    d.ts("Loaded drives", [(f'storsafe_vtl_loaded_drives{{{S}}}', "{{library}}")], "none", w=12, h=7)

    d.row("Events")
    d.ts("Events per hour by severity", [(f'sum by (severity) (increase(storsafe_events_total{{{S}}}[1h]))', "{{severity}}")], "none", w=24, h=6, bars=True, stack=True)
    d.table("Recent warnings, errors and criticals", [f'storsafe_event_recent{{{S}}} * 1000'], rename={"A": "When"}, units={"When": "dateTimeAsIso"}, color_cols=["severity"],
            order=["When", "severity", "id", "message"], hide=["time", "server"], sort=("When", True), h=10, filterable=True,
            desc="The 20 newest non-informational events. The full log is archived daily under events\\ on the monitoring host.")

    d.row("Platform and network")
    d.table("Patches", [f'storsafe_patch_info{{{S}}}'], rename={"A": None}, hide=["server"], w=12, h=7)
    d.table("Network interfaces", [f'storsafe_nic_speed_mbps{{{S}}}', f'storsafe_nic_mtu{{{S}}}', f'storsafe_nic_dhcp{{{S}}}'], rename={"A": "Speed Mb/s", "B": "MTU", "C": "DHCP"}, hide=["server"], w=12, h=7)
    d.table("FC / SCSI adapters", [f'storsafe_adapter_paths{{{S}}}'], rename={"A": "Paths"}, hide=["server"], w=12, h=6)
    d.table("Options", [f'storsafe_server_option_enabled{{{S}}}', f'storsafe_encryption_option{{{S}}}'], rename={"A": "Enabled", "B": "Enabled "}, hide=["server"], w=6, h=6, merge=False)
    d.table("Failover setup", [f'storsafe_failover_config_info{{{S}}}', f'storsafe_failover_autorecovery_enabled{{{S}}}'], rename={"A": None, "B": "Auto failback"}, hide=["server"], w=6, h=6)

    d.row("Collector")
    d.stat("Package version", [('storsafe_collector_info', '{{version}}')], w=6, text_mode="name", thresholds=BLUE, desc="Version of the installed StorSafe monitoring package (VERSION file in the install folder).")
    d.stat("Last collector run", [('storsafe_collector_last_run_timestamp_seconds * 1000', None)], "dateTimeAsIso", w=6, thresholds=BLUE)
    d.stat("Checks failing", [(f'count(storsafe_check_success{{{S}}} == 0) or vector(0)', None)], w=6, decimals=0, thresholds=GREEN_RED)
    d.stat("Collection time", [(f'storsafe_collect_duration_seconds{{{S}}}', None)], "s", w=6, thresholds=BLUE, decimals=1)
    d.table("Checks", [f'storsafe_check_success{{{S}}}', f'storsafe_check_last_success_timestamp_seconds{{{S}}} * 1000'],
            rename={"A": "OK", "B": "Last success"}, units={"Last success": "dateTimeAsIso"}, bool_cols=["OK"], hide=["server"], sort=("OK", False), w=12, h=12)
    d.ts("Collection time", [(f'storsafe_collect_duration_seconds{{{S}}}', "seconds")], "s", w=12, h=12)
    write(d)


# ============================================================================ Patch management
def patches():
    S = 'server=~"$server"'
    d = Dashboard("StorSafe Patch Management", "storsafe-patches", S, "multi", time_from="now-7d", refresh="5m", description="Versions, builds, patches and platform details across the estate.")
    d.row("Versions")
    d.stat("Appliances per version", [(f'count by (version) (storsafe_info{{{S}}})', "{{version}}")], w=8, thresholds=BLUE)
    d.stat("Appliances per build", [(f'count by (build) (storsafe_info{{{S}}})', "{{build}}")], w=8, thresholds=BLUE)
    d.stat("Appliances per OS", [(f'count by (osversion) (storsafe_server_info{{{S}}})', "{{osversion}}")], w=8, thresholds=BLUE)
    d.table("Appliances", [
        f'max by (server, hostname, osversion, kernel, make, model, virtual) (storsafe_server_info{{{S}}})',
        f'max by (server, product, version, build, apiversion) (storsafe_info{{{S}}})',
        f'max by (server) (storsafe_patches_installed{{{S}}})',
        f'max by (server) (storsafe_server_memory_bytes{{{S}}})',
        f'max by (server) (storsafe_server_cpus{{{S}}})',
        f'max by (server) (storsafe_time_offset_seconds{{{S}}})',
        f'max by (server) (storsafe_ntp_servers{{{S}}})',
        f'max by (server) (storsafe_server_option_enabled{{{S},option="failover"}})',
        f'max by (server) (storsafe_encryption_option{{{S},option="encryptionactive"}})',
    ], rename={"A": None, "B": None, "C": "Patches", "D": "Memory", "E": "CPUs", "F": "Clock offset", "G": "NTP servers", "H": "Failover", "I": "Encryption active"},
        units={"Memory": "bytes", "Clock offset": "s"},
        order=["server", "hostname", "product", "version", "build", "Patches", "osversion", "kernel", "make", "model", "virtual", "Memory", "CPUs", "Clock offset", "NTP servers", "Failover", "Encryption active", "apiversion"],
        sort=("build", False), h=16, filterable=True, links=[{"title": "Open instance", "url": INSTANCE_URL}],
        desc="Build is the server build number; a dash and number after it is the patch level. Uptime is not exposed by the StorSafe REST API (the console's Service Uptime is a web GUI value); it can be added from SNMP sysUpTime if SNMP is enabled on the appliances.")
    d.row("Patches")
    d.table("Installed patches", [f'storsafe_patch_info{{{S}}}'], rename={"A": None}, sort=("server", False), h=12, filterable=True, w=16)
    d.table("Patch coverage", [f'count by (patch) (storsafe_patch_info{{{S}}})', f'count(storsafe_up{{{S}}})'], rename={"A": "Appliances with patch", "B": None}, merge=False, w=8, h=12,
            sort=("Appliances with patch", False), desc="How many appliances have each patch. Compare with the appliance count in the Versions row to spot gaps.")
    write(d)


# ============================================================================ Events
def events():
    S = 'server=~"$server"'
    d = Dashboard("StorSafe Events", "storsafe-events", S, "multi", description="Appliance event logs across the estate. Informational events are counted but not listed.")
    d.row("Last 24 hours")
    d.stat("Critical", [(f'sum(increase(storsafe_events_total{{{S},severity="critical"}}[24h])) or vector(0)', None)], w=6, decimals=0, thresholds=GREEN_RED)
    d.stat("Error", [(f'sum(increase(storsafe_events_total{{{S},severity="error"}}[24h])) or vector(0)', None)], w=6, decimals=0, thresholds=GREEN_RED)
    d.stat("Warning", [(f'sum(increase(storsafe_events_total{{{S},severity="warning"}}[24h])) or vector(0)', None)], w=6, decimals=0, thresholds=[{"color": "green", "value": None}, {"color": "orange", "value": 1}])
    d.stat("Informational", [(f'sum(increase(storsafe_events_total{{{S},severity="informational"}}[24h])) or vector(0)', None)], w=6, decimals=0, thresholds=BLUE)
    d.ts("Events per hour by severity", [(f'sum by (severity) (increase(storsafe_events_total{{{S},severity!="informational"}}[1h]))', "{{severity}}")], "none", w=12, h=7, bars=True, stack=True)
    d.ts("Errors and criticals per hour by appliance", [(f'sum by (server) (increase(storsafe_events_total{{{S},severity=~"error|critical"}}[1h]))', "{{server}}")], "none", w=12, h=7, bars=True, stack=True)
    d.row("Recent events")
    d.table("Warnings, errors and criticals (20 newest per appliance)", [f'storsafe_event_recent{{{S}}} * 1000'], rename={"A": "When"}, units={"When": "dateTimeAsIso"}, color_cols=["severity"],
            order=["When", "server", "severity", "id", "message"], hide=["time"], sort=("When", True), h=18, filterable=True, links=[{"title": "Open instance", "url": INSTANCE_URL}],
            desc="Filter any column with the funnel icon. The complete log, informational events included, is archived daily under events\\ on the monitoring host.")
    d.table("Event log collection", [f'storsafe_eventlog_columns_detected{{{S}}}', f'storsafe_check_success{{{S},check="eventlog"}}'],
            rename={"A": "Columns recognised", "B": "Collecting"}, bool_cols=["Columns recognised", "Collecting"], hide=["check"], h=6)
    write(d)


if __name__ == '__main__':
    fleet(); activity(); instance(); patches(); events()
