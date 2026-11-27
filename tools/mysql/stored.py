"""The store step of tools/mysql/roundtrip.py: a model stored in a fresh store (the cortex installed, engine_mysql plugged
in) the real way, the app opening a turn and engine_mysql_service writing under it, then read back as
engine_mysql_service (the plugin reads its own rows to write a design back)."""
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(HERE)), "engines", "mysql"))
import rows  # noqa: E402
from sf.fixture import as_role, new_design, plugin_turn  # noqa: E402
from sf.plugin import plug_folder  # noqa: E402
from sf.schema import cortex_sql, script  # noqa: E402
from sf.store import Store  # noqa: E402


def round_trip_store(model, image, flavor=None):
    """(the model read back from the store, the number of rows written); a design of the flavor named, or the image's."""
    version = re.search(r":(\d+\.\d+)", image).group(1)
    flavor = flavor or ("percona" if "percona" in image else "mysql")
    with Store("sf-mysql-store") as store:
        store.sql(script(cortex_sql()))
        plug_folder(store, "engines/mysql")
        design, branch = new_design(store, f"roundtrip_{flavor}_{version}".replace(".", "_"), "mysql", version, flavor)
        sql, n = rows.insert_sql(model, design)
        plugin_turn(store, design, branch, sql, "engine_mysql_service")
        back = json.loads(store.sql(as_role("engine_mysql_service", rows.select_sql(design) + ";"))[1].strip())
    return rows.model_from(back), n
