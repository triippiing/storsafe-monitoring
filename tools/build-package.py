#!/usr/bin/env python3
"""Builds dist/StorSafe-monitoring-v<VERSION>.zip (Windows host) and .tar.gz (Linux host) from this repository:
everything a monitoring host needs, under a StorSafeMonitoring/ top folder, the same files in both.
tools/, docs/, dist/ and git metadata are left out.
Run from anywhere: python3 tools/build-package.py"""
import os, tarfile, zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
VERSION = open(os.path.join(ROOT, "VERSION")).read().strip()
OUT = os.path.join(ROOT, "dist", "StorSafe-monitoring-v%s.zip" % VERSION)
OUT_TGZ = os.path.join(ROOT, "dist", "StorSafe-monitoring-v%s.tar.gz" % VERSION)
TOP = "StorSafeMonitoring/"
SKIP_DIRS = {".git", ".github", ".superpowers", "tools", "docs", "dist", "prometheus", "__pycache__"}
# Components the Linux installer unpacks next to the scripts; only at the top level, because
# monitoring/grafana holds the provisioning files that ship.
SKIP_TOP_DIRS = {"grafana", "node_exporter"}
# StorSafe.config.json is a site's own config (a clone that runs as an install has one).
SKIP_FILES = {".gitignore", ".gitattributes", ".git", "StorSafe.config.json"}
# Runtime folders ship with only their README.txt, whatever a dev checkout has in them.
RUNTIME_DIRS = {"creds", "state", "events", "metrics", "reports", "installers"}

files = []
for dirpath, dirnames, filenames in os.walk(ROOT):
    rel = os.path.relpath(dirpath, ROOT)
    parts = [] if rel == "." else rel.split(os.sep)
    skip = SKIP_DIRS if parts else SKIP_DIRS | SKIP_TOP_DIRS
    dirnames[:] = sorted(d for d in dirnames if d not in skip)
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

# The tar carries the same files in the same order, preceded by an entry for every folder on the way to
# them (parents first), so that the umask of the root who extracts it cannot change the layout: a 027
# umask would make folders the service account cannot enter. Ownership is normalised and the mode is
# 0755 for the folders and the scripts directly under linux/, 0644 for everything else.
def tar_filter(ti):
    if ti.isdir() or (os.path.dirname(ti.name) == TOP + "linux" and ti.name.endswith(".sh")):
        ti.mode = 0o755
    else:
        ti.mode = 0o644
    ti.uid = ti.gid = 0
    ti.uname = ti.gname = "root"
    ti.mtime = int(ti.mtime)  # whole seconds: the same header layout on every Python version
    return ti

folders = {""}  # "" is the top folder
for f in files:
    parent = os.path.dirname(f)
    while parent:
        folders.add(parent)
        parent = os.path.dirname(parent)

with tarfile.open(OUT_TGZ, "w:gz") as t:
    for folder in sorted(folders):
        t.add(os.path.join(ROOT, folder), arcname=(TOP + folder.replace(os.sep, "/")).rstrip("/"), recursive=False, filter=tar_filter)
    for f in files:
        t.add(os.path.join(ROOT, f), arcname=TOP + f.replace(os.sep, "/"), recursive=False, filter=tar_filter)
print(OUT)
print(OUT_TGZ)
for f in files:
    print("  " + TOP + f.replace(os.sep, "/"))
