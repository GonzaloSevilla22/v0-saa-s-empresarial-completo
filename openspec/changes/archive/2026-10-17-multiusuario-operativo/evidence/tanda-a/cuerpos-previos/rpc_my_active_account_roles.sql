CREATE OR REPLACE FUNCTION public.rpc_my_active_account_roles()
 RETURNS text[]
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  -- Ronda 1 adversarial (nit 7): COALESCE a ARRAY vacío -- sin esto, un
  -- caller sin ninguna membresía (el LIMIT 1 sin filas) devuelve NULL, lo
  -- que contradecía el COMMENT ("array vacío, no NULL"). Mismo criterio que
  -- member_active_roles/account_user_active_roles de la Parte A -- las TRES
  -- funciones de la familia "roles activos" quedan con el mismo contrato:
  -- ARRAY vacío, nunca NULL.
  SELECT COALESCE(
    (SELECT public.member_active_roles(am.id)
     FROM   public.account_members am
     WHERE  am.user_id = (SELECT auth.uid())
     ORDER BY am.created_at, am.id
     LIMIT 1),
    ARRAY[]::text[]
  );
$function$

-- ACL: {postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}
-- COMMENT: v3-rbac-multirole Parte B (D10, R6): roles ACTIVOS del CALLER en su membresía más antigua (mismo criterio determinístico que get_account_id / el hook, D4 de v31-authz-token-hook) -- SIN parámetro, no hay ningún member_id que un tercero pueda pasar. DOS consumidores, los dos en require_account_role (backend/core/guards.py): (1) el fallback a DB cuando ni el claim del conjunto ni el singular viajan en el JWT, y (2) desde auth-hardening-jwt-cookies D12, el camino PRIMARIO de toda capacidad sensible (rbac.py::SENSITIVE_CAPABILITIES, hoy CAN_CONFIGURE = owner/admin): ahí se la consulta AUNQUE el claim esté presente, porque para las acciones de configuración el claim es un caché y la base es la autoridad -- un rol revocado o vencido deja de autorizar sin esperar a la próxima emisión de token. Array vacío (no NULL) si el caller no es miembro de ninguna cuenta -- COALESCE explícito (ronda 1 adversarial, nit 7), mismo contrato que member_active_roles/account_user_active_roles de la Parte A.
