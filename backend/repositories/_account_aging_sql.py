"""Fragmento de SQL de aging/FIFO compartido entre CustomerAccountRepository
y SupplierAccountRepository (cobranzas-vencimientos D7, refactor).

Hallazgo (design.md D7 de cobranzas-vencimientos): el bloque FIFO (CTE `pool`
+ `open_items`) y los derivados de vencimiento por fila (`open_amount`,
`is_overdue`, `days_overdue`) estaban copiados LITERAL en 4 sitios — 2x2,
cliente/proveedor × list_movements/list_movements_page — variando sólo el
nombre de tabla/columna de cuenta, el `movement_type` que cuenta como cargo
('sale' vs 'purchase') y el alias de la tabla en la query externa ('cam' vs
'sam'). `build_aging_cte()` es la ÚNICA definición; los 4 sitios la consumen.

edicion-operaciones-con-dinero (tanda A, D9) — EMPAREJAMIENTO de la reversión de un cargo: el crédito de una
reversión (`credit_note` del cliente, `debit_note` del proveedor) cancela PRIMERO los cargos de su misma referencia
y de la misma cuenta corriente, en el orden de la línea de flotación de esos cargos; sólo el remanente va al pozo
general. Sin esto, revertir el cargo de una venta editada o borrada cancelaba el cargo más viejo de la cuenta y no
el propio. Esta definición y la función SQL `_customer_open_items` / `_supplier_open_items` (que alimentan
`rpc_receivables_report`, `rpc_payables_report`, el aviso diario y las dos RPC de cambio de vencimiento) aplican
LA MISMA regla: un gate (`test_aging_reversal_pairing`) las compara sobre el mismo ledger.
"""
from __future__ import annotations


def build_aging_cte(
    *,
    account_column: str,
    movements_table: str,
    charge_type: str,
    reversal_type: str,
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
        reversal_type: `movement_type` de la reversión de un cargo (cuyo crédito se
            empareja con los cargos de su misma referencia) — 'credit_note' | 'debit_note'.
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
                AND NOT (m.movement_type = '{reversal_type}' AND m.reference_id IS NOT NULL)
            ),
            rev AS (
              SELECT m.reference_id, SUM(-m.amount) AS credit
              FROM public.{movements_table} m
              WHERE m.{account_column} = $1::uuid AND m.account_id = $2::uuid
                AND m.movement_type = '{reversal_type}' AND m.reference_id IS NOT NULL
              GROUP BY m.reference_id
            ),
            charges AS (
              SELECT m.id, m.amount, m.due_date, m.created_at, m.reference_id,
                     SUM(m.amount) OVER (
                       PARTITION BY m.reference_id
                       ORDER BY COALESCE(m.due_date, (m.created_at AT TIME ZONE 'America/Argentina/Mendoza')::date),
                                m.created_at, m.id
                     ) AS cum_ref
              FROM public.{movements_table} m
              WHERE m.{account_column} = $1::uuid AND m.account_id = $2::uuid
                AND (m.movement_type = '{charge_type}' OR (m.movement_type = 'adjustment' AND m.amount > 0))
            ),
            net AS (
              SELECT ch.id, ch.due_date, ch.created_at,
                     LEAST(ch.amount, GREATEST(0::numeric, ch.cum_ref - COALESCE(r.credit, 0))) AS net_amount
              FROM charges ch
              LEFT JOIN rev r ON r.reference_id = ch.reference_id
            ),
            remainder AS (
              SELECT COALESCE(SUM(GREATEST(0::numeric, r.credit - COALESCE(t.total, 0))), 0) AS rem
              FROM rev r
              LEFT JOIN (SELECT reference_id, SUM(amount) AS total FROM charges GROUP BY reference_id) t
                     ON t.reference_id = r.reference_id
            ),
            open_items AS (
              SELECT n.id,
                     LEAST(n.net_amount, GREATEST(0::numeric,
                       SUM(n.net_amount) OVER (
                         ORDER BY COALESCE(n.due_date, (n.created_at AT TIME ZONE 'America/Argentina/Mendoza')::date),
                                  n.created_at, n.id
                       ) - (SELECT credit FROM pool) - (SELECT rem FROM remainder)
                     )) AS open_amount
              FROM net n
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
