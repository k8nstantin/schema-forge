"""Builds the Schema Forge pack from the repository: python3 docs/pages/build.py. Writes docs/pages/<page>.html, and
fails when a diagram's layout breaks (an arrow through a box, two arrows crossing, labels overlapping)."""
import os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import common
made = []
_init = common.Svg.__init__
def _track(self, *a, **k):
    _init(self, *a, **k); made.append(self)
common.Svg.__init__ = _track
import home, database, buildspec
bad = [(s.label, s.check()) for s in made if s.check()]
for label, problems in bad:
    print(f"layout: {label[:70]}", *problems, sep="\n  ")
here = os.path.dirname(os.path.abspath(__file__))
for name, mod in (("home", home), ("database", database), ("build-spec", buildspec)):
    open(os.path.join(here, f"{name}.html"), "w", encoding="utf-8").write(mod.HTML)
print(f"{len(made)} diagrams, {len(bad)} with layout problems; pages written")
sys.exit(1 if bad else 0)
