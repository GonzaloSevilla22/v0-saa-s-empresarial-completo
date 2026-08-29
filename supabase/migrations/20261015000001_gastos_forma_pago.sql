-- =============================================================================
-- gastos-forma-pago — el gasto imputa forma de pago y sus movimientos
-- concilian caja y banco.
-- =============================================================================
--
-- Pedido textual del PO (2026-08-28): "Modificar Módulo Gastos para incluir
-- identificación del gasto, ejemplo efectivo, transferencia y que estos
-- movimientos concilien caja y banco". Firma de sign-off (2026-08-29, "dale,
-- arranca con el apply") sobre los tres hechos que le cambian la experiencia:
--   (a) los 175 gastos históricos ($8.723.710,63) quedan SIN imputar y fuera
--       de la conciliación para siempre — no hay backfill honesto (D7);
--   (b) un gasto que ya impactó caja o banco pasa a ser INMUTABLE: se corrige
--       borrando y recargando (D11, P0423);
--   (c) borrar un gasto en efectivo exige la caja abierta (D8, P0426).
-- OQ-1 = opt-in de caja PRE-MARCADO; OQ-2 = selector de cuenta bancaria
-- OBLIGATORIO en el formulario + P0412 en servidor. OQ-3..OQ-11 salieron por
-- su opción recomendada (el PO autorizó el apply sin responderlas una por una,
-- precedente del proyecto).
--
-- MAX(version) de prod re-verificado 2026-08-29 (sólo SELECT, MCP) JUSTO antes
-- de escribir este archivo: 20261014000001 con 263 migraciones, idéntico al
-- último archivo de origin/main → este archivo usa 20261015000001. En este
-- proyecto la renumeración mordió tres veces; por eso se re-verifica acá y no
-- sólo al principio del apply.
--
-- GATE DE INTEGRIDAD DE FUNCIÓN (regla del proyecto, instaurada tras el G3 de
-- 20261003000001 reescrito in-place): las 11 funciones que este change
-- reescribe o de las que copia un predicado están capturadas por
-- pg_get_functiondef EN VIVO de prod en
-- openspec/changes/gastos-forma-pago/baseline/*.sql, con md5 y length. Las 11
-- coinciden EXACTO contra el stack local reseteado sobre las mismas 263
-- migraciones (cero divergencias). La reescritura de rpc_payment_method_report
-- de la sección 6 parte de ese baseline, NUNCA del archivo de migración.
--
-- REUTILIZACIÓN ANTES QUE REPETICIÓN (regla PO 2026-08-02): este archivo NO
-- crea ni un helper. Cada predicado se COPIA de venta o de compra:
--   · derivación del kind + las 3 condiciones del opt-in de caja
--     ← rpc_create_sale_operation_v2 (baseline)
--   · llamada incondicional a _pay_register_operation_bank_movement con 'out'
--     ← rpc_create_purchase_operation (baseline)
--   · guards P0423 de inmutabilidad y contrato tri-estado
--     ← rpc_atomic_update_sale_operation / rpc_atomic_update_purchase_operation
--   · compensación de las dos patas al borrar
--     ← rpc_delete_sale_operation (baseline) — CON UNA INVERSIÓN OBLIGATORIA
--       DEL GUARD DE SIGNO, documentada en la sección 5 (D8).
-- Los helpers compartidos (c28_register_cash_movement,
-- _pay_register_operation_bank_movement, _pay_resolve_bank_account,
-- _register_bank_movement) NO se tocan: el endurecimiento vive en el caller de
-- gasto (D5), porque la spec bank-movement exige que "sin cuenta resuelta la
-- venta sigue funcionando igual que antes".
--
-- ERRCODEs: CERO nuevos. P0400/P0401/P0403/P0404/P0409/P0412/P0422/P0423/
-- P0424/P0426 ya existen y ya están mapeados en backend/core/errors.py.
-- P0001 PROHIBIDO: el gate embebido en 20260804000003 §(b) lo re-lanza y
-- abortaría `supabase db reset`.
--
-- Idempotente: columna con IF NOT EXISTS, índice con IF NOT EXISTS, CHECK con
-- DROP+ADD, funciones con CREATE OR REPLACE (las 3 nuevas) o DROP+CREATE (el
-- reporte, que cambia su RETURNS TABLE — 42P13, D14), y REVOKE/GRANT explícito
-- de PUBLIC/anon/authenticated en el mismo archivo para las 4 (gotcha visto 6
-- veces en el proyecto: el default-privilege setup de Supabase hosted otorga
-- EXECUTE a anon/authenticated directamente sobre funciones nuevas del schema
-- public, "REVOKE ... FROM PUBLIC" solo no alcanza — 20261004000002).
--
-- FUERA DE ALCANCE, declarado: asiento contable del gasto (V2.6) y emisión de
-- eventos al outbox. Ninguna función de este archivo lee ni escribe
-- public.events → queda fuera del chequeo (5) del gate de ACLs. Ninguna crea
-- un helper interno con prefijo _/c2x_/c3x_ → queda fuera del chequeo (4).


-- =============================================================================
-- 1. Esquema — expenses.payment_method_id + índice + vocabulario de caja
-- =============================================================================

-- Espejo exacto de sales.payment_method_id y purchases.payment_method_id.
-- Nullable y SIN backfill: los 175 gastos históricos quedan como "Sin imputar"
-- (D7). Backfillear la etiqueta sin el libro sería inventar un dato que después
-- nadie puede distinguir de uno real.
ALTER TABLE public.expenses
    ADD COLUMN IF NOT EXISTS payment_method_id uuid NULL
        REFERENCES public.payment_methods(id) ON DELETE SET NULL;

COMMENT ON COLUMN public.expenses.payment_method_id IS
  'gastos-forma-pago: forma de pago imputada al gasto (nullable, sin backfill).
  El kind se DERIVA en el servidor desde el catálogo y gobierna los efectos en
  libros: cash → movimiento de caja bajo opt-in; transfer/card/check/wallet →
  bank_movement; other → etiqueta sin efecto; credit → rechazado (P0400, D3:
  expenses no tiene contraparte con cuenta corriente).';

-- El filtro por forma de pago del listado y la agregación del reporte
-- recorren (account_id, payment_method_id) — mismo criterio que el índice
-- homónimo de sales/purchases.
CREATE INDEX IF NOT EXISTS idx_expenses_account_payment_method
    ON public.expenses (account_id, payment_method_id);

-- Vocabulario de caja: expense_reversal es la contra-partida del expense, con
-- el mismo patrón de contra-movimiento automático con tipo propio que
-- sale_reversal (D9). Dos taxonomías distintas que NO hay que mezclar: por
-- SIGNO expense_reversal es INGRESO (revertir un egreso repone plata — al
-- revés que sale_reversal, que es egreso); por FAMILIA del filtro del historial
-- de caja va a "Reversas", junto a sale_reversal, NO a "Ingresos".
-- DROP + ADD idempotente, mismo molde que 20261006000001 §1 (que agregó
-- 'adjustment'). Aditivo: ninguna fila histórica se invalida ni se reescribe.
ALTER TABLE public.cash_movements
  DROP CONSTRAINT IF EXISTS cash_movements_movement_type_check;

ALTER TABLE public.cash_movements
  ADD CONSTRAINT cash_movements_movement_type_check
  CHECK (movement_type = ANY (ARRAY[
    'sale'::text, 'purchase_payment'::text, 'expense'::text,
    'advance'::text, 'withdrawal'::text, 'sale_reversal'::text,
    'expense_reversal'::text, 'adjustment'::text
  ]));

COMMENT ON CONSTRAINT cash_movements_movement_type_check ON public.cash_movements IS
  'gastos-forma-pago: agrega expense_reversal — contra-movimiento automático del
  borrado de un gasto en efectivo, con tipo propio (no adjustment, que está
  reservado para la corrección manual y exige motivo). Signo esperado POSITIVO:
  revertir un egreso repone plata. Familia de UI: "Reversas", junto a
  sale_reversal (D9).';
