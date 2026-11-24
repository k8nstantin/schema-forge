"""Builds the product's pages from the repository: python3 docs/pages/build.py. Writes the private previews to
docs/pages/published/<page>.html (linking each other by their published links, not committed) and the website to site/ (linking each other by
relative paths, so any domain serves it), both from one stylesheet; fails when a diagram's layout breaks (an arrow
through a box, two arrows crossing, labels overlapping)."""
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
NAMES = ("landing", "home", "engines", "database", "template", "buildspec", "contribute")
KEYS = {"landing": "site", "home": "home", "engines": "engines", "contribute": "contribute", "database": "database", "template": "template", "buildspec": "build-spec"}
for mode in ("artifact", "site"):
    common.MODE = mode
    for name in NAMES:
        mod = importlib.reload(sys.modules[name]) if name in sys.modules else importlib.import_module(name)
        key = KEYS[name]
        if mode == "artifact":
            os.makedirs(os.path.join(here, "published"), exist_ok=True)
            open(os.path.join(here, "published", f"{key}.html"), "w", encoding="utf-8").write(mod.HTML)
        else:
            os.makedirs(site, exist_ok=True)
            open(os.path.join(site, common.FILES[key]), "w", encoding="utf-8").write(mod.HTML)
shutil.copy(os.path.join(here, "favicon.svg"), os.path.join(site, "favicon.svg"))
brief = sys.modules["contribute"]
open(os.path.join(site, "agents.md"), "w", encoding="utf-8").write(brief.AGENTS_MD)
open(os.path.join(site, "llms.txt"), "w", encoding="utf-8").write(brief.LLMS_TXT)
open(os.path.join(site, "agents.xml"), "w", encoding="utf-8").write(brief.AGENTS_XML)
top = os.path.join(here, "..", "..")
open(os.path.join(top, "AGENTS.md"), "w", encoding="utf-8").write(brief.REPO_AGENTS_MD)
open(os.path.join(top, "CLAUDE.md"), "w", encoding="utf-8").write(brief.CLAUDE_MD)
open(os.path.join(top, ".github", "copilot-instructions.md"), "w", encoding="utf-8").write(brief.REPO_AGENTS_MD)
bad = [(s.label, s.check()) for s in made if s.check()]
for label, problems in bad:
    print(f"layout: {label[:70]}", *problems, sep="\n  ")
print(f"{len(made) // 2} diagrams, {len(bad) // 2} with layout problems; pages and site written")
sys.exit(1 if bad else 0)
