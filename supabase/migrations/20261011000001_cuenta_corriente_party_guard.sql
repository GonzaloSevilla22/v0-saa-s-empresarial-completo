-- =============================================================================
-- cuenta-corriente-party-guard — guard de tenencia de la parte
-- (cliente/proveedor) en el choke point de cuenta corriente + cierre de la
-- primitiva de escritura cross-tenant.
-- =============================================================================
--
-- Hallazgo (auditoría de tenencia que acompañó al hotfix #446, 2026-08-22).
-- Dos familias, ninguna cubierta por trigger, CHECK ni constraint — el `grep`
-- de `client_not_found|supplier_not_found` sobre las 200+ migraciones devuelve
-- exactamente 2 líneas en todo el repo, las dos de C-30:
--
--   FAMILIA 1 — incoherencia (cuenta, parte). Las RPCs de cuenta corriente
--   resuelven el tenant de la sesión (current_account_ids + is_account_writer)
--   pero NUNCA validan que el cliente/proveedor recibido por parámetro
--   pertenezca a ese tenant. El FK `client_id REFERENCES clients(id)` no está
--   scopeado por tenant y el UNIQUE (account_id, client_id) tampoco lo exige:
--   la fila entra. El tenant A termina con deuda, cobros y partida doble
--   contra una entidad que jamás va a ver en sus listas (esas sí filtran por
--   account_id) — saldo huérfano, imposible de conciliar desde la UI.
--   El mismo hueco está en el camino de MÁS VOLUMEN: rpc_create_sale_operation
--   (_v2) y _c29_confirm_order_core reciben p_client_id del payload y tampoco
--   validan (no hay una sola ocurrencia de `FROM public.clients` en
--   20261002000001, 20261003000001 ni 20261004000001).
--
--   FAMILIA 2 — primitiva de escritura cross-tenant (severidad alta).
--   _pay_register_party_charge y _journal_post_from_event son SECURITY
--   DEFINER, reciben el account_id COMO PARÁMETRO —sin resolverlo de la
--   sesión ni validar is_account_writer— y tenían GRANT EXECUTE TO
--   authenticated, o sea invocables por PostgREST con el account_id de OTRO
--   tenant. Reproducido en local antes de este archivo: como `authenticated`
--   pelado, _pay_register_party_charge escribió una customer_account en los
--   libros REALES del tenant víctima y _journal_post_from_event le posteó un
--   asiento forjado.
--
-- Decisión (design.md D1, opción B): el guard va en el CHOKE POINT
-- c30_get_or_create_customer_account / c30_get_or_create_supplier_account —una
-- sola redefinición por parte cubre TODOS los llamadores, presentes y futuros
-- (las 3 RPCs de pago, _pay_register_party_charge y con él POS + formulario de
-- venta + el alta de compra que va a cablear compras-proveedor-cuenta-
-- corriente, y los dos rpc_create_*_account que ya validaban)— Y ADEMÁS
-- explícito en las 3 RPCs de pago (D1 capa 2: mensaje del dominio del
-- llamador, no del helper interno).
--
-- Sin helper nuevo (D1, Regla de Tres): el predicado se copia del patrón
-- canónico ya probado de rpc_create_customer_account (20260720000001 L537-542).
-- Un helper nuevo sería otra función más que hay que acordarse de REVOKE-ar,
-- que es precisamente el modo de falla que este archivo cierra.
--
-- Sin ERRCODEs nuevos (D6): se reutiliza P0404 con los mensajes canónicos
-- `client_not_found: %` / `supplier_not_found: %`. Ya mapeado a HTTP 404 en
-- backend/core/errors.py (_BUSINESS_ERRCODE_STATUS) + handler global de
-- asyncpg.PostgresError en backend/main.py, y explícito en los services de
-- customer_accounts, supplier_accounts, sales, sales_orders y quotes.
-- test_errcode_5char_gate.sql sigue verde por construcción.
--
-- MAX(version) prod verificado 2026-08-23: 20261007000001 (cuentas-billetera-
-- tipo, PR #447) al capturar el baseline → el archivo nació como
-- 20261008000001. RENUMERADA DOS VECES el 2026-08-23, siempre por el mismo
-- motivo —un archivo con número menor al MAX vivo de prod no lo aplica nunca
-- el push automático de Supabase—, cada salto por un merge a `main` ocurrido
-- mientras esta rama estaba en revisión:
--   20261008000001 → 20261010000001: compras-proveedor-cuenta-corriente
--     (PR #452) tomó 20261009000001 y elevó el MAX vivo de prod a ese número.
--   20261010000001 → 20261011000001: el hotfix de seguridad
--     revoke-internal-money-helpers (PR #454, ver más abajo) tomó
--     20261010000001 y volvió a elevar el MAX.
--
-- FAMILIA 2 — QUÉ QUEDÓ ACÁ Y QUÉ NO (reconciliación con el PR #454).
-- El `REVOKE` de _pay_register_party_charge y _journal_post_from_event, que
-- este archivo traía, **salió antes como hotfix** por orden del PO
-- (OQ-2 resuelta el 2026-08-23 → hotfix, no apply):
-- 20261010000001_revoke_internal_money_helpers.sql. No se repite acá — dos
-- migraciones revocando lo mismo con textos distintos es exactamente el tipo
-- de divergencia que produce los bugs que este change cierra. Lo que sí queda
-- acá es (i) el `REVOKE` de los DOS choke points c30_get_or_create_* (que el
-- hotfix no tocó) y (ii) una VERIFICACIÓN —no un REVOKE— en el gate final:
-- este archivo corre DESPUÉS del hotfix en la cadena de reapply de CI, así
-- que si algún eslabón intermedio les devolviera el EXECUTE a
-- anon/authenticated, el gate de acá lo detecta y falla. Ver design.md
-- §"Post-apply (2026-08-23)" punto (i).
--
-- ORDEN EN CI (no negociable): en .github/workflows/KPI_Validation.yml esta
-- migración va DESPUÉS de 20261001000001 (L137) y de 20261004000001 (~L1778)
-- en la cadena de reapply del step "Verify G1/G4 migrations are idempotent on
-- reapply": ambas re-otorgan el GRANT EXECUTE a `authenticated` de los dos
-- helpers de la Familia 2, o sea que reabren el agujero — y también vuelven a
-- ejecutar bloques REVOKE+GRANT "de plantilla" del mismo tipo que el que se
-- lo devolvió. Va además DESPUÉS de 20261010000001 (el hotfix), porque el
-- gate final de este archivo VERIFICA el estado que ese hotfix deja.
-- 20261009000001, en cambio, no re-otorga nada de esto
-- (verificado), así que el orden contra ella es libre. Baseline de las 5
-- funciones reescritas + las 2 revocadas capturado en
-- openspec/changes/cuenta-corriente-party-guard/baseline/*.sql vía
-- pg_get_functiondef EN VIVO contra prod, con md5 verificado (gate de
-- integridad de función, regla del proyecto tras 5 incidentes previos — el
-- bloque `credit` de C-30 se perdió en silencio exactamente así en julio).
-- Las 5 reescrituras de este archivo parten de ese baseline: la ÚNICA
-- diferencia es el bloque de guard y la variable que declara. Ni una firma,
-- ni un DEFAULT, ni un search_path, ni una línea de lógica cambian.
--
-- NINGUNA FIRMA CAMBIA → CREATE OR REPLACE puro, sin DROP, sin riesgo de
-- overload 42725 (gate anti-overload al final del archivo). CREATE OR REPLACE
-- preserva ACLs, pero se reafirman igual tras cada CREATE (patrón uniforme
-- documentado en la cabecera de 20261001000001) CON UNA CORRECCIÓN
-- IMPORTANTE (D5): para los helpers internos la reafirmación es
-- `REVOKE ALL ... FROM PUBLIC, anon, authenticated` SIN `GRANT`. Copiar el
-- bloque REVOKE+GRANT tal cual es literalmente el bug que produjo la Familia 2.
--
-- Gotcha #432 (asiento-venta-formulario, post-merge): prod concede EXECUTE a
-- anon/authenticated DIRECTO, no vía el pseudo-rol PUBLIC — un
-- `REVOKE ... FROM PUBLIC` que se ve limpio en el stack local puede estar
-- abierto en producción. Por eso todos los REVOKE de abajo nombran la lista
-- completa `PUBLIC, anon, authenticated`. Caso verificado en la auditoría de
-- prod: c30_get_or_create_customer_account/supplier_account son
-- anon-executable EN PROD y no lo son en local.
--
-- `service_role` conserva EXECUTE en todo lo que ya lo tenía: no se lo nombra
-- en ningún REVOKE (es el rol de los jobs administrativos, no el de la app).
--
-- Idempotente: CREATE OR REPLACE + REVOKE/GRANT + COMMENT, todos re-aplicables
-- sin efecto. Verificado con doble apply en local (sin error, sin cambio de
-- fingerprint de las 7 funciones ni de sus ACLs).
--
-- BREAKING (superficie pública de PostgREST): c30_get_or_create_customer_
-- account y c30_get_or_create_supplier_account dejan de ser invocables por
-- `anon`/`authenticated` (lo eran en prod por concesión directa, gotcha
-- #432). Son helpers internos sin ningún caller del lado app —el grep sobre
-- frontend/, backend/ y supabase/functions/ los encuentra solo en
-- comentarios, en tests de migración y en frontend/lib/database.types.ts
-- (generado, y su presencia ahí es justamente la confirmación de que
-- PostgREST los expone)—. Los PERFORM internos corren con los privilegios del
-- definer, así que el revoke es transparente para todos los callers reales.
-- Rollback: un GRANT de una línea.
-- El BREAKING equivalente sobre _pay_register_party_charge y
-- _journal_post_from_event ya lo aplicó el hotfix
-- 20261010000001_revoke_internal_money_helpers.sql (PR #454); acá sólo se
-- verifica que siga en pie.
-- =============================================================================


-- =============================================================================
-- 1. c30_get_or_create_customer_account — CHOKE POINT del lado cliente.
--    Firma SIN CAMBIOS (uuid, uuid) → CREATE OR REPLACE. SECURITY INVOKER,
--    igual que el baseline: NO se convierte en SECURITY DEFINER (D3, "sin
--    rediseño"). Se invoca siempre desde funciones SECURITY DEFINER, así que
--    el SELECT contra clients corre como el definer, sin RLS de por medio, y
--    el filtro por account_id es explícito — el guard no puede auto-bloquearse.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.c30_get_or_create_customer_account(p_account_id uuid, p_client_id uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
DECLARE
  v_id uuid;
  v_client uuid;
BEGIN
  -- cuenta-corriente-party-guard: el cliente tiene que pertenecer al tenant.
  -- Patrón canónico copiado de rpc_create_customer_account (20260720000001
  -- L537-542). Va ANTES del INSERT: el FK client_id no está scopeado por
  -- tenant, así que sin esto la fila cross-tenant entra.
  SELECT id INTO v_client
  FROM public.clients
  WHERE id = p_client_id AND account_id = p_account_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'client_not_found: %', p_client_id USING ERRCODE = 'P0404';
  END IF;

  -- INSERT idempotente: ON CONFLICT (account_id, client_id) DO NOTHING
  INSERT INTO public.customer_accounts (account_id, client_id, balance, created_by)
  VALUES (p_account_id, p_client_id, 0, auth.uid())
  ON CONFLICT (account_id, client_id) DO NOTHING;

  -- SELECT garantizado (fila ya existe o fue recién insertada)
  SELECT id INTO v_id
  FROM public.customer_accounts
  WHERE account_id = p_account_id AND client_id = p_client_id;

  RETURN v_id;
END;
$function$;

COMMENT ON FUNCTION public.c30_get_or_create_customer_account(uuid, uuid) IS
  'cuenta-corriente-party-guard (customer-account): resuelve o crea la cuenta '
  'corriente del cliente. CHOKE POINT — valida que el cliente pertenezca al '
  'tenant (P0404 client_not_found) antes del INSERT, así que cubre a TODOS '
  'sus llamadores: las 3 RPCs de pago, _pay_register_party_charge (POS, '
  'formulario de venta, alta de compra) y rpc_create_customer_account. '
  'Helper interno: sin GRANT — ver el bloque REVOKE de abajo.';

-- Helper interno: NO lleva GRANT. Se invoca siempre vía PERFORM desde
-- funciones SECURITY DEFINER (el cuerpo corre como el definer). En PROD estaba
-- concedido a anon Y authenticated directo (gotcha #432) pese a no tener
-- ningún caller de aplicación — de ahí la lista completa.
REVOKE ALL ON FUNCTION public.c30_get_or_create_customer_account(uuid, uuid) FROM PUBLIC, anon, authenticated;


-- =============================================================================
-- 2. c30_get_or_create_supplier_account — espejo exacto del lado proveedor.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.c30_get_or_create_supplier_account(p_account_id uuid, p_supplier_id uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
DECLARE
  v_id uuid;
  v_supplier uuid;
BEGIN
  -- cuenta-corriente-party-guard: el proveedor tiene que pertenecer al tenant.
  -- Espejo del guard del lado cliente (patrón canónico de
  -- rpc_create_supplier_account, 20260720000001 L590-596).
  SELECT id INTO v_supplier
  FROM public.suppliers
  WHERE id = p_supplier_id AND account_id = p_account_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'supplier_not_found: %', p_supplier_id USING ERRCODE = 'P0404';
  END IF;

  INSERT INTO public.supplier_accounts (account_id, supplier_id, balance, created_by)
  VALUES (p_account_id, p_supplier_id, 0, auth.uid())
  ON CONFLICT (account_id, supplier_id) DO NOTHING;

  SELECT id INTO v_id
  FROM public.supplier_accounts
  WHERE account_id = p_account_id AND supplier_id = p_supplier_id;

  RETURN v_id;
END;
$function$;

COMMENT ON FUNCTION public.c30_get_or_create_supplier_account(uuid, uuid) IS
  'cuenta-corriente-party-guard (supplier-account): resuelve o crea la cuenta '
  'corriente del proveedor. CHOKE POINT — valida que el proveedor pertenezca '
  'al tenant (P0404 supplier_not_found) antes del INSERT. Cubre a las RPCs de '
  'pago/cargo de proveedor, a _pay_register_party_charge y a '
  'rpc_create_supplier_account. Helper interno: sin GRANT.';

REVOKE ALL ON FUNCTION public.c30_get_or_create_supplier_account(uuid, uuid) FROM PUBLIC, anon, authenticated;


-- =============================================================================
-- 3. rpc_register_payment_received — guard explícito (D1 capa 2).
--    Reescrita desde el baseline vivo de prod. Ubicación del guard (D2):
--    DESPUÉS del bloque bank_accounts (P0412) y ANTES del INSERT en
--    operation_idempotency, junto a las otras validaciones de payload.
--    Bloques preservados byte a byte: guard de auth.uid(), current_account_ids,
--    is_account_writer, validación de amount (P0400), taxonomía de
--    payment_method (P0400), bloque bank_accounts (P0412 not_found/inactive),
--    idempotencia DEC-06 y su rama de replay,
--    c30_register_customer_account_movement con signo negativo, INSERT en
--    payments_received, _register_bank_movement con reporting_local_today()
--    (card → card_settlement, resto → transfer_in) y el evento PaymentReceived
--    con payment_method/bank_account_id.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.rpc_register_payment_received(p_idempotency_key text, p_client_id uuid, p_amount numeric, p_reference_sale_id uuid DEFAULT NULL::uuid, p_payment_method text DEFAULT 'cash'::text, p_bank_account_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_uid                 uuid;
  v_account_id          uuid;
  v_customer_account_id uuid;
  v_inserted            integer;
  v_existing_op         uuid;
  v_new_op_id           uuid;
  v_movement_id         uuid;
  v_payment_id          uuid;
  v_balance_after        numeric(15,2);
  v_bank_account         public.bank_accounts%ROWTYPE;
  v_bank_movement_type   text;
  v_bank_movement_id     uuid;
  v_client               uuid;
BEGIN
  v_uid := auth.uid();
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;

  -- Resolver account_id
  SELECT cai INTO v_account_id
  FROM public.current_account_ids() AS cai
  LIMIT 1;

  IF v_account_id IS NULL THEN
    RAISE EXCEPTION 'sin_cuenta_activa' USING ERRCODE = 'P0403';
  END IF;

  -- Guard: permiso de escritura
  IF NOT public.is_account_writer(v_account_id) THEN
    RAISE EXCEPTION 'unauthorized' USING ERRCODE = 'P0401';
  END IF;

  -- Validar amount > 0
  IF p_amount IS NULL OR p_amount <= 0 THEN
    RAISE EXCEPTION 'invalid_amount: amount debe ser > 0, recibido: %', p_amount
      USING ERRCODE = 'P0400';
  END IF;

  -- D4: validar taxonomía de payment_method
  IF p_payment_method IS NULL OR p_payment_method NOT IN ('cash', 'transfer', 'card', 'check') THEN
    RAISE EXCEPTION 'invalid_payment_method: % no está en la taxonomía {cash,transfer,card,check}',
      p_payment_method
      USING ERRCODE = 'P0400';
  END IF;

  -- D2: método bancario exige bank_account_id válido, activo y de la cuenta
  IF p_payment_method IN ('transfer', 'card', 'check') THEN
    IF p_bank_account_id IS NULL THEN
      RAISE EXCEPTION 'bank_account_required: payment_method=% exige p_bank_account_id', p_payment_method
        USING ERRCODE = 'P0400';
    END IF;

    SELECT * INTO v_bank_account
    FROM public.bank_accounts
    WHERE id = p_bank_account_id
      AND account_id = v_account_id;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'bank_account_not_found: %', p_bank_account_id
        USING ERRCODE = 'P0412';
    END IF;

    IF NOT v_bank_account.is_active THEN
      RAISE EXCEPTION 'bank_account_inactive: la cuenta % está inactiva', p_bank_account_id
        USING ERRCODE = 'P0412';
    END IF;
  END IF;

  -- cuenta-corriente-party-guard (D1 capa 2 / D2): el cliente tiene que
  -- pertenecer al tenant. Va junto a las demás validaciones de payload y
  -- ANTES del INSERT de idempotencia, para que un p_client_id inválido no
  -- consuma la clave y para que el error sea del dominio del llamador y no
  -- del helper. El choke point c30_get_or_create_customer_account valida lo
  -- mismo — redundancia deliberada.
  SELECT id INTO v_client
  FROM public.clients
  WHERE id = p_client_id AND account_id = v_account_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'client_not_found: %', p_client_id USING ERRCODE = 'P0404';
  END IF;

  -- Idempotencia DEC-06 (OQ-5 C-30): operation_kind='payment_received'
  v_new_op_id := gen_random_uuid();

  INSERT INTO public.operation_idempotency
    (user_id, idempotency_key, operation_kind, operation_id)
  VALUES
    (v_uid, p_idempotency_key, 'payment_received', v_new_op_id)
  ON CONFLICT (user_id, operation_kind, idempotency_key) DO NOTHING;

  GET DIAGNOSTICS v_inserted = ROW_COUNT;

  IF v_inserted = 0 THEN
    -- Replay: devolver el resultado original sin re-ejecutar
    SELECT operation_id INTO v_existing_op
    FROM public.operation_idempotency
    WHERE user_id = v_uid
      AND operation_kind = 'payment_received'
      AND idempotency_key = p_idempotency_key;

    RETURN jsonb_build_object(
      'payment_id',           NULL,
      'customer_account_id',  NULL,
      'balance_after',        NULL,
      'replayed',             true,
      'operation_id',         v_existing_op
    );
  END IF;

  -- Resolver/crear la CustomerAccount (OQ-4 C-30 lazy auto-create)
  v_customer_account_id := public.c30_get_or_create_customer_account(v_account_id, p_client_id);

  -- Registrar el movimiento con signo negativo (reduce la deuda, OQ-1 C-30)
  -- El helper c30_register_customer_account_movement lanza P0409 si balance resultante < 0
  v_payment_id := gen_random_uuid();
  v_movement_id := public.c30_register_customer_account_movement(
    v_customer_account_id,
    -p_amount,                 -- negativo: el cobro reduce la deuda
    'payment_received',
    v_payment_id
  );

  -- Obtener el balance_after del movimiento recién insertado
  SELECT balance_after INTO v_balance_after
  FROM public.customer_account_movements
  WHERE id = v_movement_id;

  -- INSERT en payments_received
  INSERT INTO public.payments_received
    (id, account_id, customer_account_id, client_id, amount, reference_sale_id, movement_id, created_by)
  VALUES
    (v_payment_id, v_account_id, v_customer_account_id, p_client_id, p_amount, p_reference_sale_id, v_movement_id, v_uid);

  -- D2: ruteo OPERACIONAL intra-tx — bank_movement solo para métodos bancarios.
  -- app-timezone-argentina (task 5): día argentino, no CURRENT_DATE.
  IF p_payment_method IN ('transfer', 'card', 'check') THEN
    v_bank_movement_type := CASE WHEN p_payment_method = 'card' THEN 'card_settlement' ELSE 'transfer_in' END;

    v_bank_movement_id := public._register_bank_movement(
      p_bank_account_id,
      p_amount,                 -- positivo: ingreso
      v_bank_movement_type,
      'payment_received',
      v_payment_id,
      public.reporting_local_today(),
      NULL,
      NULL
    );
  END IF;

  -- OQ-6 C-30 (evento al outbox) + payment_method/bank_account_id enriquecidos (C2 D3)
  -- El consumer AuditLog de C-25 es genérico; el Consumer 3 (JournalEntry) lee
  -- payment_method del payload para rutear 1110 vs 1100.
  INSERT INTO public.events
    (account_id, event_type, aggregate_type, aggregate_id, payload, occurred_at)
  VALUES (
    v_account_id,
    'PaymentReceived',
    'CustomerAccount',
    v_customer_account_id,
    jsonb_build_object(
      'account_id',           v_account_id,
      'customer_account_id',  v_customer_account_id,
      'client_id',            p_client_id,
      'payment_id',           v_payment_id,
      'amount',               p_amount,
      'balance_after',        v_balance_after,
      'reference_sale_id',    p_reference_sale_id,
      'payment_method',       p_payment_method,
      'bank_account_id',      p_bank_account_id,
      'occurred_at',          now()
    ),
    now()
  );

  RETURN jsonb_build_object(
    'payment_id',           v_payment_id,
    'customer_account_id',  v_customer_account_id,
    'balance_after',        v_balance_after,
    'replayed',             false,
    'operation_id',         v_new_op_id
  );
END;
$function$;

COMMENT ON FUNCTION public.rpc_register_payment_received(text, uuid, numeric, uuid, text, uuid) IS
  'C-30 (customer-account): registra un cobro a cliente. '
  'cuenta-corriente-party-guard: valida que el cliente pertenezca al tenant '
  '(P0404 client_not_found) después del bloque bancario (P0412) y antes del '
  'INSERT de idempotencia, así un p_client_id inválido no consume la clave. '
  'API pública de PostgREST: GRANT a authenticated, nunca a anon.';

-- API pública: el GRANT a authenticated acá SÍ corresponde.
REVOKE ALL ON FUNCTION public.rpc_register_payment_received(text, uuid, numeric, uuid, text, uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.rpc_register_payment_received(text, uuid, numeric, uuid, text, uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.rpc_register_payment_received(text, uuid, numeric, uuid, text, uuid) TO authenticated;


-- =============================================================================
-- 4. rpc_register_payment_made — espejo del lado proveedor.
--    Mismos bloques preservados que (3), con transfer_out y payments_made.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.rpc_register_payment_made(p_idempotency_key text, p_supplier_id uuid, p_amount numeric, p_reference_purchase_id uuid DEFAULT NULL::uuid, p_payment_method text DEFAULT 'cash'::text, p_bank_account_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_uid                 uuid;
  v_account_id          uuid;
  v_supplier_account_id uuid;
  v_inserted            integer;
  v_existing_op         uuid;
  v_new_op_id           uuid;
  v_movement_id         uuid;
  v_payment_id          uuid;
  v_balance_after        numeric(15,2);
  v_bank_account         public.bank_accounts%ROWTYPE;
  v_bank_movement_type   text;
  v_bank_movement_id     uuid;
  v_supplier             uuid;
BEGIN
  v_uid := auth.uid();
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT cai INTO v_account_id
  FROM public.current_account_ids() AS cai
  LIMIT 1;

  IF v_account_id IS NULL THEN
    RAISE EXCEPTION 'sin_cuenta_activa' USING ERRCODE = 'P0403';
  END IF;

  IF NOT public.is_account_writer(v_account_id) THEN
    RAISE EXCEPTION 'unauthorized' USING ERRCODE = 'P0401';
  END IF;

  IF p_amount IS NULL OR p_amount <= 0 THEN
    RAISE EXCEPTION 'invalid_amount: amount debe ser > 0, recibido: %', p_amount
      USING ERRCODE = 'P0400';
  END IF;

  -- D4: validar taxonomía de payment_method
  IF p_payment_method IS NULL OR p_payment_method NOT IN ('cash', 'transfer', 'card', 'check') THEN
    RAISE EXCEPTION 'invalid_payment_method: % no está en la taxonomía {cash,transfer,card,check}',
      p_payment_method
      USING ERRCODE = 'P0400';
  END IF;

  -- D2: método bancario exige bank_account_id válido, activo y de la cuenta
  IF p_payment_method IN ('transfer', 'card', 'check') THEN
    IF p_bank_account_id IS NULL THEN
      RAISE EXCEPTION 'bank_account_required: payment_method=% exige p_bank_account_id', p_payment_method
        USING ERRCODE = 'P0400';
    END IF;

    SELECT * INTO v_bank_account
    FROM public.bank_accounts
    WHERE id = p_bank_account_id
      AND account_id = v_account_id;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'bank_account_not_found: %', p_bank_account_id
        USING ERRCODE = 'P0412';
    END IF;

    IF NOT v_bank_account.is_active THEN
      RAISE EXCEPTION 'bank_account_inactive: la cuenta % está inactiva', p_bank_account_id
        USING ERRCODE = 'P0412';
    END IF;
  END IF;

  -- cuenta-corriente-party-guard (D1 capa 2 / D2): el proveedor tiene que
  -- pertenecer al tenant. Espejo exacto del guard de rpc_register_payment_
  -- received: después del bloque bancario, antes de la idempotencia.
  SELECT id INTO v_supplier
  FROM public.suppliers
  WHERE id = p_supplier_id AND account_id = v_account_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'supplier_not_found: %', p_supplier_id USING ERRCODE = 'P0404';
  END IF;

  -- Idempotencia DEC-06 (OQ-5 C-30): operation_kind='payment_made'
  v_new_op_id := gen_random_uuid();

  INSERT INTO public.operation_idempotency
    (user_id, idempotency_key, operation_kind, operation_id)
  VALUES
    (v_uid, p_idempotency_key, 'payment_made', v_new_op_id)
  ON CONFLICT (user_id, operation_kind, idempotency_key) DO NOTHING;

  GET DIAGNOSTICS v_inserted = ROW_COUNT;

  IF v_inserted = 0 THEN
    SELECT operation_id INTO v_existing_op
    FROM public.operation_idempotency
    WHERE user_id = v_uid
      AND operation_kind = 'payment_made'
      AND idempotency_key = p_idempotency_key;

    RETURN jsonb_build_object(
      'payment_id',          NULL,
      'supplier_account_id', NULL,
      'balance_after',       NULL,
      'replayed',            true,
      'operation_id',        v_existing_op
    );
  END IF;

  v_supplier_account_id := public.c30_get_or_create_supplier_account(v_account_id, p_supplier_id);

  v_payment_id := gen_random_uuid();
  v_movement_id := public.c30_register_supplier_account_movement(
    v_supplier_account_id,
    -p_amount,               -- negativo: el pago reduce lo que se debe
    'payment_made',
    v_payment_id
  );

  SELECT balance_after INTO v_balance_after
  FROM public.supplier_account_movements
  WHERE id = v_movement_id;

  INSERT INTO public.payments_made
    (id, account_id, supplier_account_id, supplier_id, amount, reference_purchase_id, movement_id, created_by)
  VALUES
    (v_payment_id, v_account_id, v_supplier_account_id, p_supplier_id, p_amount, p_reference_purchase_id, v_movement_id, v_uid);

  -- D2: ruteo OPERACIONAL intra-tx — bank_movement solo para métodos bancarios.
  -- app-timezone-argentina (task 5): día argentino, no CURRENT_DATE.
  IF p_payment_method IN ('transfer', 'card', 'check') THEN
    v_bank_movement_type := 'transfer_out';  -- egreso: pago por transfer/check/card → egreso bancario

    v_bank_movement_id := public._register_bank_movement(
      p_bank_account_id,
      -p_amount,                -- negativo: egreso
      v_bank_movement_type,
      'payment_made',
      v_payment_id,
      public.reporting_local_today(),
      NULL,
      NULL
    );
  END IF;

  -- OQ-6 C-30: evento PaymentMade al outbox + payment_method/bank_account_id (C2 D3)
  INSERT INTO public.events
    (account_id, event_type, aggregate_type, aggregate_id, payload, occurred_at)
  VALUES (
    v_account_id,
    'PaymentMade',
    'SupplierAccount',
    v_supplier_account_id,
    jsonb_build_object(
      'account_id',          v_account_id,
      'supplier_account_id', v_supplier_account_id,
      'supplier_id',         p_supplier_id,
      'payment_id',          v_payment_id,
      'amount',              p_amount,
      'balance_after',       v_balance_after,
      'payment_method',      p_payment_method,
      'bank_account_id',     p_bank_account_id,
      'occurred_at',         now()
    ),
    now()
  );

  RETURN jsonb_build_object(
    'payment_id',          v_payment_id,
    'supplier_account_id', v_supplier_account_id,
    'balance_after',       v_balance_after,
    'replayed',            false,
    'operation_id',        v_new_op_id
  );
END;
$function$;

COMMENT ON FUNCTION public.rpc_register_payment_made(text, uuid, numeric, uuid, text, uuid) IS
  'C-30 (supplier-account): registra un pago a proveedor. '
  'cuenta-corriente-party-guard: valida que el proveedor pertenezca al tenant '
  '(P0404 supplier_not_found) después del bloque bancario (P0412) y antes del '
  'INSERT de idempotencia. API pública de PostgREST: GRANT a authenticated, '
  'nunca a anon.';

REVOKE ALL ON FUNCTION public.rpc_register_payment_made(text, uuid, numeric, uuid, text, uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.rpc_register_payment_made(text, uuid, numeric, uuid, text, uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.rpc_register_payment_made(text, uuid, numeric, uuid, text, uuid) TO authenticated;


-- =============================================================================
-- 5. rpc_register_supplier_charge — cargo manual de proveedor.
--    Única de las tres nunca redefinida desde C-30: el diff del baseline vivo
--    contra 20260720000001 L895 es VACÍO (confirmado en la task 1.5).
--    No tiene bloque bancario, así que el guard va directamente después de la
--    validación de amount y antes de la idempotencia.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.rpc_register_supplier_charge(p_idempotency_key text, p_supplier_id uuid, p_amount numeric, p_reference_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_uid                 uuid;
  v_account_id          uuid;
  v_supplier_account_id uuid;
  v_inserted            integer;
  v_existing_op         uuid;
  v_new_op_id           uuid;
  v_movement_id         uuid;
  v_balance_after       numeric(15,2);
  v_supplier            uuid;
BEGIN
  v_uid := auth.uid();
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT cai INTO v_account_id
  FROM public.current_account_ids() AS cai
  LIMIT 1;

  IF v_account_id IS NULL THEN
    RAISE EXCEPTION 'sin_cuenta_activa' USING ERRCODE = 'P0403';
  END IF;

  IF NOT public.is_account_writer(v_account_id) THEN
    RAISE EXCEPTION 'unauthorized' USING ERRCODE = 'P0401';
  END IF;

  IF p_amount IS NULL OR p_amount <= 0 THEN
    RAISE EXCEPTION 'invalid_amount: amount debe ser > 0, recibido: %', p_amount
      USING ERRCODE = 'P0400';
  END IF;

  -- cuenta-corriente-party-guard (D1 capa 2 / D2): el proveedor tiene que
  -- pertenecer al tenant. Sin bloque bancario de por medio, va directo
  -- después de la validación de amount y antes de la idempotencia.
  SELECT id INTO v_supplier
  FROM public.suppliers
  WHERE id = p_supplier_id AND account_id = v_account_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'supplier_not_found: %', p_supplier_id USING ERRCODE = 'P0404';
  END IF;

  -- Idempotencia DEC-06 (OQ-5): operation_kind='supplier_charge'
  v_new_op_id := gen_random_uuid();

  INSERT INTO public.operation_idempotency
    (user_id, idempotency_key, operation_kind, operation_id)
  VALUES
    (v_uid, p_idempotency_key, 'supplier_charge', v_new_op_id)
  ON CONFLICT (user_id, operation_kind, idempotency_key) DO NOTHING;

  GET DIAGNOSTICS v_inserted = ROW_COUNT;

  IF v_inserted = 0 THEN
    SELECT operation_id INTO v_existing_op
    FROM public.operation_idempotency
    WHERE user_id = v_uid
      AND operation_kind = 'supplier_charge'
      AND idempotency_key = p_idempotency_key;

    RETURN jsonb_build_object(
      'movement_id',         NULL,
      'supplier_account_id', NULL,
      'balance_after',       NULL,
      'replayed',            true,
      'operation_id',        v_existing_op
    );
  END IF;

  v_supplier_account_id := public.c30_get_or_create_supplier_account(v_account_id, p_supplier_id);

  -- Cargo positivo: aumenta lo que se debe al proveedor
  v_movement_id := public.c30_register_supplier_account_movement(
    v_supplier_account_id,
    p_amount,             -- positivo: el cargo sube el saldo (lo que se debe)
    'purchase',
    p_reference_id
  );

  SELECT balance_after INTO v_balance_after
  FROM public.supplier_account_movements
  WHERE id = v_movement_id;

  -- OQ-6: evento SupplierAccountCharged al outbox
  INSERT INTO public.events
    (account_id, event_type, aggregate_type, aggregate_id, payload, occurred_at)
  VALUES (
    v_account_id,
    'SupplierAccountCharged',
    'SupplierAccount',
    v_supplier_account_id,
    jsonb_build_object(
      'account_id',          v_account_id,
      'supplier_account_id', v_supplier_account_id,
      'supplier_id',         p_supplier_id,
      'movement_id',         v_movement_id,
      'amount',              p_amount,
      'balance_after',       v_balance_after,
      'occurred_at',         now()
    ),
    now()
  );

  RETURN jsonb_build_object(
    'movement_id',         v_movement_id,
    'supplier_account_id', v_supplier_account_id,
    'balance_after',       v_balance_after,
    'replayed',            false,
    'operation_id',        v_new_op_id
  );
END;
$function$;

COMMENT ON FUNCTION public.rpc_register_supplier_charge(text, uuid, numeric, uuid) IS
  'C-30 (supplier-account): registra un cargo manual de proveedor. '
  'cuenta-corriente-party-guard: valida que el proveedor pertenezca al tenant '
  '(P0404 supplier_not_found) después de la validación de amount y antes del '
  'INSERT de idempotencia. API pública de PostgREST: GRANT a authenticated, '
  'nunca a anon.';

REVOKE ALL ON FUNCTION public.rpc_register_supplier_charge(text, uuid, numeric, uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.rpc_register_supplier_charge(text, uuid, numeric, uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.rpc_register_supplier_charge(text, uuid, numeric, uuid) TO authenticated;


-- =============================================================================
-- 6. Cierre de la primitiva de escritura cross-tenant (Familia 2, D3).
--    SOLO DOCUMENTACIÓN — el `REVOKE` ya no vive acá.
--
--    OQ-2 se resolvió el 2026-08-23 como HOTFIX, no como parte de este apply
--    (orden del PO, patrón #446): el `REVOKE ALL … FROM PUBLIC, anon,
--    authenticated` de _pay_register_party_charge y _journal_post_from_event
--    está en 20261010000001_revoke_internal_money_helpers.sql (PR #454), que
--    ya se mergeó a `main` y corre ANTES que este archivo en la cadena de
--    reapply de CI. Repetirlo acá sería una segunda fuente de verdad sobre el
--    mismo ACL —dos migraciones que hay que acordarse de mantener en
--    sincronía— que es exactamente la clase de divergencia silenciosa que
--    este change existe para cerrar.
--
--    Lo que sí queda de este tramo:
--      · los dos `COMMENT ON FUNCTION` de abajo (el hotfix no escribe
--        comentarios: verificado, no hay `COMMENT` en su archivo), que dejan
--        el "por qué" pegado a la función y no sólo en una migración vieja;
--      · la VERIFICACIÓN del gate del punto 7: este archivo corre después del
--        hotfix, así que puede —y debe— asegurarse de que el REVOKE sigue en
--        pie. No lo re-ejecuta: lo audita y falla si alguien lo reabrió.
--
--    Por qué no se les agrega validación de sesión (alternativa descartada en
--    D3, sigue vigente): son helpers INTRA-TRANSACCIÓN llamados desde RPCs
--    que ya validaron; duplicar el chequeo en el hot path no aporta, y en el
--    caso de _journal_post_from_event sería directamente incorrecto — lo
--    invoca el dispatcher del outbox (rpc_process_outbox_dispatch, SECURITY
--    DEFINER, disparado por el job de pg_cron `relay-process-outbox` como
--    `postgres`), que corre SIN sesión de usuario. El diseño correcto para un
--    helper interno es no ser alcanzable: es lo que ya hace
--    _pay_reverse_party_charge (20261005000001 L186).
-- =============================================================================

-- Callers reales (todos SECURITY DEFINER → el PERFORM corre como el definer,
-- el revoke del hotfix es transparente): _c29_confirm_order_core (POS),
-- rpc_create_sale_operation y rpc_create_sale_operation_v2 (formulario).
COMMENT ON FUNCTION public._pay_register_party_charge(uuid, text, uuid, numeric, uuid, uuid) IS
  'pagos-cableados-restantes (party-account-charge): postea el cargo en la '
  'cuenta corriente de un tercero (cliente o proveedor). '
  'SIN GRANT — NO AGREGAR UNO. Recibe el account_id COMO PARÁMETRO: no lo '
  'resuelve de la sesión ni valida is_account_writer, así que expuesta a '
  '`authenticated` es una primitiva de escritura cross-tenant invocable desde '
  'PostgREST con el account_id de cualquier otro tenant (verificado en local: '
  'escribió en los libros reales de un tenant víctima). Solo callable desde '
  'RPCs SECURITY DEFINER, cuyo PERFORM corre como el definer. El GRANT que le '
  'puso 20261001000001 L137 lo revocó el hotfix '
  '20261010000001_revoke_internal_money_helpers.sql (PR #454); los chequeos '
  '(3) y (4) de supabase/tests/test_function_acl_gate.sql impiden que vuelva.';

-- Nació con REVOKE en 20260803000001 L517, reafirmado en 20260804000007 L934,
-- y lo PERDIÓ en 20261001000001 L1914 (arrastrado por 20261004000001 L1778),
-- donde el "patrón uniforme" REVOKE+GRANT —pensado para el gotcha de ALTER
-- DEFAULT PRIVILEGES en DROP+CREATE— se le aplicó en piloto automático a un
-- helper que nunca lo tuvo. El hotfix 20261010000001 restauró el estado
-- original.
COMMENT ON FUNCTION public._journal_post_from_event(public.events) IS
  'journal-entry-outbox (journal-entry): Consumer 3 — postea la partida doble '
  'de un evento del outbox. '
  'SIN GRANT — NO AGREGAR UNO. Recibe una fila de events COMPLETA (composite; '
  'PostgREST acepta un objeto JSON), así que expuesta a `authenticated` '
  'permite forjar un evento con cualquier account_id y postear un asiento '
  'arbitrario en otro tenant (verificado en local). Único caller: '
  'rpc_process_outbox_dispatch (SECURITY DEFINER), disparado por el job de '
  'pg_cron `relay-process-outbox`. Perdió su REVOKE original en '
  '20261001000001 L1914; lo restauró el hotfix '
  '20261010000001_revoke_internal_money_helpers.sql (PR #454) y los chequeos '
  '(3) y (4) de supabase/tests/test_function_acl_gate.sql impiden que vuelva '
  'a perderse.';


-- =============================================================================
-- 7. Gates de la propia migración.
-- =============================================================================

DO $$
DECLARE
  v_count integer;
  v_bad   text;
BEGIN
  -- ANTI-OVERLOAD 42725: ninguna de las 5 funciones cambió de firma, así que
  -- tiene que haber exactamente una definición de cada una. Cualquier valor
  -- distinto de 5 es un overload fantasma (un CREATE que no reemplazó nada).
  SELECT count(*) INTO v_count
  FROM pg_proc
  WHERE pronamespace = 'public'::regnamespace
    AND proname IN ('rpc_register_payment_received',
                    'rpc_register_payment_made',
                    'rpc_register_supplier_charge',
                    'c30_get_or_create_customer_account',
                    'c30_get_or_create_supplier_account');

  IF v_count <> 5 THEN
    RAISE EXCEPTION 'cuenta-corriente-party-guard ANTI-OVERLOAD: esperaba exactamente 5 definiciones de las 5 funciones reescritas (ninguna cambió de firma), hay %. Revisar overloads fantasma con: SELECT proname, pg_get_function_identity_arguments(oid) FROM pg_proc WHERE pronamespace = ''public''::regnamespace AND proname IN (...);', v_count;
  END IF;

  -- Entorno sin roles de Supabase (p.ej. postgres pelado): no hay ACL que verificar.
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') THEN
    RAISE NOTICE 'cuenta-corriente-party-guard: roles de Supabase ausentes — se omite la verificación de ACLs.';
    RETURN;
  END IF;

  -- (a) Los dos choke points que ESTE archivo revoca quedan inalcanzables para
  --     los dos roles de aplicación.
  SELECT string_agg(sig, ', ') INTO v_bad
  FROM (
    SELECT unnest(ARRAY[
      'public.c30_get_or_create_customer_account(uuid,uuid)',
      'public.c30_get_or_create_supplier_account(uuid,uuid)'
    ]) AS sig
  ) s
  WHERE has_function_privilege('anon',          s.sig::regprocedure, 'EXECUTE')
     OR has_function_privilege('authenticated', s.sig::regprocedure, 'EXECUTE');

  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION 'cuenta-corriente-party-guard ACL: los helpers internos no deben ser ejecutables por anon/authenticated, siguen expuestos: %', v_bad;
  END IF;

  -- (b) VERIFICACIÓN (no REVOKE) de la Familia 2: los dos helpers de dinero
  --     que revoca el hotfix 20261010000001_revoke_internal_money_helpers.sql
  --     (PR #454) tienen que seguir cerrados. Este archivo corre DESPUÉS de
  --     ese hotfix —en `supabase start`/`db push` por número, y en la cadena
  --     de reapply de KPI_Validation.yml por orden explícito—, así que es el
  --     último en tocar el schema y por lo tanto el lugar natural para
  --     detectar que un eslabón intermedio se los reabrió: 20261001000001
  --     (L137) y 20261004000001 (~L1778) lo hacen cada vez que se reaplican.
  --     Si esto falla, el problema NO está en este archivo: está en el orden
  --     de la cadena o en una migración nueva que volvió a arrastrar el
  --     bloque REVOKE+GRANT "de plantilla" sobre un helper interno.
  SELECT string_agg(sig, ', ') INTO v_bad
  FROM (
    SELECT unnest(ARRAY[
      'public._pay_register_party_charge(uuid,text,uuid,numeric,uuid,uuid)',
      'public._journal_post_from_event(public.events)'
    ]) AS sig
  ) s
  WHERE has_function_privilege('anon',          s.sig::regprocedure, 'EXECUTE')
     OR has_function_privilege('authenticated', s.sig::regprocedure, 'EXECUTE');

  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION 'cuenta-corriente-party-guard ACL: los helpers de dinero revocados por 20261010000001_revoke_internal_money_helpers.sql (PR #454) volvieron a ser ejecutables por anon/authenticated — alguien los reabrió después de ese hotfix (¿bloque REVOKE+GRANT "de plantilla" en una migración nueva, o eslabón mal ordenado en la cadena de reapply de KPI_Validation.yml?): %', v_bad;
  END IF;

  -- Las 3 RPCs públicas conservan su EXECUTE para authenticated y NO lo tienen
  -- para anon (control negativo: el REVOKE de arriba no se pasó de rosca).
  SELECT string_agg(sig, ', ') INTO v_bad
  FROM (
    SELECT unnest(ARRAY[
      'public.rpc_register_payment_received(text,uuid,numeric,uuid,text,uuid)',
      'public.rpc_register_payment_made(text,uuid,numeric,uuid,text,uuid)',
      'public.rpc_register_supplier_charge(text,uuid,numeric,uuid)'
    ]) AS sig
  ) s
  WHERE NOT has_function_privilege('authenticated', s.sig::regprocedure, 'EXECUTE')
     OR      has_function_privilege('anon',         s.sig::regprocedure, 'EXECUTE');

  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION 'cuenta-corriente-party-guard ACL: las RPCs públicas deben conservar EXECUTE para authenticated y NO tenerlo para anon, están mal: %', v_bad;
  END IF;

  RAISE NOTICE 'cuenta-corriente-party-guard OK: 5 funciones con una sola definición, 2 choke points revocados acá + 2 helpers de dinero verificados (revocados por 20261010000001, PR #454) cerrados a anon/authenticated, 3 RPCs públicas con su GRANT intacto.';
END $$;
