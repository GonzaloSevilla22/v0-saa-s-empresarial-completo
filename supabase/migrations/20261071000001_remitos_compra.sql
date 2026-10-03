-- =============================================================================
-- 20261071000001_remitos_compra.sql
-- remitos-compra, TANDA A (governance MEDIA con tramo ALTO: escribe el ledger
-- de stock en tres caminos nuevos —recepción, edición y anulación— y reescribe
-- helpers y RPCs que remitos-venta acaba de mergear). Sign-off del PO
-- 2026-09-29: «no necesito el remito legal. Andá con todo lo recomendado» y
-- «quiero que tanto el remito como los presupuestos se puedan modificar»
-- (R1-R8); OQ-RC1..RC11 por su recomendación. Ver
-- openspec/changes/remitos-compra/design.md (D1-D16).
--
-- Qué hace (sin dinero: la conversión a compra es la tanda B):
--   1. CHECK ampliados POR AGREGADO al vivo (D16): un bloque DO lee
--      pg_get_constraintdef y sólo hace DROP + ADD si falta el valor, con la
--      lista viva más delivery_note_purchase. Nunca una lista fija: reaplicar
--      esta migración después de otro change que sume valores no los borra.
--      internal_document_sequences, document_status_history,
--      document_status_transitions y operation_idempotency.operation_kind.
--   2. FSM y numeración (D2, D3): filas NULL -> issued {stock,admin,owner} e
--      issued -> canceled {admin,owner} (motivo, terminal) de
--      delivery_note_purchase; disparadores gemelos de número (RC, genérico),
--      creación y enforcement con WHEN (direction = 'purchase'). Los de venta
--      no se tocan.
--   3. Helpers por sentido desde el cuerpo VIVO, con la MISMA firma (D4, D7):
--      _delivery_note_apply_stock y _delivery_note_reverse_held leen direction
--      de la fila del remito (compra: la aplicación suma sin gate con
--      type = purchase; la reversa resta con gate P0409
--      delivery_note_stock_consumed y type = purchase_return);
--      _delivery_note_assert_role_dir(uuid, text, text) NUEVA con nombre propio
--      (sin overload) y _delivery_note_assert_role(uuid, text) delega con
--      'sale'; _delivery_note_payload (desde el cuerpo vivo de 20261070000001)
--      suma supplier_name, supplier_phone, supplier_deleted y
--      missing_price_count.
--   4. Núcleo de edición _delivery_note_replace_content extraído del cuerpo
--      vivo de rpc_update_delivery_note (D5), en el orden vivo: la sucursal
--      nueva se fija ANTES de recalcular lo retenido nuevo; en compra, chequeo
--      del neto por par antes de cualquier pata; patas que suman primero.
--      rpc_update_delivery_note (venta) pasa a llamarlo: el único cambio de
--      forma es su UPDATE partido en dos.
--   5. RPCs SECURITY DEFINER rpc_create_purchase_delivery_note (idempotente,
--      molde DEC-06), rpc_update_purchase_delivery_note y
--      rpc_cancel_delivery_note para los dos sentidos.
--   6. Bloque DO de introspección al final.
--
-- El guard de baja de sucursal NO se toca: _branch_pending_delivery_notes ya
-- cuenta los remitos issued sin filtrar direction (verificado en el gate).
--
-- Idempotente (auto-apply de Supabase GitHub y reaplicación de
-- KPI_Validation.yml): CHECK por agregado, catálogo con ON CONFLICT DO
-- NOTHING, DROP TRIGGER IF EXISTS + CREATE, CREATE OR REPLACE con firmas
-- nuevas o idénticas (sin overload, sin 42725), REVOKE/GRANT y COMMENT
-- re-ejecutables.
--
-- Gates: supabase/tests/test_remitos_compra.sql (EJECUTA las RPCs, los helpers
-- por sentido y la regresión de venta), supabase/tests/test_remitos_compra_race.sh,
-- supabase/tests/test_internal_document_numbering_race.sh
-- (DOC_TYPE=delivery_note_purchase) y, sin tocarlos salvo el bloque (n),
-- test_remitos_venta.sql / test_remitos_venta_race.sh.
-- =============================================================================


-- =============================================================================
-- 1. CHECK ampliados POR AGREGADO al vivo (D16)
-- =============================================================================
DO $$
DECLARE
  v_spec    record;
  v_def     text;
  v_values  text[];
  v_comment text;
BEGIN
  FOR v_spec IN
    SELECT * FROM (VALUES
      ('internal_document_sequences', 'internal_document_sequences_document_type_check', 'document_type'),
      ('document_status_history',     'document_status_history_document_type_check',     'document_type'),
      ('document_status_transitions', 'document_status_transitions_document_type_check', 'document_type'),
      ('operation_idempotency',       'operation_idempotency_operation_kind_check',      'operation_kind')
    ) AS t(tbl, con, col)
  LOOP
    SELECT pg_get_constraintdef(c.oid), obj_description(c.oid, 'pg_constraint')
    INTO   v_def, v_comment
    FROM   pg_constraint c
    WHERE  c.conname = v_spec.con
      AND  c.conrelid = format('public.%I', v_spec.tbl)::regclass;
    IF v_def IS NULL THEN
      RAISE EXCEPTION 'remitos-compra: falta la constraint viva %.%', v_spec.tbl, v_spec.con;
    END IF;

    SELECT array_agg(m[1] ORDER BY o) INTO v_values
    FROM   regexp_matches(v_def, '''([^'']+)''', 'g') WITH ORDINALITY AS r(m, o);

    IF NOT ('delivery_note_purchase' = ANY (v_values)) THEN
      v_values := v_values || 'delivery_note_purchase'::text;
      EXECUTE format('ALTER TABLE public.%I DROP CONSTRAINT %I', v_spec.tbl, v_spec.con);
      -- ARRAY[...] literal (no '{...}'::text[]): pg_get_constraintdef lo devuelve
      -- con un literal por valor, que es lo que la regexp de arriba vuelve a leer.
      EXECUTE format('ALTER TABLE public.%I ADD CONSTRAINT %I CHECK (%I = ANY (ARRAY[%s]::text[]))',
                     v_spec.tbl, v_spec.con, v_spec.col,
                     (SELECT string_agg(quote_literal(v), ', ' ORDER BY o) FROM unnest(v_values) WITH ORDINALITY AS u(v, o)));
      IF v_comment IS NOT NULL THEN
        EXECUTE format('COMMENT ON CONSTRAINT %I ON public.%I IS %L', v_spec.con, v_spec.tbl,
                       v_comment || ' remitos-compra (D16): suma delivery_note_purchase por agregado al vivo.');
      END IF;
    END IF;
  END LOOP;
END $$;


-- =============================================================================
-- 2. FSM y numeración (D2, D3)
-- =============================================================================
-- Sólo las filas de la tanda A (regla del seed: ninguna transición sin productor).
INSERT INTO public.document_status_transitions
  (document_type, from_status, to_status, is_terminal_to, requires_reason, allowed_role)
VALUES
  ('delivery_note_purchase', NULL, 'issued', false, false, ARRAY['stock', 'admin', 'owner'])
ON CONFLICT (document_type, to_status) WHERE from_status IS NULL DO NOTHING;

INSERT INTO public.document_status_transitions
  (document_type, from_status, to_status, is_terminal_to, requires_reason, allowed_role)
VALUES
  ('delivery_note_purchase', 'issued', 'canceled', true, true, ARRAY['admin', 'owner'])
ON CONFLICT (document_type, from_status, to_status) WHERE from_status IS NOT NULL DO NOTHING;

-- Número RC: la función genérica, sin cambios; el WHEN separa las secuencias.
DROP TRIGGER IF EXISTS delivery_notes_assign_number_purchase ON public.delivery_notes;
CREATE TRIGGER delivery_notes_assign_number_purchase
  BEFORE INSERT ON public.delivery_notes
  FOR EACH ROW WHEN (NEW.direction = 'purchase')
  EXECUTE FUNCTION public.trg_assign_internal_document_number('delivery_note_purchase');

-- Creación: la función parametrizada por TG_ARGV[0] de remitos-venta, sin cambios.
DROP TRIGGER IF EXISTS delivery_notes_record_status_creation_purchase ON public.delivery_notes;
CREATE TRIGGER delivery_notes_record_status_creation_purchase
  AFTER INSERT ON public.delivery_notes
  FOR EACH ROW WHEN (NEW.direction = 'purchase')
  EXECUTE FUNCTION public.trg_delivery_note_record_creation('delivery_note_purchase');

DROP TRIGGER IF EXISTS delivery_notes_enforce_status_transition_purchase ON public.delivery_notes;
CREATE TRIGGER delivery_notes_enforce_status_transition_purchase
  BEFORE UPDATE ON public.delivery_notes
  FOR EACH ROW WHEN (OLD.status IS DISTINCT FROM NEW.status AND OLD.direction = 'purchase' AND NEW.direction = 'purchase')
  EXECUTE FUNCTION public.trg_enforce_status_transition('delivery_note_purchase');
