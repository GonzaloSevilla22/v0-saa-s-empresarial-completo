CREATE OR REPLACE FUNCTION public.rpc_my_effective_plan()
 RETURNS text
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_account_id uuid;
BEGIN
  -- D2: cuenta de la membresía MÁS ANTIGUA entre las elegibles según el
  -- helper canónico current_account_ids() (20260606000001) — desempate por
  -- account_id ASC si dos membresías comparten created_at exacto.
  --
  -- CRÍTICO: el filtro `am.user_id = (SELECT auth.uid())` es OBLIGATORIO acá
  -- y NO es redundante con `account_id IN (SELECT current_account_ids())`.
  -- Ese IN solo restringe QUÉ CUENTAS son elegibles; no restringe qué FILA
  -- de account_members se lee para cada una. En una cuenta compartida (2+
  -- miembros) hay una fila por miembro — sin este filtro, el ORDER BY podía
  -- levantar la fila de OTRO usuario (p. ej. el owner de una cuenta de la
  -- que el llamador es simple member) y devolver el plan de una cuenta que
  -- el llamador nunca tuvo intención de resolver. Confirmado con un anchor
  -- de 2 cuentas + 2 usuarios: sin este filtro, el resultado era
  -- indeterminista (~30-50% de las corridas) dependiendo del orden aleatorio
  -- de los UUID de cuenta al desempatar por created_at entre filas de
  -- USUARIOS DISTINTOS que por casualidad compartían timestamp.
  SELECT am.account_id
  INTO v_account_id
  FROM public.account_members am
  WHERE am.user_id = (SELECT auth.uid())
    AND am.account_id IN (SELECT public.current_account_ids())
  ORDER BY am.created_at ASC, am.account_id ASC
  LIMIT 1;

  -- Sin cuenta resoluble (usuario sin membresía, o sin sesión válida):
  -- fail-closed, nunca lanza.
  IF v_account_id IS NULL THEN
    RETURN 'gratis';
  END IF;

  RETURN public.get_effective_plan(v_account_id);
END;
$function$

-- ACL: {postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}
-- COMMENT: billing-edge-effective-plan (D1/D2, sign-off PO 2026-07-31): wrapper SIN argumentos sobre get_effective_plan(uuid) para que las Edge Functions (JWT de usuario, sin service_role) lean el plan efectivo sin exponer get_effective_plan a authenticated (permanece revocada — D2 de billing-pro-trial). La cuenta del llamador se deriva SIEMPRE de auth.uid() vía current_account_ids(): es imposible por construcción consultar el plan de una cuenta ajena. Regla de desempate multi-cuenta (OQ-4): la membresía con MENOR account_members.created_at (más antigua); si dos membresías comparten created_at exacto, desempata el MENOR account_id. Sin cuenta resoluble: gratis (fail-closed, D5). No introduce "cuenta activa" seleccionable — eso pertenece a v3-rbac-multirole.
