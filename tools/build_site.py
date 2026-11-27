#!/usr/bin/env python3
"""Builds the site (site/), AGENTS.md, CLAUDE.md and the Copilot instructions from the spec and the owners' folders,
with docs/pages/build.py; tools/check.py then checks they are committed as built.

  python3 tools/build_site.py
"""
import os
import runpy
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.argv = [os.path.join(ROOT, "docs", "pages", "build.py")]
runpy.run_path(sys.argv[0], run_name="__main__")
