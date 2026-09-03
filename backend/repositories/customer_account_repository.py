"""
Repository para C-30 — CustomerAccount / PaymentReceived.

JWT-passthrough via base.py (conexión ya configurada con claims del usuario).
Mutaciones via SELECT rpc_...(args) → SECURITY DEFINER RPCs.
Lecturas de saldo/historial via SELECT directo (RLS SELECT aplica).
"""
from __future__ import annotations

import json

import asyncpg

from backend.repositories.base import BaseRepository


def _jsonb(value) -> dict:
    """asyncpg devuelve jsonb como str cuando no hay codec registrado."""
    return json.loads(value) if isinstance(value, str) else value


class CustomerAccountRepository(BaseRepository):
    """Repository para cuentas corrientes de clientes — JWT-passthrough via base.py."""

    # cobranzas-panel (D3): traducción por diccionario a columna — el criterio
    # de orden JAMÁS se interpola desde el input; un valor fuera del dominio
    # (que Pydantic ya rechaza en el router vía Literal) cae al default.
    _RECEIVABLES_SORT_COLUMNS: dict[str, str] = {
        "balance": "balance",
        "days_since_last_charge": "days_since_last_charge",
        "days_since_last_payment": "days_since_last_payment",
        "client_name": "client_name",
    }

    # cobranzas-vencimientos (task 7.2): filtro por tramo resuelto EN el
    # servidor, traducido por diccionario a predicado — el input JAMÁS se
    # interpola (el router ya lo acota con Literal; un valor fuera del
    # diccionario cae a "sin filtro"). El predicado se aplica al listado Y al
    # COUNT: el filtro es sobre el conjunto completo, no sobre la página.
    _RECEIVABLES_BUCKET_FILTERS: dict[str, str] = {
        "overdue": "overdue_total > 0",
        "current": "amount_current > 0",
        "overdue_1_30": "amount_overdue_1_30 > 0",
        "overdue_31_60": "amount_overdue_31_60 > 0",
        "overdue_60_plus": "amount_overdue_60_plus > 0",
        "no_due_date": "amount_no_due_date > 0",
    }

    # cobranzas-vencimientos (D4/D7): derivación FIFO por línea de flotación
    # para el importe abierto por movimiento — cargo = 'sale' + adjustment
    # POSITIVO (nunca por signo: un payment_received_reversal es positivo y
    # NO es cargo), crédito = suma negada del resto. Este bloque se comparte
    # LITERAL entre list_movements y list_movements_page (D7: los derivados
    # viajan por LAS DOS queries — deuda de duplicación declarada, ver
    # design.md D7).
    _MOVEMENT_OPEN_ITEMS_CTE = """
            WITH pool AS (
              SELECT COALESCE(SUM(-m.amount), 0) AS credit
              FROM public.customer_account_movements m
              WHERE m.customer_account_id = $1::uuid AND m.account_id = $2::uuid
                AND NOT (m.movement_type = 'sale' OR (m.movement_type = 'adjustment' AND m.amount > 0))
            ),
            open_items AS (
              SELECT m.id,
                     LEAST(m.amount, GREATEST(0::numeric,
                       SUM(m.amount) OVER (
                         ORDER BY COALESCE(m.due_date, (m.created_at AT TIME ZONE 'America/Argentina/Mendoza')::date),
                                  m.created_at, m.id
                       ) - (SELECT credit FROM pool)
                     )) AS open_amount
              FROM public.customer_account_movements m
              WHERE m.customer_account_id = $1::uuid AND m.account_id = $2::uuid
                AND (m.movement_type = 'sale' OR (m.movement_type = 'adjustment' AND m.amount > 0))
            )
    """

    # Derivados de vencimiento por fila: ausentes (NULL) para todo movimiento
    # que no es cargo; un cargo saldado (open 0) tampoco se presenta vencido.
    _MOVEMENT_DUE_DERIVATIVES = """
              oi.open_amount,
              CASE WHEN oi.id IS NOT NULL AND cam.due_date IS NOT NULL
                   THEN (cam.due_date < public.reporting_local_today() AND oi.open_amount > 0)
                   END AS is_overdue,
              CASE WHEN oi.id IS NOT NULL AND cam.due_date IS NOT NULL
                        AND cam.due_date < public.reporting_local_today() AND oi.open_amount > 0
                   THEN (public.reporting_local_today() - cam.due_date)
                   END AS days_overdue
    """

    async def list_receivables_page(
        self,
        account_id: str,
        *,
        page: int,
        size: int,
        sort: str = "balance",
        sort_dir: str = "desc",
        bucket: str | None = None,
    ) -> dict:
        """cobranzas-panel (tasks 3.2) + cobranzas-vencimientos (task 7.2).

        El predicado de "quién es deudor" (balance > 0, cliente no borrado,
        tenant) vive UNA sola vez en rpc_receivables_report (D1/D2) — acá no
        se re-declara nada: sólo orden + filtro por tramo (diccionario, nunca
        interpolación) + envelope estándar via paginate().
        El guard de membresía es el P0401 del propio RPC.
        """
        sort_column = self._RECEIVABLES_SORT_COLUMNS.get(sort, "balance")
        direction = "ASC" if sort_dir == "asc" else "DESC"
        # Deudores sin cargo/cobro (OQ-4: deuda nacida de adjustment) van al
        # final al ordenar por antigüedad — el NULL no es "0 días".
        nulls = (
            " NULLS LAST"
            if sort_column in ("days_since_last_charge", "days_since_last_payment")
            else ""
        )
        bucket_predicate = self._RECEIVABLES_BUCKET_FILTERS.get(bucket or "")
        where = f"WHERE {bucket_predicate}" if bucket_predicate else ""
        return await self.paginate(
            f"""
            SELECT *
            FROM public.rpc_receivables_report($1::uuid)
            {where}
            ORDER BY {sort_column} {direction}{nulls}, client_id ASC
            """,
            f"""
            SELECT COUNT(*)
            FROM public.rpc_receivables_report($1::uuid)
            {where}
            """,
            account_id,
            page=page,
            size=size,
        )

    async def get_receivables_summary(self, account_id: str) -> dict:
        """cobranzas-panel (task 3.3, D2) + cobranzas-vencimientos: el resumen
        agrega SOBRE el mismo RPC del detalle — sin un segundo RPC ni un
        segundo predicado de deudor, para que el total (y ahora el vencido)
        de la cabecera cierre SIEMPRE contra la suma de la tabla."""
        row = await self.fetchrow(
            """
            SELECT COALESCE(SUM(balance), 0)       AS total_receivable,
                   COALESCE(SUM(overdue_total), 0) AS overdue_total,
                   COUNT(*)::int                   AS debtor_count
            FROM public.rpc_receivables_report($1::uuid)
            """,
            account_id,
        )
        return dict(row)

    async def get_default_payment_terms(self, account_id: str) -> int | None:
        """cobranzas-vencimientos (task 7.8): lee el plazo por defecto de la
        cuenta. Lectura directa (RLS aplica); la escritura va SIEMPRE por la
        RPC con guard is_account_writer."""
        return await self._conn.fetchval(
            "SELECT default_payment_terms_days FROM public.accounts WHERE id = $1::uuid",
            account_id,
        )

    async def set_default_payment_terms(self, days: int | None) -> None:
        """cobranzas-vencimientos (task 7.8): escribe el plazo por defecto vía
        rpc_set_default_payment_terms (SECURITY DEFINER, guard
        is_account_writer → P0401; P0400 si negativo; NULL limpia)."""
        await self._conn.fetchval(
            "SELECT public.rpc_set_default_payment_terms($1::smallint)",
            days,
        )

    async def create_account(self, client_id: str) -> dict:
        """Invoca rpc_create_customer_account(p_client_id) → crea/retorna la cuenta."""
        row = await self.fetchrow(
            "SELECT public.rpc_create_customer_account($1::uuid) AS result",
            client_id,
        )
        return _jsonb(row["result"])

    async def get_account(self, account_id: str, client_id: str) -> asyncpg.Record | None:
        """Lee la fila de customer_accounts para (account_id, client_id)."""
        return await self.fetchrow(
            """
            SELECT *
            FROM public.customer_accounts
            WHERE account_id = $1::uuid
              AND client_id  = $2::uuid
            """,
            account_id,
            client_id,
        )

    async def list_movements(
        self,
        customer_account_id: str,
        account_id: str,
        limit: int = 50,
        offset: int = 0,
    ) -> list[dict]:
        """Lista customer_account_movements paginados por (customer_account_id, created_at).

        Usado por `get_account` (vista combinada saldo+historial) — mantiene
        su firma limit/offset. Para el endpoint dedicado de listado usar
        `list_movements_page` (v3-api-standards §2.7).

        fix/tenancy-bank-accounts-leak (2026-08-22): `account_id` obligatorio
        — antes solo filtraba por customer_account_id (IDOR: un id de OTRO
        tenant devolvía sus movimientos). account_id está desnormalizado en
        la tabla (RLS), así que el filtro es directo, sin JOIN.

        caja-compras-cobranzas (OQ-1, task 8.5): payment_method resuelto por
        LEFT JOIN a payments_received (reference_id = payments_received.id,
        sólo pobla cuando movement_type='payment_received') — NULL para el
        resto de los tipos y para los cobros históricos, sin backfill.

        cobranzas-catalogo-pagos (D3, task 7.2): el JOIN se extiende a
        payment_methods.name — payments_received.payment_method (texto) ya
        no existe, la columna se dropeó. El alias del resultado sigue
        llamándose payment_method (mismo campo, mismo consumidor) pero ahora
        expone el NOMBRE que el usuario configuró en su catálogo, resuelto a
        través de payment_method_id. Un cobro sin imputar (payment_method_id
        NULL) o imputado a un método desde entonces dado de baja (is_active
        pasa a false, pero la fila del catálogo sigue existiendo) resuelve
        igual por el LEFT JOIN — la baja es desactivación, nunca borrado.

        cobranzas-reverso (D12, hallazgo del propio TDD del apply — task
        13.1): esta es la query que alimenta la vista combinada de
        GET /clientes/{id}/cuenta (get_account → CustomerAccountHistory en
        la pantalla real), NO list_movements_page — que sólo sirve al
        endpoint paginado dedicado. Sin los mismos 4 derivados acá, la
        acción "Anular" nunca aparecería en la pantalla que el usuario
        realmente mira: is_reversible/is_reversal_blocked por defecto en
        False la habrían dejado siempre oculta.
        """
        return await self.fetch(
            f"""
            {self._MOVEMENT_OPEN_ITEMS_CTE}
            SELECT cam.*, pm.name AS payment_method,
              {self._MOVEMENT_DUE_DERIVATIVES},
              (cam.movement_type = 'payment_received' AND EXISTS (
                SELECT 1 FROM public.payments_received pr2 WHERE pr2.id = cam.reference_id
              )) AS is_reversible,
              EXISTS (
                SELECT 1
                FROM public.cash_movements cm
                JOIN public.cash_sessions cs ON cs.id = cm.session_id
                WHERE cm.reference_id = cam.reference_id AND cm.movement_type = 'payment_received'
                  AND NOT EXISTS (
                    SELECT 1 FROM public.cash_sessions cs_open
                    WHERE cs_open.cashbox_id = cs.cashbox_id AND cs_open.status = 'open'
                  )
              ) AS is_reversal_blocked,
              EXISTS (
                SELECT 1 FROM public.cash_movements cm2
                WHERE cm2.reference_id = cam.reference_id AND cm2.movement_type = 'payment_received'
              ) AS has_cash_movement,
              EXISTS (
                SELECT 1 FROM public.bank_movements bm
                WHERE bm.source_doc_type = 'payment_received' AND bm.source_doc_ref = cam.reference_id
              ) AS has_bank_movement
            FROM public.customer_account_movements cam
            LEFT JOIN open_items oi ON oi.id = cam.id
            LEFT JOIN public.payments_received pr
              ON pr.id = cam.reference_id AND cam.movement_type = 'payment_received'
            LEFT JOIN public.payment_methods pm
              ON pm.id = pr.payment_method_id
            WHERE cam.customer_account_id = $1::uuid AND cam.account_id = $2::uuid
            ORDER BY cam.created_at DESC
            LIMIT $3
            OFFSET $4
            """,
            customer_account_id,
            account_id,
            limit,
            offset,
        )

    async def list_movements_page(
        self,
        customer_account_id: str,
        *,
        account_id: str,
        page: int,
        size: int,
    ) -> dict:
        """v3-api-standards §2.7: envelope estándar {items,total,page,pages}
        para GET /customer-accounts/{id}/movements (reemplaza limit/offset +
        lista plana).

        fix/tenancy-bank-accounts-leak: `account_id` obligatorio — mismo IDOR
        que list_movements (ver nota ahí). caja-compras-cobranzas (OQ-1):
        mismo LEFT JOIN a payments_received que list_movements.

        cobranzas-reverso (D12, task 9.2): suma los derivados —
        `is_reversible` (el movimiento es 'payment_received' y su documento
        sigue vivo), `is_reversal_blocked` (tiene movimiento de caja y esa
        caja no tiene ninguna sesión abierta) — con el MISMO predicado que
        evalúa `rpc_reverse_payment_received`, nunca columnas denormalizadas
        (regla D5 de delete-guard-ledgers). `has_cash_movement`/
        `has_bank_movement` siguen el MISMO molde que purchase_repository.py
        (has_cash_movement/has_bank_movement de PurchaseOperationOut) — el
        diálogo de anulación los necesita para enumerar sólo las patas que
        aplican; `payment_method` NO sirve para esto (NULL en el 100% de los
        pagos históricos, D3)."""
        return await self.paginate(
            f"""
            {self._MOVEMENT_OPEN_ITEMS_CTE}
            SELECT cam.*, pm.name AS payment_method,
              {self._MOVEMENT_DUE_DERIVATIVES},
              (cam.movement_type = 'payment_received' AND EXISTS (
                SELECT 1 FROM public.payments_received pr2 WHERE pr2.id = cam.reference_id
              )) AS is_reversible,
              EXISTS (
                SELECT 1
                FROM public.cash_movements cm
                JOIN public.cash_sessions cs ON cs.id = cm.session_id
                WHERE cm.reference_id = cam.reference_id AND cm.movement_type = 'payment_received'
                  AND NOT EXISTS (
                    SELECT 1 FROM public.cash_sessions cs_open
                    WHERE cs_open.cashbox_id = cs.cashbox_id AND cs_open.status = 'open'
                  )
              ) AS is_reversal_blocked,
              EXISTS (
                SELECT 1 FROM public.cash_movements cm2
                WHERE cm2.reference_id = cam.reference_id AND cm2.movement_type = 'payment_received'
              ) AS has_cash_movement,
              EXISTS (
                SELECT 1 FROM public.bank_movements bm
                WHERE bm.source_doc_type = 'payment_received' AND bm.source_doc_ref = cam.reference_id
              ) AS has_bank_movement
            FROM public.customer_account_movements cam
            LEFT JOIN open_items oi ON oi.id = cam.id
            LEFT JOIN public.payments_received pr
              ON pr.id = cam.reference_id AND cam.movement_type = 'payment_received'
            LEFT JOIN public.payment_methods pm
              ON pm.id = pr.payment_method_id
            WHERE cam.customer_account_id = $1::uuid AND cam.account_id = $2::uuid
            ORDER BY cam.created_at DESC
            """,
            """
            SELECT COUNT(*)
            FROM public.customer_account_movements cam
            WHERE cam.customer_account_id = $1::uuid AND cam.account_id = $2::uuid
            """,
            customer_account_id,
            account_id,
            page=page,
            size=size,
        )

    async def reverse_payment_received(self, payment_id: str, reason: str | None) -> dict:
        """cobranzas-reverso (task 9.1): invoca rpc_reverse_payment_received.

        Sin idempotency_key (D9 — idempotente por ausencia del documento).
        `account_id` NO viaja como parámetro: la RPC lo resuelve internamente
        de la sesión (SECURITY DEFINER + current_account_ids()) y filtra por
        él antes de tocar cualquier libro (D8) — el mismo patrón que
        rpc_delete_expense."""
        row = await self.fetchrow(
            "SELECT public.rpc_reverse_payment_received($1::uuid, $2::text) AS result",
            payment_id,
            reason,
        )
        return _jsonb(row["result"])

    async def register_payment_received(
        self,
        idempotency_key: str,
        client_id: str,
        amount: float,
        reference_sale_id: str | None = None,
        payment_method_id: str | None = None,
        bank_account_id: str | None = None,
        cash_session_id: str | None = None,
    ) -> dict:
        """Invoca rpc_register_payment_received → registra cobro en la cuenta del cliente.

        cobranzas-catalogo-pagos (D1): payment_method (text) → payment_method_id
        (uuid) en la MISMA posición — el kind se deriva en el servidor desde el
        catálogo. Verificado contra la firma nueva: un desplazamiento
        posicional acá mandaría el uuid al parámetro equivocado.
        caja-compras-cobranzas (D5): cash_session_id trailing — NULL = no-op,
        el cobro no toca caja.
        """
        row = await self.fetchrow(
            """
            SELECT public.rpc_register_payment_received(
              $1::text, $2::uuid, $3::numeric, $4::uuid, $5::uuid, $6::uuid, $7::uuid
            ) AS result
            """,
            idempotency_key,
            client_id,
            amount,
            reference_sale_id,
            payment_method_id,
            bank_account_id,
            cash_session_id,
        )
        return _jsonb(row["result"])
