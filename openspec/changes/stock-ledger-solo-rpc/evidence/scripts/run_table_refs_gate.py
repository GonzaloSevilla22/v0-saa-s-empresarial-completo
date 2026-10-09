"""Corre el gate real de scripts/ci/check_backend_table_refs.py contra el stack local sin psql en el host:
reemplaza fetch_existing_objects por la misma consulta vía `docker exec ... psql`. Uso (desde la raíz del repo):
  python openspec/changes/stock-ledger-solo-rpc/evidence/scripts/run_table_refs_gate.py"""
import subprocess, sys
from pathlib import Path
sys.path.insert(0, "scripts/ci")
import check_backend_table_refs as gate

CID = "supabase_db_v0-saa-s-empresarial-completo"

def fetch(dsn):
    out = subprocess.run(
        ["docker", "exec", "-i", CID, "psql", "-U", "postgres", "-d", "postgres", "-At", "-F", "\t", "-c", gate._EXISTING_OBJECTS_SQL],
        capture_output=True, text=True, check=True,
    ).stdout
    tables, functions = set(), set()
    for line in out.splitlines():
        if not line.strip():
            continue
        kind, schema, name = line.rstrip("\r").split("\t")
        schema, name = schema.strip().lower(), name.strip().lower()
        target = tables if kind == "T" else functions
        target.add(f"{schema}.{name}")
        if schema == "public":
            target.add(name)
    return tables, functions

gate.fetch_existing_objects = fetch
# El venv local vive en backend/.venv (en CI no existe): se excluye del escaneo.
_orig_iter = gate.iter_backend_files
gate.iter_backend_files = lambda root: [f for f in _orig_iter(root) if ".venv" not in f.parts]
sys.exit(gate.main(["--dsn", "docker-exec"]))
