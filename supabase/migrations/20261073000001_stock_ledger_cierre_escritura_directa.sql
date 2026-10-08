-- =============================================================================
-- stock-ledger-solo-rpc — TANDA A (G1): cerrar la escritura directa al ledger
-- de stock
-- =============================================================================
--
-- Governance ALTA (ledger de stock + revocación de privilegios, con un tramo
-- cross-tenant). Sign-off del PO 2026-10-08: "firmo el candidato con las
-- recomendaciones" (5 decisiones; la 3 fija esta tanda como PR chico y
-- separado) y "aplicá las tres recomendaciones y arrancá la tanda A".
-- Procedencia: openspec/changes/stock-ledger-solo-rpc/ (proposal, design D1-D3,
-- specs/inventory-single-ledger) y el candidato homónimo de CHANGES.md
-- (diagnóstico 2026-10-03: red team de remitos-compra y remitos-venta).
--
-- EL HALLAZGO. `authenticated` conservaba INSERT/UPDATE/DELETE/TRUNCATE a nivel
-- TABLA sobre `public.stock_movements` y `public.branch_stock`
-- (relacl `authenticated=arwdDxtm`, 2026-10-08), y había tres policies
-- permisivas de escritura:
--   · stock_movements_account_insert — cualquier MIEMBRO de la cuenta, `viewer`
--     incluido, podía insertar movimientos con el account_id de su cuenta;
--   · branch_stock_writer_insert / branch_stock_writer_update — 7 de los 8
--     roles (is_account_writer) podían crear y PISAR saldos sin rastro en el
--     ledger.
-- Controles EJECUTADOS en el stack local antes de esta migración
-- (openspec/changes/stock-ledger-solo-rpc/evidence/logs/01_*):
--   (i)   un `viewer` forja una fila reference_type='sale' y llama a
--         rpc_reverse_stock_movement sobre ella: el stock SUBE (1 -> 2);
--   (ii)  un `seller` hace UPDATE de branch_stock a otro valor (2 -> 555): pasa,
--         sin ningún movimiento en el ledger;
--   (iii) un escritor de la cuenta A inserta (A, producto de B, sucursal de B,
--         0); la compra siguiente de B de ese producto en esa sucursal se
--         ACUMULA en la fila de A (c21_apply_branch_stock_delta actualiza por
--         (producto, sucursal) sin filtrar cuenta), invisible para B bajo RLS.
--
-- LO QUE HACE (D2 del design) — dos capas, no una:
--   1. DROP POLICY de las tres policies permisivas de escritura. Es la segunda
--      red: si una migración futura hiciera un GRANT amplio sobre el esquema,
--      sin policy permisiva la RLS sigue denegando INSERT/UPDATE/DELETE.
--   2. REVOKE INSERT, UPDATE, DELETE, TRUNCATE de las dos tablas a anon y
--      authenticated. Es la barrera, y la única contra TRUNCATE (la RLS no se
--      aplica a TRUNCATE). `anon` hoy ya no los tiene: se incluye por
--      idempotencia e intención (molde: presupuestos-modulo con `quotes`,
--      20261035000001 con las tablas de public).
--   3. REVOKE EXECUTE de rpc_reverse_stock_movement(uuid, text, text) a PUBLIC,
--      anon y authenticated. Sus únicos callers son rpc_delete_sale_operation y
--      rpc_delete_purchase_operation, ambas SECURITY DEFINER (corren como
--      postgres, que conserva EXECUTE); el backend sólo la nombra en un
--      comentario y el frontend nunca. La función NO valida rol: confía en su
--      caller, así que dejarla pública era una primitiva de reposición de
--      stock sin dueño.
--
-- QUÉ NO TOCA.
--   · NINGUNA función se reescribe (cero CREATE OR REPLACE). La reversa pasa a
--     interna sin cambiar su cuerpo.
--   · stock_movements_account_select y branch_stock_member_select (lectura por
--     cuenta) quedan: el historial de /stock y el panel de movimientos las usan.
--   · stock_movements_no_update / stock_movements_no_delete (`USING false`) se
--     CONSERVAN: tras el REVOKE son redundantes, cuestan cero, RN-21 las cita
--     como su mecanismo y el gate afirma la forma exacta de la tabla de
--     policies (D2). Defensa en profundidad ante un re-GRANT accidental.
--   · service_role conserva sus privilegios (contexto de servicio del backend).
--   · Las acciones referenciales de las FKs (ON DELETE CASCADE / SET NULL desde
--     products, branches y auth.users) corren como dueño de la tabla, no como el
--     rol que borra: el borrado de un producto con historial sigue funcionando
--     (lo ejercita el gate, bloque (e)).
--
-- MEDIDO ANTES (todo sólo lectura, prod 2026-10-08): 0 escrituras directas a las
-- dos tablas en frontend/, backend/, supabase/functions/ y scripts; 0 escrituras
-- directas y 0 llamadas directas a rpc_apply_product_stock_delta /
-- rpc_reverse_stock_movement / rpc_adjust_branch_stock / rpc_transfer_stock en
-- 14 días de logs de PostgREST (2026-09-20 -> 10-03, con control positivo). Todo
-- lo que escribe es SECURITY DEFINER o un helper INVOKER sin EXECUTE para
-- authenticated. Exposición real hoy: baja (41 cuentas, 0 multiusuario); se
-- vuelve explotable con el primer usuario invitado, por eso el change entra antes.
--
-- RESIDUO ABIERTO HASTA LA TANDA B (declarado). Esta tanda cierra la FORJA y la
-- REVERSA PÚBLICA, no el ajuste sin rol: hasta que 20261074000001 reescriba el
-- núcleo, rpc_apply_product_stock_delta (incluido p_log_movement = false, que
-- cambia el saldo SIN movimiento), rpc_stock_adjustment y
-- rpc_adjust_branch_stock siguen aceptando a cualquier escritor, sin rol ni
-- motivo. Con la forja y la reversa cerradas ya no fabrican stock por
-- encadenamiento, pero sí permiten mover un saldo sin el rol firmado. Población
-- afectada hoy: cero (0 cuentas multiusuario).
--
-- ROLLBACK (no hay datos que deshacer): una migración nueva que re-otorgue
--   GRANT INSERT, UPDATE, DELETE, TRUNCATE ON public.stock_movements, public.branch_stock TO authenticated;
--   GRANT EXECUTE ON FUNCTION public.rpc_reverse_stock_movement(uuid, text, text) TO authenticated;
-- y re-cree las tres policies con su definición viva (design.md, Anexo B):
--   CREATE POLICY stock_movements_account_insert ON public.stock_movements
--     FOR INSERT TO authenticated
--     WITH CHECK (account_id IN (SELECT current_account_ids() AS current_account_ids));
--   CREATE POLICY branch_stock_writer_insert ON public.branch_stock
--     FOR INSERT TO authenticated WITH CHECK (is_account_writer(account_id));
--   CREATE POLICY branch_stock_writer_update ON public.branch_stock
--     FOR UPDATE TO authenticated
--     USING (is_account_writer(account_id)) WITH CHECK (is_account_writer(account_id));
--
-- Idempotente: DROP POLICY IF EXISTS y REVOKE repetido son no-op.
-- Gate: supabase/tests/test_stock_ledger_solo_rpc.sql (KPI_Validation.yml).
-- Sin superficie frontend (declarado en el proposal).
-- =============================================================================

-- ── 1. Policies permisivas de escritura ─────────────────────────────────────
DROP POLICY IF EXISTS stock_movements_account_insert ON public.stock_movements;
DROP POLICY IF EXISTS branch_stock_writer_insert     ON public.branch_stock;
DROP POLICY IF EXISTS branch_stock_writer_update     ON public.branch_stock;

-- ── 2. Privilegios de escritura a nivel tabla ───────────────────────────────
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON TABLE public.stock_movements FROM anon, authenticated;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON TABLE public.branch_stock    FROM anon, authenticated;

-- ── 3. La reversa deja de ser pública ───────────────────────────────────────
-- Sin DROP FUNCTION (resetearía la ACL a EXECUTE para PUBLIC) y sin tocar su
-- cuerpo. Sus callers (rpc_delete_sale_operation / rpc_delete_purchase_operation)
-- son SECURITY DEFINER y siguen ejecutándola como postgres.
REVOKE EXECUTE ON FUNCTION public.rpc_reverse_stock_movement(uuid, text, text) FROM PUBLIC, anon, authenticated;

-- ── 4. Documentación en el catálogo ─────────────────────────────────────────
COMMENT ON TABLE public.branch_stock IS
  'Per-branch inventory ledger. Tracks quantity of each product in each branch.
   Rows are created lazily on first movement. Dual-ledger: when a sale
   or purchase has branch_id, this table is updated instead of products.stock.
   stock-ledger-solo-rpc (tanda A, 2026-10): SOLO SE ESCRIBE DESDE FUNCIONES SECURITY DEFINER
   (o helpers INVOKER sin EXECUTE para la app). anon/authenticated no tienen INSERT/UPDATE/DELETE/TRUNCATE
   y no hay policy permisiva de escritura: solo la de lectura por cuenta (branch_stock_member_select).
   Un PATCH directo de un saldo ya no es posible: todo cambio de saldo pasa por una RPC.';

COMMENT ON TABLE public.stock_movements IS
  'Ledger append-only de movimientos de stock (RN-21). stock-ledger-solo-rpc (tanda A, 2026-10):
   SOLO SE ESCRIBE DESDE FUNCIONES SECURITY DEFINER (o helpers INVOKER sin EXECUTE para la app).
   anon/authenticated no tienen INSERT/UPDATE/DELETE/TRUNCATE; las policies que quedan son la de lectura por cuenta
   (stock_movements_account_select) y las dos qual=false de UPDATE/DELETE, conservadas como segunda red ante un
   re-GRANT accidental. Una fila forjada por PostgREST ya no es posible. La reversa de una venta o compra
   es un contramovimiento nuevo (rpc_reverse_stock_movement, interna), nunca un borrado.';
