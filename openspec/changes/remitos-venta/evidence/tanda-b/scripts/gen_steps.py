"""Genera un .sh por paso `run:` del job validate-kpis, en el orden real."""
import pathlib
import re

import yaml

WT = pathlib.Path("C:/Users/Usuario/Desktop/EIE/wt-remitos")
OUT = pathlib.Path("C:/Users/Usuario/Desktop/EIE/scratchpad-remitos/b/steps")
OUT.mkdir(parents=True, exist_ok=True)
for f in OUT.glob("*"):
    f.unlink()

d = yaml.safe_load((WT / ".github/workflows/KPI_Validation.yml").read_text(encoding="utf-8"))
steps = d["jobs"]["validate-kpis"]["steps"]
index = []
for i, st in enumerate(steps, start=1):
    run = st.get("run")
    name = st.get("name") or ""
    if not run or name == "Start Supabase":
        continue
    body = re.sub(r"(?<![\w/.'-])supabase (db reset|start|stop|status)", r"npx supabase \1", run)
    idx = f"{i - 1:03d}"
    (OUT / f"{idx}.sh").write_text("set -e\n" + body, encoding="utf-8", newline="\n")
    index.append(f"{idx}\t{name}")
(OUT / "index.txt").write_text("\n".join(index) + "\n", encoding="utf-8", newline="\n")
print(len(index), "pasos")
