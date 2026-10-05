# Testing without an appliance

Everything here runs on Linux or Windows with PowerShell 7 (`pwsh`) and Python 3; the collector itself also runs on Windows PowerShell 5.1, which is what the scheduled task uses.

1. Start the mock StorSafe API (serves the documented endpoints with made-up data; `--expire` makes the first session expire once, `--noheader` returns a headerless event CSV, `--gzip` compresses it):
   ```
   python3 tools/test/mock_api.py 18080
   ```
2. Run the collector against it (the mock credential is user `mon`, password `pw`, stored with Export-Clixml on Linux, so it is not DPAPI-protected and only works with the mock):
   ```
   pwsh -NoProfile -File ./Export-StorSafeMetrics.ps1 -ConfigPath tools/test/mock.config.json -All -NonInteractive -TextfileDirectory tools/test/out
   promtool check metrics < tools/test/out/storsafe.prom
   ```
   Expect "Wrote ... samples for 2 server(s)" and every `storsafe_check_success` at 1 (the second run also records a reclamation run finishing, because the mock reports reclaim running for its first two status calls).
3. Validate the dashboards: serve the output file as `/metrics`, point a Prometheus at it, then run the validator.
   ```
   ln -sf storsafe.prom tools/test/out/metrics
   (cd tools/test/out && python3 -m http.server 19100 --bind 127.0.0.1 &)
   prometheus --config.file=tools/test/prometheus-test.yml --storage.tsdb.path=tools/test/out/tsdb --web.listen-address=127.0.0.1:19090 &
   sleep 10; python3 tools/test/validate_dashboards.py
   ```
   Expect `errors 0`. A few `empty` lines are normal: `increase()` queries need more than one scrape, the 30-day trend needs history, and the mock omits tape caching, policy targets and failover auto-recovery.

After changing a dashboard in `tools/build-dashboards.py`, regenerate with `python3 tools/build-dashboards.py` and re-run step 3. `python3 tools/build-package.py` builds the release zip into `dist/`.
