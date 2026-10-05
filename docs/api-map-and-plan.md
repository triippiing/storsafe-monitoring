# StorSafe REST API: capability map and monitoring plan

Source: FalconStor StorSafe REST API Guide, 21 Nov 2022 (copy at `storsafe/source/StorSafe_REST_API.md`, line refs below point into it).
Covers FBD / StorSafe / SIR v9+. Static review only. No live calls have been made.

---

## 1. API basics

| Item | Detail |
|---|---|
| Base | `http(s)://<appliance>/obd/...` (two mirror endpoints use `/ipstor/...`) |
| Auth | `POST /obd/auth/login` `{"username","password","server":"<appliance IP>"}` → `{"rc":0,"id":"<uuid>","type":"root|admin|user"}` + `Set-Cookie: session_id=` |
| Session | Cookie `session_id`. **Idle timeout ~10 min** (L456). Logout `POST /obd/auth/logout`. |
| Result | HTTP status **and** `rc` in the body. `rc=0` success, `rc=109` partial batch success. Code lookup: `GET /obd/server/rcs`, `GET /obd/server/rcs/<id>`. |
| Paging | `offset`/`limit` (default/max examples 1000) on virtualtape, runhistory, tapehistory, tapeinfo |
| Time | Mostly Unix epoch. Replication incoming uses `YYYY-MM-DD hh:mm:ss`. Sizes are mixed: bytes (pools, devices), MB (tapes, jobs), GB (object storage). |
| Roles | Account types `A` Admin, `S` Standard (multi-tenant, `useracl`), **`R` Read-only**, `I` iSCSI (L20610). Some actions (reclaim, prune) are root/superadmin only. |
| Server log | `/usr/local/apache-tomcat/logs/obd.log` on the appliance (20 MB × 10 rotation) |

**Doc quirk:** the replication queue is read at `/obd/vtl/activities/replicationqueue`, but the PUT samples use `/obd/activities/replicationqueue` (L17829-17851). Confirm against the live box before scripting writes.

---

## 2. Read-only monitoring surface ("what can be scrubbed")

### 2.1 Appliance health and identity
| Endpoint | Useful fields | Monitor use |
|---|---|---|
| `GET server/properties/version` | product, version, build(-patch), apiversion | Version drift between primary and secondary |
| `GET server/properties/info` | role, os/kernel, CPU list, memory, swap, make/model, isvirtualappliance, fmsrunning | Inventory |
| `GET server/properties/time`, `ntp` | server time, NTP servers | Clock skew (matters for epoch-based job data) |
| `GET patches` | name, desc | Patch level compliance |
| `GET server/failover/status` | `notconfigured / normal / takenover / tookover / suspended / swap` | **Alert on anything other than normal (or notconfigured)** |
| `GET server/failover/smsstatus` | `up / ready / down` | Partner self-monitor after takeover |
| `GET server/failover` | config incl. partner, heartbeat | Inventory |
| `GET logicalresource/status/<id>` | `online / incomplete` (missing segments) | Config repo, tape DB, dedupe data/index/folder devices |
| `GET /ipstor/logicalresource/mirror/<id>` | mirror state | Config repository mirror health |
| `GET server/syslogalert`, `snmp` | alert patterns, SNMP config | Config audit only. These do **not** return alerts. |

### 2.2 Capacity
| Endpoint | Useful fields |
|---|---|
| `GET physicalresource/storagepool` | per pool: name, resourcetype, **size, used** (bytes) |
| `GET physicalresource/physicaldevice` | per LUN: reservation (tapes/deduplication/configuration/nas), **size, used**, owner, isforeign, **status online/offline** |
| `GET server/storagethreshold` | configured disk-usage % threshold (use as the alert line) |
| `GET tle/tapecaching` | unmigrated/reclaimable cache MB, total/used virtualised disk MB |
| `GET deduplication` | repository config: nodes, data/index/folder disks with **sizes**, failoverstatus, encryption, associated servers |
| `GET deduplication/reclamation/status` | `reclaimstatus`, `prunestatus`: `idle / running / failed` (empty string on standby or no repo) |
| `GET deduplication/reclamation`, `cleanup` | reclamation policy, cleanup state |

**Gap:** there is no single "repository used / free / global dedupe ratio" call. Repository fill must be derived from the physical devices reserved for `deduplication` plus pool usage, and dedupe ratio from the policy run history (2.4). This is an inference from the field lists, so validate it against the GUI on day one.

### 2.3 VTL inventory and state
| Endpoint | Useful fields |
|---|---|
| `GET virtuallibrary` | per VTL: id, name, slots, drives, **loadeddrives**, tapes |
| `GET virtuallibrary/drive/<libId>` | `data.drives[]`: id, name, serialno, status `empty / loaded`, loadedtape {id, name, barcode} |
| `GET virtualdrive`, `virtualdrive/<id>` | standalone drives |
| `GET virtuallibrary/freeslot/<id>` | free slots (slot exhaustion) |
| `GET virtualtape?offset&limit` + filters | tape list. Server-side filters exist for location (lib/vault/replica), barcode, **used/available size**, creation/modification time, replication source |
| `GET virtualtape/<id>` | tape detail incl. write-protect, replication, encryption |
| `GET virtualtape/vault` | vaulted tapes |
| `GET tle/reclaim/tapes` | tapes eligible for space reclamation |

### 2.4 Deduplication activity
| Endpoint | Useful fields |
|---|---|
| `GET dedupepolicy` | per policy: status `idle/running/suspended/stopping/preparing/stopped/queued/error`, suspended, **lastrun/nextrun**, trigger, tapes, replicationmode, targets |
| `GET dedupepolicy/activestatus/<id>` | per tape being scanned: datasize, scanned, **throughput MB/s**, status incl. `failed`, `writingvitfailed` |
| `GET dedupepolicy/runhistory/<id>?fromts&tots` | per run: dedupedata, uniquedata, **deduperatio**, duration, repldata, replunique, repldeduperatio, replduration |
| `GET dedupepolicy/tapehistory/<id>` | same per tape |
| `GET vtl/activities/dedupequeue` | live queue: state (queued, deduplicating, uniquereplicating, tapeindrive, suspended …), **undedupeddatamb**, throughputmbps, progress % |

### 2.5 Replication
| Endpoint | Useful fields |
|---|---|
| `GET dedupereplication` | source and target servers, protocol, TCP options |
| `GET vtl/activities/replicationqueue` | non-dedupe replication jobs: state `running / waiting / waitingforslot …` |
| `GET vtl/activities/uniquereplicationqueue` | dedupe unique-data replication jobs, starttime, status |
| `GET vtl/activities/replicationqueue/setting` | global `normal / suspended` |
| `GET tapereplication/outgoing/<tapeId>` | per tape: status `onschedule / suspended / skipped`, dedupe resolved flags |
| `GET tapereplication/incoming/<tapeId>` | per replica: status `new / normal / error / inprogress`, **lastsuccessfulsync**, throughput, ETA |

Per-tape replication calls mean one request per tape, so poll them rarely or only for flagged tapes. Use the queues for near-real-time status.

### 2.6 Physical tape (if libraries are attached)
| Endpoint | Useful fields |
|---|---|
| `GET physicallibrary/status` | per library: status `online / offline / disabled / addrnotconfig`, tapes, loadedtapes; per drive: status `empty / loaded / ejected / offline / passthrough / unloading / disabled` |
| `GET physicaldrive/<id>`, `physicaltape/<id>` | detail, stacked tapes |
| `GET activity/iejob` | import/export/stacking/object-storage jobs with status and mode |
| `GET historyphysicaltapes` | export history |

### 2.7 SAN / front end
`GET physicalresource/physicaladapter[/<id>]` (FC/iSCSI ports, WWPNs), `fcclientinitiators` (initiators seen via SNS), `GET client`, `client/iscsitarget`, and `physicaldevice/scsialias/<id>` (path count per LUN). These are useful for "backup server lost its FC paths" checks.

### 2.8 Events and alerts
- **No GET for alerts.** The event log is pulled with `PUT /obd/server/event {"range":"YYYYMMDDhhmmss[-YYYYMMDDhhmmss]"}` and `Accept: application/csv`, which returns a CSV. The manual lists "Download the Event Log" as permitted for read-only users.
- Hardware sensors (PSU, fans, temperatures, disk SMART) are **not exposed**. `ipmi`/`ilo` only return BMC network config. Hardware health has to come from the BMC (IPMI/Redfish) or from SNMP traps the appliance sends.
- X-ray support bundles can be generated and fetched (`POST server/xray/tolocal`, `GET server/xray/ready`, `GET server/xray?filename=`).

---

## 3. Admin actions available (candidate utilities)

| Risk | Action | Endpoint |
|---|---|---|
| Low | Re-prioritise or cancel a dedupe job | `PUT vtl/activities/dedupequeue/<tapeId>` `runnext / runlater / cancel` |
| Low | Restart / suspend / resume / cancel import-export jobs (batch) | `PUT activity/iejob` |
| Low | Generate and download an X-ray | `server/xray/*` |
| Low | Save server config | `POST server/properties/save` |
| Med | Start / stop / suspend / resume a dedupe policy, suspend replication per target | `PUT dedupepolicy/<id>` |
| Med | Suspend / resume all non-dedupe replication | `PUT .../replicationqueue` |
| Med | Start space reclamation / index prune (root only) | `POST deduplication/reclaim`, `prune` |
| Med | Move tapes (vault ↔ library, physical library) | `PUT virtualtape/movetapes`, `physicallibrary/movetapes/<id>` |
| Med | Manage replication per tape | `PUT tapereplication/manage/<id>`, `tapereplica/manage/<id>` |
| High | Failover suspend / resume / takeover / stop takeover | `PUT server/failover/*` |
| High | Create or delete VTLs, drives, tapes; shred; export | `virtuallibrary`, `virtualtape`, `virtualtape/shred` |
| High | Storage pools, device prep/delete, network, patches, encryption keys | various |

Recommendation: the utilities should expose the Low and Med rows only. High-risk actions stay in the StorSafe console.

---

## 4. Suggested alert rules (first cut)

| Condition | Source | Severity |
|---|---|---|
| Login fails / API unreachable | auth/login | Critical |
| Failover status ≠ normal (and configured) | server/failover/status | Critical |
| Any physical device `offline`, logical resource `incomplete` | physicaldevice, logicalresource/status | Critical |
| Pool or repository used % ≥ `storagethreshold` (warn 5 % below) | storagepool, physicaldevice | Warn / Crit |
| `reclaimstatus` or `prunestatus` = failed | reclamation/status | Major |
| Dedupe policy `error`, or `lastrun` older than its schedule + grace | dedupepolicy | Major |
| `undedupeddatamb` growing across N polls (backlog) | dedupequeue | Warn |
| Replication global status suspended, or replica `lastsuccessfulsync` > RPO | replicationqueue/setting, tapereplication/incoming | Major |
| Dedupe ratio drop > X % against the 7-day average | runhistory | Info |
| Free virtual slots < N, scratch tapes < N | freeslot, virtualtape filters | Warn |
| Physical library/drive offline; failed IE jobs | physicallibrary/status, iejob | Major |
| Version/patch mismatch between primary and secondary | version, patches | Info |

---

## 5. Plan options

All options share the same foundation (Phase 0 below). They differ in where the data is stored and shown.

### Phase 0 (common to all options)
1. Create a **Read-only (`R`) API account** on both appliances. Before building anything, confirm it can call the Section 2 GETs. The manual only explicitly lists event-log/X-ray rights for read-only users.
2. Build one shared client library: login, cookie session, re-login on 401 or idle timeout, `rc` check, paging, retry, and an https default with a proper CA trust.
3. Move the estate config (appliance names, DNS) and credentials out of the code, into a config file plus a vault (Windows SecretManagement/DPAPI, or a root-only `0600` file / Vault on Linux).
4. Validate a handful of responses against the live appliances (read-only) and pin the schemas.

### Option A: PowerShell module + scheduled reports
Turn the two scripts into a `StorSafe.psm1` module with `Get-SS*` collectors. Task Scheduler runs them every 5-15 min, writes JSON/CSV and a static HTML status page, and emails or exits non-zero on alert rules.
- **Pros:** fastest; reuses what exists; no new infrastructure.
- **Cons:** no real trending or graphs; alerting is home-grown; the HTML page is a snapshot only.
- **Effort:** low.

### Option B: Exporter + Prometheus/Grafana, with an admin CLI (recommended)
A small exporter (Python on a Linux admin host) polls Section 2 every 60-300 s per endpoint tier and exposes `/metrics`. Prometheus stores the history, Grafana provides the dashboards (estate overview, capacity trend, dedupe ratio/backlog, replication lag, VTL/drive state), and Alertmanager sends the Section 4 rules to email, SNMP or Teams. Admin utilities are a separate CLI (`storsafe-admin`, or the PS module from A) limited to the Low/Med actions, using a separate admin credential, with `--dry-run` by default and an audit log.
- **Pros:** proper trending (capacity forecasting, ratio drift, replication lag); standard alerting; it fits beside other estate monitoring and could later take TSM/Veeam metrics; keeps read-only monitoring separate from write actions.
- **Cons:** needs a Linux VM with Prometheus and Grafana, or an existing instance.
- **Effort:** medium.

### Option C: Plug into an existing monitoring tool
If you already run Zabbix, Nagios/Icinga, Checkmk or similar, write check plugins (ksh/bash + `curl`/`jq`, or PS) that return Nagios-style exit codes and perfdata for each Section 4 rule. Admin utilities are the same CLI as in B.
- **Pros:** no new stack; alerts land in the existing on-call path.
- **Cons:** dashboards are only as good as that tool's; perfdata history varies.
- **Effort:** low-medium.

### Option D: Custom web app (dashboard + admin UI)
A FastAPI/Flask (or ASP.NET) app with a collector, a SQLite/Postgres store, a web dashboard and buttons for admin actions.
- **Pros:** a single pane, tailored to how you work.
- **Cons:** the most code to own; you'd be rebuilding graphing and alerting; a web UI that can trigger failover or cancel jobs needs authentication, RBAC and auditing done properly.
- **Effort:** high.

**Recommendation: B.** If an existing monitoring platform is already in place, C gets you alerting sooner. You could run C for alerts and B's Grafana for trends.

### Suggested phasing for B
1. **Phase 0** above, plus fixes to the existing scripts (see script-review.md).
2. **Collector v1:** health, failover, capacity, reclamation, dedupe policies and queue, replication queues, VTL/drive summary. Grafana overview dashboard plus the Critical/Major alert rules.
3. **History:** dedupe runhistory ratios, replication lag per replica set (sampled), capacity forecast panel, event-log CSV pull with parsing.
4. **Admin CLI:** Low/Med actions, dry-run default, audit log.
5. **Optional:** physical tape/IE jobs, SAN path checks, BMC/Redfish hardware health, correlation with TSM/Veeam job data.

### Open questions for you
- Is there an existing monitoring platform (Zabbix, Nagios, Checkmk, Prometheus, Grafana, SCOM)?
- Where would the collector run: a Windows jump host or a Linux admin VM?
- Are physical tape libraries attached to the StorSafe boxes, or is it pure VTL + dedupe + replication?
- Is primary → secondary replication the only replication path, and what is the RPO you'd alert on?
- Is HTTPS enabled on the appliances' API, and with what certificate?

---

## 6. Decision: Option B on a Windows desktop (2026-10-01)

Option B was chosen, with Grafana on a Windows host. Adapted stack:

```
StorSafe x2 --REST--> Collector (PowerShell, StorSafe.psm1, Task Scheduler every 2-5 min)
                         |  writes storsafe.prom (Prometheus text format, atomic rename)
                         v
                  windows_exporter (textfile collector dir)  --> Prometheus (Windows service) --> Grafana (Windows service)
                                                                                                   |-> Grafana alerting -> email/Teams
Admin CLI: Invoke-StorSafeAdmin.ps1 (same module, separate admin credential, -WhatIf default, audit log)
```

Why this shape:
- **The collector is PowerShell, not Python.** It reuses the tested `StorSafe.psm1` and adds no runtime to the desktop.
- **windows_exporter's textfile collector** gives Prometheus an endpoint to scrape without writing an HTTP listener. Each run rewrites one `.prom` file, written to a temp name and then renamed.
- **Prometheus** runs as a Windows service (native binary, wrapped with WinSW/NSSM). Retention is about 90 days; two appliances produce a small series count.
- **Grafana alerting** replaces Alertmanager, so there is one less service on Windows.

Desktop caveats:
- Sleep, reboots and patching will leave gaps. Set the power plan to never sleep, and run all three components as services or SYSTEM-independent tasks.
- The scheduled task must use "Run whether user is logged on or not". Create the credential files **as that same account**, because DPAPI ties them to user and machine.
- The firewall needs outbound 443 to both appliances. Grafana and Prometheus can listen on localhost unless other people need the dashboard.

Next steps:
1. **Collector v1** (`Export-StorSafeMetrics.ps1`): health, failover, capacity (pools + LUNs vs threshold), reclaim/prune, dedupe policies and queue backlog, replication queues and global state, VTL drive/slot summary, collector duration/success gauges.
2. **Install pack:** a PowerShell installer for windows_exporter + Prometheus + Grafana services, a provisioned data source, and an estate-overview dashboard JSON.
3. **Alert rules** from Section 4 as Grafana alert rules.
4. **History metrics:** dedupe ratio from runhistory, sampled replica lag, event-log CSV.
5. **Admin CLI** for the Low/Med actions.
