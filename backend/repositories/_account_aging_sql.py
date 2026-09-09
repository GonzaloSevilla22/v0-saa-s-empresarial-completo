"""Fragmento de SQL de aging/FIFO compartido entre CustomerAccountRepository
y SupplierAccountRepository (cobranzas-vencimientos D7, refactor).

Hallazgo (design.md D7 de cobranzas-vencimientos): el bloque FIFO (CTE `pool`
+ `open_items`) y los derivados de vencimiento por fila (`open_amount`,
`is_overdue`, `days_overdue`) estaban copiados LITERAL en 4 sitios — 2x2,
cliente/proveedor × list_movements/list_movements_page — variando sólo el
nombre de tabla/columna de cuenta, el `movement_type` que cuenta como cargo
('sale' vs 'purchase') y el alias de la tabla en la query externa ('cam' vs
'sam'). `build_aging_cte()` es la ÚNICA definición; los 4 sitios la consumen.

Fuera de este refactor (ver deviations del ítem): `rpc_receivables_report`
(SQL, no Python) tiene su propia copia del mismo cálculo — no se toca.
"""
from __future__ import annotations


def build_aging_cte(
    *,
    account_column: str,
    movements_table: str,
    charge_type: str,
    outer_alias: str,
) -> tuple[str, str]:
    """Arma los dos fragmentos de SQL de aging para una "parte" (cliente o
    proveedor).

    Args:
        account_column: columna de cuenta en la tabla de movimientos —
            'customer_account_id' | 'supplier_account_id'.
        movements_table: tabla de movimientos —
            'customer_account_movements' | 'supplier_account_movements'.
        charge_type: `movement_type` que cuenta como cargo (además de
            `adjustment` positivo) — 'sale' | 'purchase'.
        outer_alias: alias de la tabla de movimientos en la query EXTERNA
            (fuera de este CTE) — 'cam' | 'sam'. Sólo lo usa
            `due_derivatives`, que referencia `{outer_alias}.due_date`.

    Returns:
        (open_items_cte, due_derivatives):
          - open_items_cte: el `WITH pool AS (...), open_items AS (...)`
            completo — su alias interno es siempre 'm' (no depende de
            `outer_alias`), así que el texto es idéntico al que vivía
            duplicado salvo por `account_column`/`movements_table`/
            `charge_type`.
          - due_derivatives: las 3 columnas derivadas (`open_amount`,
            `is_overdue`, `days_overdue`) que la query externa agrega al
            SELECT, referenciando `oi` (de `open_items_cte`) y
            `{outer_alias}.due_date`.
    """
    open_items_cte = f"""
            WITH pool AS (
              SELECT COALESCE(SUM(-m.amount), 0) AS credit
              FROM public.{movements_table} m
              WHERE m.{account_column} = $1::uuid AND m.account_id = $2::uuid
                AND NOT (m.movement_type = '{charge_type}' OR (m.movement_type = 'adjustment' AND m.amount > 0))
            ),
            open_items AS (
              SELECT m.id,
                     LEAST(m.amount, GREATEST(0::numeric,
                       SUM(m.amount) OVER (
                         ORDER BY COALESCE(m.due_date, (m.created_at AT TIME ZONE 'America/Argentina/Mendoza')::date),
                                  m.created_at, m.id
                       ) - (SELECT credit FROM pool)
                     )) AS open_amount
              FROM public.{movements_table} m
              WHERE m.{account_column} = $1::uuid AND m.account_id = $2::uuid
                AND (m.movement_type = '{charge_type}' OR (m.movement_type = 'adjustment' AND m.amount > 0))
            )
    """
    due_derivatives = f"""
              oi.open_amount,
              CASE WHEN oi.id IS NOT NULL AND {outer_alias}.due_date IS NOT NULL
                   THEN ({outer_alias}.due_date < public.reporting_local_today() AND oi.open_amount > 0)
                   END AS is_overdue,
              CASE WHEN oi.id IS NOT NULL AND {outer_alias}.due_date IS NOT NULL
                        AND {outer_alias}.due_date < public.reporting_local_today() AND oi.open_amount > 0
                   THEN (public.reporting_local_today() - {outer_alias}.due_date)
                   END AS days_overdue
    """
    return open_items_cte, due_derivatives
