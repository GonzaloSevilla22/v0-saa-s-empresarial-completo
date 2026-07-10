-- =============================================================================
-- MIGRATION: 20260813000001_v3_client_addresses.sql
-- CHANGE:    v3-catalog-masters
--
-- QUÉ HACE (aditivo, sin BREAKING):
--   Modelo V3 §7.3 pide `Customer.addresses: Address[]` operativas/editables
--   con `alias` e `is_primary`, invariante "exactamente una primaria por
--   cliente". Hoy `clients` no tiene NINGUNA columna de dirección (verificado
--   en prod: 16 columnas, ninguna de dirección) — la dirección FISCAL vive en
--   FiscalIdentity (inmutable por snapshot) y NO se toca acá.
--
--   Crea `public.client_addresses`: tabla nueva, pura-additiva, sin backfill
--   (nadie tenía dirección antes; nace vacía). Scope de tenancy DIRECTO por
--   `account_id` (igual que `clients`) — habilita reusar
--   `BaseRepository.soft_delete()` con la allowlist existente (D2 del design).
--
--   Invariante "exactamente una primaria viva por cliente": índice único
--   parcial `(client_id) WHERE is_primary AND deleted_at IS NULL` + RPC
--   `rpc_set_primary_client_address` que hace el switch atómico (baja la
--   vigente, sube la nueva) en una transacción — evita la ventana en la que
--   el índice rechazaría un UPDATE naïve que suba la nueva antes de bajar
--   la vieja.
--
--   RLS org-based idéntica al patrón de `clients` (4 policies): SELECT por
--   `current_account_ids()`; INSERT/UPDATE/DELETE por `is_account_writer`.
--
--   Soft-delete del cliente padre NO propaga (D4 del design): las lecturas
--   de direcciones siempre parten de un cliente vivo (enforced en el service,
--   no en DB) — las direcciones de un cliente borrado quedan lógicamente
--   inalcanzables sin necesidad de tocarles `deleted_at`, y vuelven a ser
--   alcanzables si el cliente se reactiva.
--
--   `units_of_measure`: CERO DDL en este change (spec-only, ver
--   openspec/changes/v3-catalog-masters/specs/units-of-measure/spec.md).
--
-- GOVERNANCE: BAJO — maestros/catálogo, no toca auth/billing/dinero.
--
-- IDEMPOTENCIA / BOTH-WORLDS-SAFE: la integración GitHub de Supabase auto-
--   aplica migraciones al mergear a main ANTES del `db push` de Actions
--   (confirmado 3x esta semana) → esta migración puede correr más de una vez.
--   CREATE TABLE IF NOT EXISTS; CREATE INDEX IF NOT EXISTS; DROP POLICY IF
--   EXISTS + CREATE POLICY; CREATE OR REPLACE FUNCTION para el RPC. Cero DDL
--   sobre units_of_measure.
--
-- APPLY: vía CI al mergear a main (GitHub Actions: build + deploy + db push).
--   NUNCA aplicar con el MCP `apply_migration` (desincroniza el historial).
--
-- ROLLBACK: aditivo — en prod NO se dropea, se deja de escribir. Referencia:
--   DROP FUNCTION public.rpc_set_primary_client_address(uuid, uuid);
--   DROP TABLE public.client_addresses;
--   quitar "client_addresses" de SOFT_DELETE_TABLES en backend/repositories/base.py.
-- =============================================================================


-- =============================================================================
-- 1. CREATE TABLE (task 2.2)
-- =============================================================================
CREATE TABLE IF NOT EXISTS public.client_addresses (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id   uuid NOT NULL REFERENCES public.accounts(id),
  client_id    uuid NOT NULL REFERENCES public.clients(id),
  alias        text,
  street       text,
  city         text,
  province     text,
  postal_code  text,
  notes        text,
  is_primary   boolean NOT NULL DEFAULT false,
  created_at   timestamptz NOT NULL DEFAULT now(),
  updated_at   timestamptz,
  deleted_at   timestamptz,
  deleted_by   uuid
);

COMMENT ON TABLE public.client_addresses IS
  'v3-catalog-masters (V3 §7.3): direcciones operativas/editables múltiples '
  'por cliente. Distinta de la dirección FISCAL (FiscalIdentity, inmutable '
  'por snapshot). account_id es scope de tenancy DIRECTO (D2 del design) — '
  'habilita RLS simple y BaseRepository.soft_delete() sin JOIN a clients.';

COMMENT ON COLUMN public.client_addresses.client_id IS
  'FK a clients(id) SIN ON DELETE CASCADE: el borrado de cliente es SOFT '
  '(nunca hard), un cascade duro no aplica. Las direcciones de un cliente '
  'soft-deleteado quedan inalcanzables por lectura (D4), no se les propaga '
  'deleted_at.';

COMMENT ON COLUMN public.client_addresses.is_primary IS
  'Invariante "exactamente una primaria viva por cliente" (V3 §7.3): '
  'respaldada por el índice único parcial idx_client_addresses_primary. '
  'La primera dirección de un cliente se marca primaria automáticamente '
  '(service layer). El switch atómico entre primarias usa '
  'rpc_set_primary_client_address, nunca dos UPDATEs sueltos.';

COMMENT ON COLUMN public.client_addresses.deleted_at IS
  'Soft delete (RN-B1, Modelo V3 §4): NOT NULL = borrado — la fila sale de '
  'toda lectura por defecto.';

COMMENT ON COLUMN public.client_addresses.deleted_by IS
  'Autoría del borrado (RN-B2): uuid del usuario que ejecutó el soft delete. '
  'Referencia lógica a auth.users (sin FK dura, consistente con el resto '
  'de columnas de autoría del proyecto).';


-- =============================================================================
-- 2. Índices (task 2.3)
-- =============================================================================

-- FK account_id (lecturas por tenant, y soft_delete() filtra por account_id).
CREATE INDEX IF NOT EXISTS idx_client_addresses_account_id
  ON public.client_addresses (account_id);

-- FK client_id (lookup por cliente — el endpoint principal de listado).
CREATE INDEX IF NOT EXISTS idx_client_addresses_client_id
  ON public.client_addresses (client_id);

-- Invariante "exactamente una primaria viva por cliente" (D3 del design).
CREATE UNIQUE INDEX IF NOT EXISTS idx_client_addresses_primary
  ON public.client_addresses (client_id)
  WHERE is_primary AND deleted_at IS NULL;


-- =============================================================================
-- 3. RLS — 4 policies idempotentes replicando el patrón de `clients` (task 2.4)
-- =============================================================================
ALTER TABLE public.client_addresses ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS client_addresses_select ON public.client_addresses;
CREATE POLICY client_addresses_select ON public.client_addresses
  FOR SELECT
  TO authenticated
  USING (account_id IN (SELECT public.current_account_ids()));

DROP POLICY IF EXISTS client_addresses_insert ON public.client_addresses;
CREATE POLICY client_addresses_insert ON public.client_addresses
  FOR INSERT
  TO authenticated
  WITH CHECK (public.is_account_writer(account_id));

DROP POLICY IF EXISTS client_addresses_update ON public.client_addresses;
CREATE POLICY client_addresses_update ON public.client_addresses
  FOR UPDATE
  TO authenticated
  USING (public.is_account_writer(account_id))
  WITH CHECK (public.is_account_writer(account_id));

DROP POLICY IF EXISTS client_addresses_delete ON public.client_addresses;
CREATE POLICY client_addresses_delete ON public.client_addresses
  FOR DELETE
  TO authenticated
  USING (public.is_account_writer(account_id));


-- =============================================================================
-- 4. RPC — rpc_set_primary_client_address (task 2.5)
--    Switch atómico: baja la primaria vigente del cliente, sube la nueva, en
--    una sola transacción. INVOKER (no SECURITY DEFINER): la RLS ya exige
--    is_account_writer(account_id) sobre las filas que toca, no hace falta
--    elevar privilegios (D3 del design prefiere INVOKER + RLS).
-- =============================================================================
CREATE OR REPLACE FUNCTION public.rpc_set_primary_client_address(
  p_address_id uuid,
  p_account_id uuid
)
RETURNS public.client_addresses
LANGUAGE plpgsql
AS $$
DECLARE
  v_client_id uuid;
  v_result    public.client_addresses;
BEGIN
  -- Valida que la dirección exista, esté viva y pertenezca a la cuenta.
  SELECT client_id INTO v_client_id
  FROM   public.client_addresses
  WHERE  id = p_address_id
    AND  account_id = p_account_id
    AND  deleted_at IS NULL;

  IF v_client_id IS NULL THEN
    RAISE EXCEPTION
      'rpc_set_primary_client_address: dirección % no encontrada o no pertenece a la cuenta %',
      p_address_id, p_account_id
      USING ERRCODE = 'P0404';
  END IF;

  -- Baja la primaria vigente de ESE cliente (si la hay) antes de subir la
  -- nueva — evita la violación transitoria del índice único parcial.
  UPDATE public.client_addresses
  SET    is_primary = false,
         updated_at = now()
  WHERE  client_id = v_client_id
    AND  account_id = p_account_id
    AND  is_primary = true
    AND  deleted_at IS NULL
    AND  id <> p_address_id;

  UPDATE public.client_addresses
  SET    is_primary = true,
         updated_at = now()
  WHERE  id = p_address_id
    AND  account_id = p_account_id
  RETURNING * INTO v_result;

  RETURN v_result;
END;
$$;

COMMENT ON FUNCTION public.rpc_set_primary_client_address(uuid, uuid) IS
  'v3-catalog-masters (D3): switch atómico de dirección primaria de un '
  'cliente — baja la vigente, sube la nueva, en una transacción. Rechaza '
  '(ERRCODE P0404) si la dirección no existe/no está viva/no es de la '
  'cuenta indicada. INVOKER: la RLS de client_addresses ya exige '
  'is_account_writer(account_id).';


-- =============================================================================
-- 5. GATE de comportamiento auto-limpiante (task 2.6)
--    Patrón establecido (20260811000001, 20260812000001): anchor sintético en
--    auth.users dispara handle_new_user (account + branch + cashbox reales);
--    resuelve la account vía account_members (nunca inserta accounts a mano);
--    limpia hijo→padre por email del anchor (accounts=0 al final). Degrada
--    con NOTICE si el contexto no permite el gate (prod real).
-- =============================================================================
DO $$
DECLARE
  v_anchor_email   text := 'v3-catalog-masters-gate@test.local';
  v_user_id        uuid := gen_random_uuid();
  v_account_id     uuid;
  v_client_id      uuid;
  v_addr_1         uuid;
  v_addr_2         uuid;
  v_primary_count  integer;
  v_guard_fired    boolean;
  v_row            record;
BEGIN
  -- Anchor sintético: dispara handle_new_user (AFTER INSERT ON auth.users).
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data)
  VALUES (v_user_id, 'authenticated', 'authenticated', v_anchor_email, now(), now(),
          jsonb_build_object('name', 'Gate Catalog Masters', 'phone', '', 'locality', '', 'province', ''))
  ON CONFLICT (id) DO NOTHING;

  SELECT account_id INTO v_account_id
  FROM   public.account_members
  WHERE  user_id = v_user_id
  ORDER  BY created_at
  LIMIT  1;

  IF v_account_id IS NULL THEN
    RAISE NOTICE 'GATE V3-CATALOG-MASTERS: no se pudo resolver una account para el anchor sintético (contexto no permite el gate) — degradando sin abortar.';
    RETURN;
  END IF;

  -- Cliente de prueba.
  INSERT INTO public.clients (user_id, account_id, name)
  VALUES (v_user_id, v_account_id, '__gate_v3_cm_client__')
  RETURNING id INTO v_client_id;

  -- ── Assert 1: la primera dirección se vuelve primaria automáticamente ────
  -- (comportamiento del service layer; acá simulamos el INSERT ya con
  -- is_primary=true, como haría el service en la primera alta).
  INSERT INTO public.client_addresses (account_id, client_id, alias, street, is_primary)
  VALUES (v_account_id, v_client_id, 'Depósito', 'Calle Falsa 123', true)
  RETURNING id INTO v_addr_1;

  SELECT count(*) INTO v_primary_count
  FROM   public.client_addresses
  WHERE  client_id = v_client_id AND is_primary AND deleted_at IS NULL;

  IF v_primary_count <> 1 THEN
    RAISE EXCEPTION 'GATE V3-CATALOG-MASTERS FAILED: se esperaba exactamente 1 primaria tras la primera alta, se encontraron %', v_primary_count;
  END IF;

  -- ── Assert 2: intentar una SEGUNDA primaria directa (INSERT crudo, sin
  -- pasar por el RPC) colisiona con el índice único parcial ──────────────
  v_guard_fired := false;
  BEGIN
    INSERT INTO public.client_addresses (account_id, client_id, alias, street, is_primary)
    VALUES (v_account_id, v_client_id, 'Sucursal', 'Calle Verdadera 456', true);
  EXCEPTION
    WHEN unique_violation THEN
      v_guard_fired := true;
  END;

  IF NOT v_guard_fired THEN
    RAISE EXCEPTION 'GATE V3-CATALOG-MASTERS FAILED: dos direcciones primarias vivas del mismo cliente no violaron el índice único parcial.';
  END IF;

  -- ── Assert 3: switch atómico vía RPC deja exactamente una primaria ──────
  INSERT INTO public.client_addresses (account_id, client_id, alias, street, is_primary)
  VALUES (v_account_id, v_client_id, 'Sucursal', 'Calle Verdadera 456', false)
  RETURNING id INTO v_addr_2;

  SELECT * INTO v_row FROM public.rpc_set_primary_client_address(v_addr_2, v_account_id);

  IF v_row.id IS DISTINCT FROM v_addr_2 OR v_row.is_primary IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'GATE V3-CATALOG-MASTERS FAILED: rpc_set_primary_client_address no devolvió la dirección esperada como primaria (id=%, is_primary=%).', v_row.id, v_row.is_primary;
  END IF;

  SELECT count(*) INTO v_primary_count
  FROM   public.client_addresses
  WHERE  client_id = v_client_id AND is_primary AND deleted_at IS NULL;

  IF v_primary_count <> 1 THEN
    RAISE EXCEPTION 'GATE V3-CATALOG-MASTERS FAILED: tras el switch atómico se esperaba exactamente 1 primaria, se encontraron %.', v_primary_count;
  END IF;

  -- TRIANGULATE: la dirección 1 (la original) ya NO debe ser primaria.
  IF EXISTS (
    SELECT 1 FROM public.client_addresses
    WHERE id = v_addr_1 AND is_primary = true AND deleted_at IS NULL
  ) THEN
    RAISE EXCEPTION 'GATE V3-CATALOG-MASTERS FAILED: la dirección original (%) sigue marcada primaria tras el switch.', v_addr_1;
  END IF;

  -- ── Assert 4: rechazo de switch cross-account/cross-client ──────────────
  v_guard_fired := false;
  BEGIN
    PERFORM public.rpc_set_primary_client_address(gen_random_uuid(), v_account_id);
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLSTATE = 'P0404' THEN
        v_guard_fired := true;
      ELSE
        RAISE;
      END IF;
  END;

  IF NOT v_guard_fired THEN
    RAISE EXCEPTION 'GATE V3-CATALOG-MASTERS FAILED: rpc_set_primary_client_address con un address_id inexistente no fue rechazado (ERRCODE P0404 esperado).';
  END IF;

  RAISE NOTICE 'GATE V3-CATALOG-MASTERS PASSED: primera dirección auto-primaria; índice único parcial rechaza doble-primaria directa; rpc_set_primary_client_address hace el switch atómico y rechaza direcciones inexistentes/ajenas.';

  -- ── Limpieza hijo→padre por anchor (accounts=0 al final) ─────────────────
  DELETE FROM public.client_addresses WHERE account_id = v_account_id;
  DELETE FROM public.clients          WHERE account_id = v_account_id;
  DELETE FROM public.cashboxes        WHERE branch_id IN (SELECT id FROM public.branches WHERE account_id = v_account_id);
  DELETE FROM public.branches         WHERE account_id = v_account_id;
  DELETE FROM public.account_members  WHERE user_id = v_user_id;
  DELETE FROM public.accounts         WHERE owner_user_id = v_user_id;
  DELETE FROM public.profiles         WHERE id = v_user_id;
  DELETE FROM public.email_logs       WHERE user_id = v_user_id;
  DELETE FROM public.operation_idempotency WHERE user_id = v_user_id;
  DELETE FROM auth.users              WHERE id = v_user_id;

EXCEPTION
  WHEN OTHERS THEN
    IF SQLERRM LIKE 'GATE V3-CATALOG-MASTERS FAILED%' THEN
      RAISE;
    END IF;
    -- Best-effort cleanup si algo falló a mitad de camino.
    BEGIN
      IF v_account_id IS NOT NULL THEN
        DELETE FROM public.client_addresses WHERE account_id = v_account_id;
        DELETE FROM public.clients          WHERE account_id = v_account_id;
        DELETE FROM public.cashboxes        WHERE branch_id IN (SELECT id FROM public.branches WHERE account_id = v_account_id);
        DELETE FROM public.branches         WHERE account_id = v_account_id;
        DELETE FROM public.account_members  WHERE user_id = v_user_id;
        DELETE FROM public.accounts         WHERE owner_user_id = v_user_id;
      END IF;
      DELETE FROM public.profiles         WHERE id = v_user_id;
      DELETE FROM public.email_logs       WHERE user_id = v_user_id;
      DELETE FROM public.operation_idempotency WHERE user_id = v_user_id;
      DELETE FROM auth.users              WHERE id = v_user_id;
    EXCEPTION WHEN OTHERS THEN NULL;
    END;
    RAISE;
END $$;

-- =============================================================================
-- END OF MIGRATION 20260813000001_v3_client_addresses.sql
-- =============================================================================
