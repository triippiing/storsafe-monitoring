#!/usr/bin/env python3
"""Builds dist/StorSafe-monitoring-v<VERSION>.zip from this repository: everything a monitoring host needs,
under a StorSafeMonitoring/ top folder. tools/, docs/, dist/ and git metadata are left out.
Run from anywhere: python3 tools/build-package.py"""
import os, zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
VERSION = open(os.path.join(ROOT, "VERSION")).read().strip()
OUT = os.path.join(ROOT, "dist", "StorSafe-monitoring-v%s.zip" % VERSION)
TOP = "StorSafeMonitoring/"
SKIP_DIRS = {".git", "tools", "docs", "dist", "prometheus", "__pycache__"}
SKIP_FILES = {".gitignore", ".gitattributes", ".git"}
# Runtime folders ship with only their README.txt, whatever a dev checkout has in them.
RUNTIME_DIRS = {"creds", "state", "events", "metrics", "reports", "installers"}

files = []
for dirpath, dirnames, filenames in os.walk(ROOT):
    rel = os.path.relpath(dirpath, ROOT)
    parts = [] if rel == "." else rel.split(os.sep)
    dirnames[:] = sorted(d for d in dirnames if d not in SKIP_DIRS)
    for name in sorted(filenames):
        if name in SKIP_FILES or name.endswith(".part"):
            continue
        if parts and parts[0] in RUNTIME_DIRS and name != "README.txt":
            continue
        files.append(os.path.join(rel, name) if parts else name)

os.makedirs(os.path.dirname(OUT), exist_ok=True)
with zipfile.ZipFile(OUT, "w", zipfile.ZIP_DEFLATED) as z:
    for f in files:
        z.write(os.path.join(ROOT, f), TOP + f.replace(os.sep, "/"))
print(OUT)
for f in files:
    print("  " + TOP + f.replace(os.sep, "/"))
