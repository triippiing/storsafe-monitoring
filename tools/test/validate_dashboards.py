#!/usr/bin/env python3
"""Runs every panel query of every dashboard in monitoring/dashboards/ against a Prometheus holding collector
output and reports query errors and empty results. Usage:
  python3 tools/test/validate_dashboards.py [--prom http://127.0.0.1:19090] [--servers MOCK-A,MOCK-B]"""
import argparse, glob, json, os, re, urllib.error, urllib.parse, urllib.request

ap = argparse.ArgumentParser()
ap.add_argument("--prom", default="http://127.0.0.1:19090")
ap.add_argument("--servers", default="MOCK-A,MOCK-B", help="server label values present in Prometheus")
args = ap.parse_args()
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
servers = args.servers.split(",")
ALL = "(" + "|".join(servers) + ")"
total = errors = empty = 0
for path in sorted(glob.glob(os.path.join(ROOT, "monitoring", "dashboards", "*.json"))):
    d = json.load(open(path))
    single = any(v["name"] == "server" and not v.get("multi") for v in d["templating"]["list"])
    panels = []
    for p in d["panels"]:
        panels.append(p); panels += p.get("panels", [])
    print("==", d["title"], "(%d panels)" % len([p for p in panels if p["type"] != "row"]))
    for p in panels:
        for t in p.get("targets", []):
            e = t["expr"].replace("$server", servers[0] if single else ALL).replace("$__all", ALL)
            e = re.sub(r"\$__(rate_)?interval", "5m", e).replace("$__range", "24h")
            total += 1
            try:
                r = json.load(urllib.request.urlopen(args.prom + "/api/v1/query?" + urllib.parse.urlencode({"query": e}), timeout=10))
            except urllib.error.HTTPError as ex:
                r = json.load(ex)
            if r["status"] != "success":
                errors += 1; print("  ERROR  %-45s %s :: %s" % (p["title"][:45], t["refId"], r.get("error"))); print("         ", e); continue
            if not r["data"]["result"]:
                empty += 1; print("  empty  %-45s %s  %s" % (p["title"][:45], t["refId"], e[:110]))
print("queries %d  errors %d  empty %d" % (total, errors, empty))
raise SystemExit(1 if errors else 0)
