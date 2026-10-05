# StorSafe dashboards: design for a 40-instance estate

Date: 2026-10-01. Target screens: 1080p laptop / 1440p monitor, desktop use (dense tables are fine).

## Pages

| Page | Scope | Content |
|---|---|---|
| **Fleet** | all instances, one row each | API up, failed checks, pool used %, repo devices offline, replication queue depth, warnings/errors last 24h, newest replica age. Sortable; red rows float to the top. Click a row to open the Instance page for that server. |
| **Activity** | all instances | Live job tables (below), plus "completed in the last 24 h" from run history, plus import/export jobs. |
| **Instance** | one server, chosen from a picker | Health, capacity, dedupe, replication, tapes, recent events. One dashboard with a `server` variable, not 40 copies; each server has its own bookmarkable URL (`?var-server=NAME`). |
| **Patch management** | all instances, one row each | Product version, build (build-patchlevel), patch count and latest patch, RHEL release, kernel, make/model, memory, clock offset, uptime (see below). |
| **Events** | all instances | Warnings/errors/criticals across the estate, counts over time, searchable table. |

Estate and Detail (the current dashboards) are retired once these exist.

## Activity tables: what the API gives per job

### Dedupe jobs (one row per tape in a dedupe queue)

| Wanted | Source | Notes |
|---|---|---|
| Server | collector label | |
| Policy | `GET /vtl/activities/dedupequeue` | |
| Tape barcode, name | same | |
| State | same | queued, deduplicating, paused, indexrepli, uniquereplicating, tapeindrive, suspended, ... |
| Progress %, throughput, un-deduped MB | same | |
| Drive used | `GET /vtl/activities/dedupequeue/<id>` (`sourcedrive`, `destinationdrive` serials) or `GET /dedupepolicy/activestatus/<id>` (`drivesn`) | Serial numbers; mapped to drive names via the library drive list. |
| Data scanned / size | `activestatus` scan list | |
| **Start time** | **not in the API** | Option: the collector records when it first saw the job (accurate to one collector interval). |

### Replication jobs

| Wanted | Source | Notes |
|---|---|---|
| Server, tape barcode, policy | `dedupequeue` detail / `activestatus` replication list | |
| Target server | `dedupequeue/<id>` `targetservers[]` (name, ip, per-target status, throughput, progress) | Cascaded/parallel policies give two targets. |
| Phase, replicated/transmitted MB, throughput, progress %, remaining time | `activestatus` replication list | |
| Start time | `GET /vtl/activities/uniquereplicationqueue` `starttime` | Only for the unique-data phase. |
| Classic (non-dedupe) replication | `GET /vtl/activities/replicationqueue` (+ `/<id>` for target, retries, next retry time) | No progress figure in the API. |
| **Drive used** | **not applicable** | Replication is a network copy; no tape drive is involved. Show target and phase instead. |

### Repository maintenance (reclamation and pruning)

| Wanted | Source | Notes |
|---|---|---|
| Status | `GET /deduplication/reclamation/status` | Only `idle` / `running` / `failed` for each of reclaim and prune. |
| Trigger policy | `GET /deduplication/reclamation` | Usage-based (interval) and/or scheduled (weekdays, start time). |
| **Space reclaimed, duration, progress** | **not in the API** | Decision (2026-10-01): report status only. The Activity table lists only runs with status `running`, with the time the collector first saw the run. The Instance page also shows the last run's end time and duration, tracked by the collector from the status transitions. |

## Patch page: uptime

`server/properties/info` and `version` give OS, kernel, build and patches, but **no uptime or boot time**. The web console's "Service Uptime" field (Server Overview) is not in the REST API guide: searched for uptime, boot, "running since" and every `server/*` property; the only matches are the reboot and restart-services operations. It is a web GUI value. To find out where the GUI gets it: open the Server Overview page with the browser's developer tools (F12 > Network) and look at which request carries the uptime figure. If it is an `/obd/...` call, the collector can use it even though it is undocumented. Otherwise the options are:

1. **SNMP `sysUpTime`** from the appliance (standard, exact). Needs SNMP enabled on the appliances and a small SNMP poll added to the collector.
2. **Event log boot marker**: if the appliance logs a "server started" event at boot, the collector can keep the last such event's time and publish uptime from it.
3. IPMI/iDRAC power-on time (hardware, not OS).

## Scaling to 40 instances

- Collector: ~5-15 s per appliance with 47 checks, sequential. 40 appliances would take 4-10 min, longer than the 5-minute interval. Needs a parallel mode (N appliances at a time, each writing its own `.prom` file) before production. Straightforward change.
- Prometheus: tape inventory is aggregated per server, so series counts stay small. Recent events are 20 series per server (800 total). Fine on one host.
- Credentials: one DPAPI file per appliance, created once per monitoring host. A read-only API account per appliance is recommended.
- Discovery: replication partners are read from the API (`dedupereplication`), so the Activity page can show source → target without manual pairing.
