"""Builds Schema Forge's pages from the repository: python3 docs/pages/build.py. Writes the published pages to
docs/pages/<page>.html (linking each other by their published links) and the website to site/ (linking each other by
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
NAMES = ("landing", "home", "database", "template", "buildspec")
KEYS = {"landing": "site", "home": "home", "database": "database", "template": "template", "buildspec": "build-spec"}
for mode in ("artifact", "site"):
    common.MODE = mode
    for name in NAMES:
        mod = importlib.reload(sys.modules[name]) if name in sys.modules else importlib.import_module(name)
        key = KEYS[name]
        if mode == "artifact":
            open(os.path.join(here, f"{'site' if key == 'site' else key}.html"), "w", encoding="utf-8").write(mod.HTML)
        else:
            os.makedirs(site, exist_ok=True)
            open(os.path.join(site, common.FILES[key]), "w", encoding="utf-8").write(mod.HTML)
shutil.copy(os.path.join(here, "favicon.svg"), os.path.join(site, "favicon.svg"))
bad = [(s.label, s.check()) for s in made if s.check()]
for label, problems in bad:
    print(f"layout: {label[:70]}", *problems, sep="\n  ")
print(f"{len(made) // 2} diagrams, {len(bad) // 2} with layout problems; pages and site written")
sys.exit(1 if bad else 0)
