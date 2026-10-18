#!/usr/bin/env python3
"""Opens every StorSafe dashboard in a Grafana that serves them (anonymous viewer access), saves a screenshot of
each and fails when a panel shows an error, a panel plugin is missing, or (with --cards) the Fleet dashboard does
not show its Business Text estate cards. With --full the screenshots show the whole page as a viewer sees it (Grafana's
menu and toolbar, every panel down to the last), like docs/images. Needs Python Playwright and its Chromium. Usage:
  python3 tools/test/render_dashboards.py [--grafana http://127.0.0.1:3000] [--out tools/test/out/screens] [--cards] [--full] [--from now-15m]"""
import argparse, os
from playwright.sync_api import sync_playwright

UIDS = ["storsafe-fleet", "storsafe-activity", "storsafe-instance", "storsafe-patches", "storsafe-events"]

ap = argparse.ArgumentParser()
ap.add_argument("--grafana", default="http://127.0.0.1:3000")
ap.add_argument("--out", default=os.path.join(os.path.dirname(os.path.abspath(__file__)), "out", "screens"))
ap.add_argument("--cards", action="store_true", help="require Fleet's Business Text cards (the plugin is installed)")
ap.add_argument("--full", action="store_true", help="whole page with Grafana's menu, not kiosk mode")
ap.add_argument("--from", dest="time_from", help="time range start instead of the dashboard's own, e.g. now-15m for a fresh mock")
args = ap.parse_args()
os.makedirs(args.out, exist_ok=True)

problems = []
with sync_playwright() as pw:
    browser = pw.chromium.launch()
    # A locale of its own: headless Chromium on a POSIX locale reports en-US@posix, which Grafana's Intl calls reject.
    page = browser.new_page(viewport={"width": 1920, "height": 1080}, locale="en-GB")
    for uid in UIDS:
        page.set_viewport_size({"width": 1920, "height": 1080})
        query = ("" if args.full else "&kiosk") + ("&from=%s&to=now" % args.time_from if args.time_from else "")
        page.goto("%s/d/%s/%s?orgId=1%s" % (args.grafana, uid, uid, query), wait_until="networkidle")
        page.wait_for_timeout(5000)
        if args.full:
            # Grafana scrolls the dashboard inside its own element, not the page: grow the window to the dashboard's
            # height (panels below the fold load as they come into view, so wait again).
            height = page.evaluate("""() => Math.max(...[...document.querySelectorAll('*')]
                .filter(e => e.scrollHeight > e.clientHeight + 1 && getComputedStyle(e).overflowY.match(/auto|scroll/))
                .map(e => e.scrollHeight - e.clientHeight), 0)""")
            if height:
                page.set_viewport_size({"width": 1920, "height": 1080 + height})
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
            values = page.locator(".ss-card .ss-value").all_inner_texts()
            line += "  cards %d %s" % (cards, values)
            if args.cards and cards != 8:
                problems.append("storsafe-fleet: %d estate cards, expected 8" % cards)
            if args.cards and "-" in values:
                problems.append("storsafe-fleet: a card has no value (%s)" % values)
        print(line)
    browser.close()

for p in problems:
    print("PROBLEM", p)
raise SystemExit(1 if problems else 0)
