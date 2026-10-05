# StorSafe PowerShell script review

Scope: `STORSAFE API/Get-StorSafeActivity.ps1` and `STORSAFE API/Get-StorSafeLoadedTapes.ps1`. Static review only, no live API calls.
Checked against the StorSafe REST API Guide (21 Nov 2022), copied to `storsafe/source/StorSafe_REST_API.md`.

## 1. API surface the scripts use today

| Method | Endpoint | Used by | Purpose |
|---|---|---|---|
| POST | `/obd/auth/login` | both | Body `{username,password,server}`; returns `rc` (0 = OK) and `id`/`session_id`, sent back as `session_id` cookie |
| POST | `/obd/auth/logout` | both | Session teardown |
| GET | `/obd/dedupepolicy` | Activity | Dedupe policy list + status fields |
| GET | `/obd/deduplication/reclamation/status` | Activity | Space reclamation state |
| GET | `/obd/virtualtape?offset=0&limit=1000` | Activity (`-IncludeTapeInventory`) | Virtual tape inventory |
| GET | `/obd/virtuallibrary` | LoadedTapes | VTL list |
| GET | `/obd/virtuallibrary/drive/{libId}` | LoadedTapes | Drives per VTL, incl. loaded tape |

Everything is read-only. Nothing touches capacity, replication, system health, alerts/events, physical tape, or SAN clients.

## 2. What each script does

**Get-StorSafeActivity.ps1** logs in to each selected appliance, pulls the endpoints above, then walks the JSON recursively and records every property whose name ends in `status` (plus `reclaimstatus`/`prunestatus`). Each value is bucketed by regex into Active / Queued / Attention / Inactive / Unknown. Writes a CSV and exits 0 (idle), 1 (active/queued), 2 (attention or API error).

**Get-StorSafeLoadedTapes.ps1** enumerates VTLs, then drives per VTL, keeps drives whose status is exactly `loaded`, and reports library / drive / serial / tape name / barcode. Exits 0 (none loaded), 1 (tapes loaded), 2 (errors).

## 3. Things to scrub or move out of the scripts

| Item | Where | Recommendation |
|---|---|---|
| Appliance names + IPs `STORSAFE-PRIMARY <ip>`, `STORSAFE-SECONDARY <ip>` | Activity L19-22, LoadedTapes L13-16 | Move to a shared config file (`storsafe.json`/`.psd1`) outside the script dir and out of any repo. Use DNS names rather than IPs. |
| Credentials | n/a | **None hardcoded.** Both prompt via `Get-Credential`. Good for interactive use, but see 4.1. |
| Login failure messages embed the full login response JSON | Activity L176-182, LoadedTapes L121-126 | Low risk, but strip/redact `id`/`session_id` before printing or logging. |
| CSVs written next to the script with no retention | both, `$CsvPath` default | Write to a dedicated output dir with a retention sweep. |

## 4. Issues and gaps

### 4.1 Functional
1. **Cannot run unattended.** `Read-Host` server picker + `Get-Credential` per server block Task Scheduler / cron, yet the exit codes are designed for scheduler use (Activity L302). Needs a `-Server`/`-All` param and a non-interactive credential source (SecretManagement vault, DPAPI-protected `Export-Clixml`, or a read-only API account).
2. **`exit 3` is dead code.** With `$ErrorActionPreference = 'Stop'`, every `Write-Error` before `exit 3` (Activity L33/44/48/61, LoadedTapes L27/38/42/54) is terminating, so the process exits **1**, which collides with "active work". A monitor would read a bad selection as "busy", not "broken". Use `Write-Host ... ; exit 3` or `throw` + a top-level trap that maps to 3.
3. **Tape inventory truncates at 1000.** `/obd/virtualtape?offset=0&limit=1000` has no paging loop (the guide's own example pages with `offset=1000`). Larger estates silently under-report.
4. **Status scraping is heuristic.** Any field ending in `status` is collected, so the output is noisy and depends on whatever the API returns. Unmapped values fall into `Unknown`, which is **not** counted in the exit code, so a new failure state (e.g. `degraded`, `offline`, `fault`) would exit 0. Mapping `disabled` to Inactive also hides a disabled dedupe policy.
5. **LoadedTapes likely never finds a loaded drive (per the documented schema).** `GET /obd/virtuallibrary/drive/<id>` returns `{"rc":0,"data":{"vendorid":..,"productid":..,"media":..,"drives":[...]}}` (manual L4933). `ConvertTo-ObjectArray` looks for `drives` at the top level, misses it, falls through to `data`, and returns the single `data` object. The loop then reads `status` off that wrapper object, gets `$null`, and skips it, so the script reports 0 loaded tapes. Fix: use `$driveResponse.data.drives`. If you've seen it report loaded tapes in practice, the live firmware differs from the guide. (`GET /obd/virtuallibrary` returns `data` as an array, so the library step itself is fine.) Documented virtual drive states are only `empty`/`loaded`, so filtering on `loaded` is correct.
6. **Collection/field names are guessed** (`libraries|virtuallibraries|vlibs|items|data`, `id|libid|vlibid`, etc.). Pin them to the documented schema: `data[]` for libraries, `data.drives[]` for drives, `data.policies[]` for dedupe policies, and `data.reclaimstatus`/`data.prunestatus`. Note also that the Activity status regex misses the documented policy states `preparing` and `stopping` (they become Unknown), and that reclamation status is an empty string on a standby node or one without a repository.
7. **401/session expiry not distinguished** from other endpoint errors; `Reachable` is still `$true`.

### 4.2 Security / transport
8. **Default scheme is `http`.** The login body carries the password in cleartext. Default to `https`.
9. **`-SkipCertificateCheck` only works on Windows PowerShell 5.1.** On PowerShell 7 `Invoke-RestMethod` uses HttpClient and ignores `ServicePointManager`, so the switch does nothing there. Use `Invoke-RestMethod -SkipCertificateCheck` on 7.x, or better, trust the appliance CA. It also sets a process-wide trust-all policy.
10. Use a dedicated **Read-only (`R` type) account** on the appliances for polling. The API supports Admin, Standard, Read-only and iSCSI account types.

### 4.3 Maintainability
11. ~60% of each script is duplicated (server picker, TLS, connect/disconnect, GET wrapper). Factor into one module (`StorSafe.psm1`) so new collectors are ~20 lines each.
12. Timestamps are local `Get-Date` per row with culture-dependent CSV formatting. Use one run-level UTC ISO-8601 timestamp.
13. No retry/backoff; sequential per appliance; 30 s timeout per call. Fine for two boxes, but worth a retry on transient errors before raising exit 2.

## 5. Net assessment
Both scripts are sound ad-hoc operator checks with good structure (StrictMode, session logout in `finally`, CSV + exit codes). They are not yet usable as monitoring collectors because of the interactive prompts, the exit-code collision, and heuristic parsing. They cover dedupe/reclamation activity and drive load state only; capacity, replication, health and alerts are not collected at all.

## 6. Fixes applied (2026-10-01)

Originals are kept in `storsafe/originals/`. Both scripts now import a shared `StorSafe.psm1`, and the appliance list lives in `StorSafe.config.json` (`StorSafe.config.example.json` is a template).

| # | Fix |
|---|---|
| 1 | `-Server`/`-All`/`-NonInteractive`/`-Credential` added. A per-server `CredentialFile` holds a DPAPI-protected `Export-Clixml` created by `New-StorSafeCredentialFile`. The interactive picker and prompts still work when no switches are given. |
| 2 | Usage and config errors go to stderr and **exit 3** for real. |
| 3 | `/virtualtape` is paged until `total` is reached (tested with 2,500 tapes across 3 pages). |
| 4 | The recursive `*status` scrape is replaced with explicit parsing of `data.policies[]`, `data.reclaimstatus`/`prunestatus` and per-tape `devicestatus`/`dedupestatus`/`replstatus`. The status map covers the documented values (including `preparing`, `stopping` and compound `completedfailed` etc.). **Unknown now counts towards exit 2.** `suspended=true` on a policy is flagged Attention. Empty reclaim/prune status is reported as N/A. The tape inventory writes only non-idle tapes plus a summary row. |
| 5 | LoadedTapes reads `data.drives[]`, and cross-checks the parsed count against each library's `loadeddrives`, so a format change surfaces as exit 2 instead of a silent 0. (A tape mid-load/unload between the two calls can trip this once.) |
| 7 | Errors are classified as Auth / Connection / Endpoint. A 401 triggers one re-login. `Reachable` is now accurate. |
| 8 | `https` is the default scheme. `"Scheme": "http"` can still be set in config. |
| 9 | Certificate skip works on both 5.1 (ServicePointManager) and 7.x (`-SkipCertificateCheck`). TLS 1.2 is forced on 5.1. |
| - | The `rc` is checked on every call, and the login response is never echoed. |
| 12 | One UTC ISO-8601 timestamp per run. Epoch fields are converted. |
| 13 | One retry on transient errors (connection, 408, 5xx). |
| - | Reports go to `Reports\` (configurable) with a 30-day retention sweep. |

Tested on PowerShell 7.4 against a mock API covering paging, 401 re-login, refused connection, bad password, unknown status, the cross-check and all exit-3 paths. Not yet run on Windows PowerShell 5.1 or against a live appliance.

