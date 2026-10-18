#!/usr/bin/env python3
"""Opens every StorSafe dashboard in a Grafana that serves them (anonymous viewer access), saves a screenshot of
each and fails when a panel shows an error, a panel plugin is missing, or (with --cards) the Fleet dashboard does
not show its Business Text estate cards. Needs Python Playwright and its Chromium. Usage:
  python3 tools/test/render_dashboards.py [--grafana http://127.0.0.1:3000] [--out tools/test/out/screens] [--cards]"""
import argparse, os
from playwright.sync_api import sync_playwright

UIDS = ["storsafe-fleet", "storsafe-activity", "storsafe-instance", "storsafe-patches", "storsafe-events"]

ap = argparse.ArgumentParser()
ap.add_argument("--grafana", default="http://127.0.0.1:3000")
ap.add_argument("--out", default=os.path.join(os.path.dirname(os.path.abspath(__file__)), "out", "screens"))
ap.add_argument("--cards", action="store_true", help="require Fleet's Business Text cards (the plugin is installed)")
args = ap.parse_args()
os.makedirs(args.out, exist_ok=True)

problems = []
with sync_playwright() as pw:
    browser = pw.chromium.launch()
    # A locale of its own: headless Chromium on a POSIX locale reports en-US@posix, which Grafana's Intl calls reject.
    page = browser.new_page(viewport={"width": 1920, "height": 1080}, locale="en-GB")
    for uid in UIDS:
        page.goto("%s/d/%s/%s?orgId=1&kiosk" % (args.grafana, uid, uid), wait_until="networkidle")
        page.wait_for_timeout(5000)
        path = os.path.join(args.out, uid + ".png")
        page.screenshot(path=path)
        text = page.inner_text("body")
        if "Panel plugin not found" in text:
            problems.append("%s: a panel plugin is not installed" % uid)
        errors = page.locator('[data-testid="data-testid Panel status error"]').count()
        if errors:
            problems.append("%s: %d panel(s) show an error" % (uid, errors))
        line = "%-20s %s" % (uid, path)
        if uid == "storsafe-fleet":
            cards = page.locator(".ss-card").count()
            line += "  cards %d" % cards
            if args.cards and cards != 8:
                problems.append("storsafe-fleet: %d estate cards, expected 8" % cards)
        print(line)
    browser.close()

for p in problems:
    print("PROBLEM", p)
raise SystemExit(1 if problems else 0)
