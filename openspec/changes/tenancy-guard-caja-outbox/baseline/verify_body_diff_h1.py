# -*- coding: utf-8 -*-
"""Gate de integridad de función — verificación mecánica en la OTRA dirección.

El baseline vivo de prod es el punto de partida de las dos reescrituras de
`supabase/migrations/20261013000001_tenancy_guard_caja_sesion.sql`. Este script
prueba lo contrario: extrae los dos cuerpos DE LA MIGRACIÓN, les quita las
únicas adiciones admisibles —el bloque de guard delimitado por los marcadores
box-drawing y las variables que declara— y los diffea contra el baseline. El
resultado tiene que ser BYTE IDÉNTICO.

Es la verificación que el design pide en la tabla de riesgos: "extraer el
cuerpo de la migración, quitarle el guard, diffear contra el baseline → única
diferencia admisible = el guard". Sin ella, un bloque perdido en la reescritura
(como el `credit` de C-30 en julio) pasaría desapercibido.

Normaliza CRLF → LF antes de comparar: el working tree está en CRLF por
core.autocrlf=true, y el baseline se capturó con LF.

Uso:  python openspec/changes/tenancy-guard-caja-outbox/baseline/verify_body_diff_h1.py
Salida: rc=0 y una línea OK por función; rc=1 con el diff unificado si difieren.
"""
from __future__ import annotations

import difflib
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parents[4]
MIGRATION = ROOT / "supabase" / "migrations" / "20261013000001_tenancy_guard_caja_sesion.sql"
BASELINE_DIR = ROOT / "openspec" / "changes" / "tenancy-guard-caja-outbox" / "baseline"

# Adiciones admisibles en el bloque DECLARE, literales. Todo lo demás que
# difiera del baseline es un error.
DECLARE_ADDITIONS = {
    "_c29_confirm_order_core": (
        "  -- tenancy-guard-caja-outbox (h1, capa 1): mismos nombres que en\n"
        "  -- rpc_create_sale_operation_v2, de donde se copia el predicado.\n"
        "  v_cash_session_status  text;\n"
        "  v_cash_session_branch  uuid;\n"
    ),
    "c28_register_cash_movement": (
        "  -- tenancy-guard-caja-outbox (h1, capa 2): cuenta dueña de la sesión.\n"
        "  v_owner_account_id uuid;\n"
    ),
}

GUARD_OPEN = "  -- ╔═══ tenancy-guard-caja-outbox"
GUARD_CLOSE = "  -- ╚"


def read_lf(path: pathlib.Path) -> str:
    return path.read_text(encoding="utf-8").replace("\r\n", "\n")


def extract_from_migration(sql: str, fn: str) -> str:
    """Devuelve el CREATE OR REPLACE completo de `fn`, tal cual está en la migración."""
    start = sql.index("CREATE OR REPLACE FUNCTION public.%s(" % fn)
    end = sql.index("\n$function$;\n", start) + len("\n$function$;\n")
    return sql[start:end]


def extract_from_baseline(sql: str, fn: str) -> str:
    start = sql.index("CREATE OR REPLACE FUNCTION public.%s(" % fn)
    return sql[start:]


def strip_guard(body: str, fn: str) -> str:
    lines = body.split("\n")
    out, inside, removed_block = [], False, False
    for line in lines:
        if line.startswith(GUARD_OPEN):
            inside = True
            removed_block = True
            continue
        if inside:
            if line.startswith(GUARD_CLOSE):
                inside = False
            continue
        out.append(line)
    if not removed_block:
        raise SystemExit("FALLO: no se encontró el bloque de guard en %s" % fn)

    text = "\n".join(out)
    # El bloque de guard va precedido y seguido de una línea en blanco; al
    # quitarlo quedan dos consecutivas donde el baseline tiene una.
    text = text.replace("\n\n\n", "\n\n")

    addition = DECLARE_ADDITIONS[fn]
    if addition not in text:
        raise SystemExit("FALLO: no se encontró la declaración de variables del guard en %s" % fn)
    text = text.replace(addition, "", 1)

    # pg_get_functiondef no emite el `;` final; la migración sí.
    assert text.endswith("$function$;\n"), "cierre inesperado en %s" % fn
    return text[: -len("$function$;\n")] + "$function$\n"


def main() -> int:
    migration = read_lf(MIGRATION)
    rc = 0
    for fn, baseline_file in (
        ("_c29_confirm_order_core", "_c29_confirm_order_core.sql"),
        ("c28_register_cash_movement", "c28_register_cash_movement.sql"),
    ):
        got = strip_guard(extract_from_migration(migration, fn), fn)
        want = extract_from_baseline(read_lf(BASELINE_DIR / baseline_file), fn)
        if got == want:
            print("OK  %-28s cuerpo sin el guard == baseline vivo de prod (%d bytes)" % (fn, len(want)))
        else:
            rc = 1
            print("FALLA %s — el cuerpo diverge del baseline en algo que NO es el guard:" % fn)
            sys.stdout.writelines(
                difflib.unified_diff(
                    want.splitlines(keepends=True),
                    got.splitlines(keepends=True),
                    fromfile="baseline/%s" % baseline_file,
                    tofile="migracion/%s (sin guard)" % fn,
                )
            )
    return rc


if __name__ == "__main__":
    sys.exit(main())
