"""Builds the product's website from the repository: python3 docs/pages/build.py. Writes site/, its pages linking each
other by relative paths so any domain serves it (GitHub Pages publishes it from main); fails when a diagram's layout
breaks (an arrow through a box, two arrows crossing, labels overlapping)."""
import importlib, os, shutil, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import common
made = []
_init = common.Svg.__init__
def _track(self, *a, **k):
    _init(self, *a, **k); made.append(self)
common.Svg.__init__ = _track
here = os.path.dirname(os.path.abspath(__file__))
site = os.path.join(here, "..", "..", "site")
NAMES = ("landing", "home", "architecture", "engines", "database", "template", "buildspec", "contribute")
KEYS = {"landing": "site", "home": "home", "architecture": "architecture", "engines": "engines", "contribute": "contribute", "database": "database","template": "template", "buildspec": "build-spec"}
os.makedirs(site, exist_ok=True)
for name in NAMES:
    mod = importlib.import_module(name)
    open(os.path.join(site, common.FILES[KEYS[name]]), "w", encoding="utf-8").write(mod.HTML)
docs = importlib.import_module("docs")
for old in os.listdir(site):
    if old.startswith("doc-") and old.endswith(".html") and old not in docs.PAGES:
        os.remove(os.path.join(site, old))
for file, html in docs.PAGES.items():
    open(os.path.join(site, file), "w", encoding="utf-8").write(html)
shutil.copy(os.path.join(here, "favicon.svg"), os.path.join(site, "favicon.svg"))
os.makedirs(os.path.join(site, "screenshots"), exist_ok=True)
shutil.copy(os.path.join(here, "..", "screenshots", "table-and-turn.jpg"), os.path.join(site, "screenshots", "table-and-turn.jpg"))
brief = sys.modules["contribute"]
open(os.path.join(site, "llms.txt"), "w", encoding="utf-8").write(brief.LLMS_TXT)
open(os.path.join(site, "agents.xml"), "w", encoding="utf-8").write(brief.AGENTS_XML)
top = os.path.join(here, "..", "..")
open(os.path.join(top, "AGENTS.md"), "w", encoding="utf-8").write(brief.AGENT_FILE)
open(os.path.join(top, "CLAUDE.md"), "w", encoding="utf-8").write(brief.CLAUDE_MD)
open(os.path.join(top, ".github", "copilot-instructions.md"), "w", encoding="utf-8").write(brief.AGENT_FILE)
bad = [(s.label, s.check()) for s in made if s.check()]
for label, problems in bad:
    print(f"layout: {label[:70]}", *problems, sep="\n  ")
print(f"{len(made)} diagrams, {len(bad)} with layout problems; site written")
sys.exit(1 if bad else 0)
