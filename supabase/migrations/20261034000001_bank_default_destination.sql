-- =============================================================================
-- bank-default-destination — cobranzas-catalogo-pagos OQ-5: configurar
-- destinos bancarios por defecto en las formas de pago bancarias que no
-- tienen ninguno.
--
-- Decisión del PO: NO adivinar. Si la cuenta tiene EXACTAMENTE UNA cuenta
-- bancaria activa, asignarla automáticamente como destino de las formas de
-- pago bancarias (kind IN transfer/card/wallet/check) que aún no tengan
-- destino. Con 0 o 2+ bancos activos, no se toca nada — el PO ya eligió no
-- adivinar en ese caso (mismo criterio D2 de pos-banco-movimientos, que deja
-- el default sin resolver como "camino silencioso y válido").
--
-- Medido en prod el 2026-09-08: 1 cuenta con exactamente 1 banco activo (4
-- formas de pago bancarias sin destino se autoasignarían con este backfill),
-- 4 cuentas con 2+ bancos activos (no se tocan).
--
-- `_pay_resolve_bank_account` (20261020000001) YA lee
-- `payment_methods.bank_account_id` como default (regla 2 de D2) — lo único
-- que faltaba era ASIGNARLO. Este change cierra ese hueco por los DOS
-- caminos posibles:
--   (a) el banco ya existía y se crea/edita una forma de pago bancaria sin
--       destino → el backend resuelve el único banco activo al alta
--       (backend/services/payment_methods.py, ver PR de este change);
--   (b) la forma de pago ya existía sin destino y se crea EL banco (el
--       primero de la cuenta) → rpc_create_bank_account llama al helper
--       nuevo al final de su alta;
--   (c) backfill histórico, una sola vez, para las cuentas que YA tienen
--       exactamente 1 banco activo hoy.
--
-- Helper nuevo `_pay_assign_default_bank_destination(p_account_id uuid)`:
-- SECURITY DEFINER, "solo-DEFINER" (prefijo `_`) — REVOKE ALL FROM PUBLIC,
-- anon, authenticated: sólo lo llaman rpc_create_bank_account y el backfill
-- de esta migración, nunca PostgREST directo (recibe el account_id por
-- parámetro, sin resolver la sesión — sigue el contrato de
-- _pay_register_party_charge/_pay_reverse_party_charge, nunca expuesto).
--
-- rpc_create_bank_account: reescrita desde el cuerpo VIVO de prod
-- (verificado hoy — `printf '%s\n' "$(cat live.sql)" | md5sum` =
-- b7124b89efa0319b2350e58c00ac34f2, idéntico al md5 de prod dado en el
-- brief). CREATE OR REPLACE con la MISMA firma (p_name text, p_bank_name
-- text, p_cbu text, p_alias text, p_currency text, p_opening_balance
-- numeric, p_opening_date date, p_account_kind text) — CREATE OR REPLACE
-- preserva el ACL vigente (no lo cambia), pero se re-emite igual el
-- REVOKE/GRANT explícito debajo del cuerpo (mismo molde que las otras dos
-- reescrituras de esta tanda) para no depender de que un ACL previo ya
-- exista si esta migración se reaplica sobre una base reconstruida desde
-- un subconjunto.
--
-- ERRCODEs: ninguno nuevo — el helper nunca falla (RETURNS integer, 0 filas
-- afectadas es un resultado válido, no un error), y rpc_create_bank_account
-- conserva sus ERRCODEs existentes (P0400/P0403/P0401/P0411/P0414) sin
-- cambios.
--
-- Idempotencia: el backfill de abajo llama al mismo helper "solo asigna si
-- bank_account_id IS NULL" — reaplicar esta migración no duplica ni pisa
-- nada (una cuenta ya resuelta no tiene filas con bank_account_id IS NULL
-- que tocar, y el conteo de bancos activos no cambia entre corridas).
-- =============================================================================


-- ═══════════════ (a) Helper "solo-DEFINER": asignación del default ══════════

CREATE OR REPLACE FUNCTION public._pay_assign_default_bank_destination(p_account_id uuid)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_bank_count  integer;
  v_bank_id     uuid;
  v_updated     integer;
BEGIN
  -- No adivinar: sólo actúa con EXACTAMENTE una cuenta bancaria activa.
  -- (uuid no tiene MIN/MAX — se cuenta y se toma la fila aparte.)
  SELECT COUNT(*) INTO v_bank_count
  FROM public.bank_accounts
  WHERE account_id = p_account_id
    AND is_active = TRUE
    AND deleted_at IS NULL;

  IF v_bank_count <> 1 THEN
    RETURN 0;
  END IF;

  SELECT id INTO v_bank_id
  FROM public.bank_accounts
  WHERE account_id = p_account_id
    AND is_active = TRUE
    AND deleted_at IS NULL;

  UPDATE public.payment_methods
  SET    bank_account_id = v_bank_id
  WHERE  account_id = p_account_id
    AND  kind IN ('transfer', 'card', 'wallet', 'check')
    AND  bank_account_id IS NULL
    AND  is_active = TRUE
    AND  deleted_at IS NULL;

  GET DIAGNOSTICS v_updated = ROW_COUNT;
  RETURN v_updated;
END;
$function$;

REVOKE ALL ON FUNCTION public._pay_assign_default_bank_destination(uuid) FROM PUBLIC, anon, authenticated;


-- ═══════════════ (b) rpc_create_bank_account: llama al helper al alta ═══════

CREATE OR REPLACE FUNCTION public.rpc_create_bank_account(p_name text, p_bank_name text DEFAULT NULL::text, p_cbu text DEFAULT NULL::text, p_alias text DEFAULT NULL::text, p_currency text DEFAULT 'ARS'::text, p_opening_balance numeric DEFAULT 0, p_opening_date date DEFAULT NULL::date, p_account_kind text DEFAULT 'bank'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_account_id      uuid;
  v_bank_account_id uuid;
BEGIN
  -- Resolver account_id de la sesión (misma mecánica que C-30)
  SELECT cai INTO v_account_id
  FROM public.current_account_ids() AS cai
  LIMIT 1;

  IF v_account_id IS NULL THEN
    RAISE EXCEPTION 'sin_cuenta_activa' USING ERRCODE = 'P0403';
  END IF;

  -- Guard D5: solo escritores autorizados
  IF NOT public.is_account_writer(v_account_id) THEN
    RAISE EXCEPTION 'unauthorized' USING ERRCODE = 'P0401';
  END IF;

  -- Validar CBU/CVU (D7 original; D3 de este change: cbu también rotula CVU
  -- para wallet — misma columna, misma validación de 22 dígitos)
  IF p_cbu IS NOT NULL AND p_cbu !~ '^[0-9]{22}$' THEN
    RAISE EXCEPTION 'cbu_invalido: el CBU debe tener exactamente 22 dígitos numéricos, recibido: %', p_cbu
      USING ERRCODE = 'P0411';
  END IF;

  -- Validar nombre requerido
  IF p_name IS NULL OR trim(p_name) = '' THEN
    RAISE EXCEPTION 'name_required: el nombre de la cuenta es obligatorio'
      USING ERRCODE = 'P0400';
  END IF;

  -- cuentas-billetera-tipo (D1/D4): dominio cerrado de account_kind
  IF COALESCE(p_account_kind, 'bank') NOT IN ('bank', 'wallet') THEN
    RAISE EXCEPTION 'account_kind_invalido: el tipo de cuenta debe ser ''bank'' o ''wallet'', recibido: %', p_account_kind
      USING ERRCODE = 'P0414';
  END IF;

  -- INSERT de la cuenta bancaria
  INSERT INTO public.bank_accounts
    (account_id, name, bank_name, cbu, alias, currency, opening_balance, opening_date, account_kind)
  VALUES
    (v_account_id, trim(p_name), p_bank_name, p_cbu, p_alias,
     COALESCE(p_currency, 'ARS'), COALESCE(p_opening_balance, 0), p_opening_date,
     COALESCE(p_account_kind, 'bank'))
  RETURNING id INTO v_bank_account_id;

  -- bank-default-destination (OQ-5 de cobranzas-catalogo-pagos): si esta es
  -- la única cuenta bancaria activa de la cuenta, se asigna automáticamente
  -- como destino de las formas de pago bancarias que aún no tienen ninguno.
  PERFORM public._pay_assign_default_bank_destination(v_account_id);

  RETURN jsonb_build_object(
    'bank_account_id',  v_bank_account_id,
    'account_id',       v_account_id,
    'name',             trim(p_name),
    'currency',         COALESCE(p_currency, 'ARS'),
    'opening_balance',  COALESCE(p_opening_balance, 0),
    'account_kind',     COALESCE(p_account_kind, 'bank'),
    'is_active',        true
  );
END;
$function$;

-- Re-emitir el ACL explícitamente: un CREATE OR REPLACE no toca REVOKE/GRANT
-- vigentes, PERO si esta migración se reaplica sobre una base donde la
-- función no existía aún (replay parcial, migration repair, base
-- reconstruida desde un subconjunto), quedaría creada con el EXECUTE a
-- PUBLIC por defecto — ejecutable por anon. Idempotente: no cambia el
-- estado actual en la base normal (ya fijado por 20261007000001).
REVOKE ALL     ON FUNCTION public.rpc_create_bank_account(text, text, text, text, text, numeric, date, text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.rpc_create_bank_account(text, text, text, text, text, numeric, date, text) FROM anon;
GRANT  EXECUTE ON FUNCTION public.rpc_create_bank_account(text, text, text, text, text, numeric, date, text) TO authenticated;


-- ═══════════════ (c) Backfill histórico (idempotente) ═══════════════════════

DO $$
DECLARE
  v_account_id  uuid;
  v_count       integer;
  v_total       integer := 0;
BEGIN
  FOR v_account_id IN
    SELECT a.id
    FROM   public.accounts a
    WHERE (
      SELECT COUNT(*) FROM public.bank_accounts ba
      WHERE ba.account_id = a.id AND ba.is_active = TRUE AND ba.deleted_at IS NULL
    ) = 1
  LOOP
    SELECT public._pay_assign_default_bank_destination(v_account_id) INTO v_count;
    v_total := v_total + v_count;
    IF v_count > 0 THEN
      RAISE NOTICE 'bank-default-destination backfill: cuenta % — % formas de pago asignadas al único banco activo.', v_account_id, v_count;
    END IF;
  END LOOP;

  RAISE NOTICE 'bank-default-destination backfill: % formas de pago asignadas en total.', v_total;
END $$;
