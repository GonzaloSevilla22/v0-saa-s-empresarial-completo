-- =============================================================================
-- 20261078000001_documentos_marca_empresa.sql
-- documentos-marca-empresa, TANDA A (governance MEDIA)
--
-- PEDIDO DEL PO (2026-10-11): "Necesito que en todos los comprobantes, remitos,
-- facturas, presupuesto, etc., tenga toda la información de la empresa y el
-- logo de la misma, de cada usuario. Y sacale el color verde y dejalos blancos,
-- o en Configuración que cada usuario pueda elegir la paleta de colores que
-- ellos decidan para estos papeles." Sign-off anticipado (2026-10-11):
-- "continuá con todo lo recomendado" — las OQ-1…OQ-14 del design se aplican
-- según su recomendación. "De cada usuario" es DE CADA CUENTA (tenant): el logo
-- y los datos son del negocio, no de la persona logueada.
--
-- MEDICIÓN DEL PROPOSE (prod, 2026-10-11, sólo lectura; re-medida en el apply):
--   * 41 cuentas, 2 perfiles fiscales, 6 dueños con business_name, 19 con
--     teléfono, 6 con avatar; 0 cuentas multiusuario; base de 58 MB.
--   * public.account_branding y un bucket `branding` NO existen.
--   * rpc_commercial_issuer(uuid): cuerpo vivo md5 (sin CR)
--     3abc66aee3eb3c2b19d5f8a3305941d9, 1.119 caracteres, ACL
--     {postgres=X, authenticated=X, service_role=X}, SECURITY DEFINER, STABLE,
--     devuelve EXACTAMENTE 6 claves. Idéntico a 20261067000001:939-980 — esta
--     migración parte de ESE cuerpo vivo y cambia sólo lo marcado con
--     "documentos-marca-empresa".
--   * 43 políticas que invocan is_account_writer sobre 17 tablas → con las dos
--     de escritura de la tabla nueva: 45 sobre 18.
--
-- QUÉ HACE
--   1. Tabla `public.account_branding` (una fila por cuenta; molde
--      `scale_settings`, 20261066000001:161-262): nombre comercial para los
--      papeles, razón social, CUIT, domicilio, teléfono, email DEL NEGOCIO,
--      sitio web, leyenda al pie, paleta (catálogo cerrado + color
--      personalizado) y el LOGO NORMALIZADO por el backend. CHECKs de forma como
--      segunda capa (la primera es Pydantic). Sin fila = valores por defecto
--      (paleta Neutro, sin logo).
--   2. RLS: SELECT de cualquier miembro; INSERT/UPDATE `is_account_writer`;
--      SIN política de DELETE. Disparador `trg_account_branding_guard_owner_admin`
--      (BEFORE INSERT OR UPDATE): sólo owner/admin escriben (P0401) y la fila no
--      se muda de cuenta. Privilegios: anon sin NINGUNO; authenticated SIN
--      DELETE/TRUNCATE/REFERENCES/TRIGGER ("sin DELETE" cerrado también en la
--      capa de privilegio; scale_settings conserva arwdDxtm — hallazgo lateral).
--   3. `rpc_commercial_issuer(uuid)` ampliada con la MISMA firma
--      (CREATE OR REPLACE: no hay overload ni se resetea la ACL): 6 claves
--      legadas + 12 nuevas, planas y aditivas (iva_condition, brand_*, paleta,
--      huella del logo) = 18. NUNCA la imagen ni un email de Auth (la función no
--      lee auth.users).
--
-- DESVÍO DEL BRIEF (declarado, design D2): el logo se guarda NORMALIZADO EN LA
-- BASE (`logo_image bytea`, ≤ 300 KB, PNG/JPEG) y no en un bucket de Storage.
-- Razones: (1) regla dura del proyecto "NUNCA service_role en el backend" — bajar
-- el logo en cada PDF que genera un usuario no es un job administrativo; (2) la
-- subida tiene que pasar por el backend de todos modos (bomba de descompresión,
-- reescalado, metadatos) y escribir en Storage exigiría credenciales de escritura
-- → service_role; (3) en la base todo va por la misma conexión con JWT (RLS +
-- disparador + CHECKs) y el gate puede EJECUTAR el camino. Costo acotado: 41 × 300
-- KB = 12 MB en el peor caso; umbral de revisión ~2.000 cuentas con logo.
--
-- ORDEN DE DESPLIEGUE: aditiva (tabla nueva + RPC con la misma firma y claves de
-- más) → un backend viejo contra la base nueva sigue leyendo sus 6 claves; el
-- backend nuevo contra la base vieja resuelve la marca sólo por la RPC
-- (claves ausentes → valores por defecto). Rollback: revert del PR (la tabla
-- queda inerte; la RPC con claves de más no molesta a un backend viejo).
--
-- IDEMPOTENCIA: CREATE TABLE IF NOT EXISTS, DROP POLICY IF EXISTS + CREATE,
-- REVOKE/GRANT repetibles, CREATE OR REPLACE, DROP TRIGGER IF EXISTS + CREATE.
-- Sin DROP FUNCTION.
-- =============================================================================

-- ── 1. account_branding ──────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.account_branding (
  account_id       uuid        PRIMARY KEY REFERENCES public.accounts(id) ON DELETE CASCADE,
  display_name     text        NULL,
  legal_name       text        NULL,
  tax_id           text        NULL,
  address          text        NULL,
  phone            text        NULL,
  email            text        NULL,
  website          text        NULL,
  footer_note      text        NULL,
  palette_preset   text        NOT NULL DEFAULT 'neutro',
  accent_color     text        NULL,
  logo_image       bytea       NULL,
  logo_mime        text        NULL,
  logo_sha256      text        NULL,
  logo_width       integer     NULL,
  logo_height      integer     NULL,
  logo_updated_at  timestamptz NULL,
  updated_at       timestamptz NOT NULL DEFAULT now(),
  updated_by       uuid        NULL,

  -- Textos: el vacío se guarda como NULL, nunca como blanco (btrim <> '').
  CONSTRAINT account_branding_display_name_check CHECK (
    display_name IS NULL OR (btrim(display_name) <> '' AND char_length(display_name) <= 80)),
  CONSTRAINT account_branding_legal_name_check CHECK (
    legal_name IS NULL OR (btrim(legal_name) <> '' AND char_length(legal_name) <= 120)),
  CONSTRAINT account_branding_address_check CHECK (
    address IS NULL OR (btrim(address) <> '' AND char_length(address) <= 200)),
  CONSTRAINT account_branding_phone_check CHECK (
    phone IS NULL OR (btrim(phone) <> '' AND char_length(phone) <= 40)),
  CONSTRAINT account_branding_footer_note_check CHECK (
    footer_note IS NULL OR (btrim(footer_note) <> '' AND char_length(footer_note) <= 280)),
  -- Forma de dirección de correo: sin espacios, arroba ni marcado; dominio con punto.
  CONSTRAINT account_branding_email_check CHECK (
    email IS NULL OR (btrim(email) <> '' AND char_length(email) <= 120
      AND email ~ '^[^[:space:]@<>"]+@[^[:space:]@<>"]+\.[^[:space:]@<>"]+$')),
  -- CUIT NN-NNNNNNNN-N (guiones opcionales). La validación del dígito
  -- verificador vive en el backend y en el zod del frontend.
  CONSTRAINT account_branding_tax_id_check CHECK (
    tax_id IS NULL OR tax_id ~ '^[0-9]{2}-?[0-9]{8}-?[0-9]$'),
  -- Sitio web: sin espacios ni caracteres de marcado (se imprime como TEXTO).
  CONSTRAINT account_branding_website_check CHECK (
    website IS NULL OR (btrim(website) <> '' AND char_length(website) <= 120
      AND website !~ '[[:space:]<>"]')),

  -- Paleta: catálogo cerrado + color personalizado presente SI Y SÓLO SI la
  -- paleta es 'personalizado'. La aritmética de contraste NO va en un CHECK:
  -- la cubre el servicio (422) y el render (cae a Neutro).
  CONSTRAINT account_branding_palette_preset_check CHECK (
    palette_preset IN ('neutro', 'azul', 'verde', 'grafito', 'bordo', 'personalizado')),
  CONSTRAINT account_branding_accent_color_check CHECK (
    accent_color IS NULL OR accent_color ~ '^#[0-9a-f]{6}$'),
  CONSTRAINT account_branding_palette_accent_coherent_check CHECK (
    (palette_preset = 'personalizado') = (accent_color IS NOT NULL)),

  -- Logo: todo o nada (las seis columnas logo_*), tipo y FIRMA coherentes,
  -- tamaño y dimensiones acotados. El backend ya normalizó la imagen; esto es la
  -- red para una escritura directa por PostgREST.
  CONSTRAINT account_branding_logo_all_or_nothing_check CHECK (
    (logo_image IS NULL AND logo_mime IS NULL AND logo_sha256 IS NULL
       AND logo_width IS NULL AND logo_height IS NULL AND logo_updated_at IS NULL)
    OR
    (logo_image IS NOT NULL AND logo_mime IS NOT NULL AND logo_sha256 IS NOT NULL
       AND logo_width IS NOT NULL AND logo_height IS NOT NULL AND logo_updated_at IS NOT NULL)),
  CONSTRAINT account_branding_logo_mime_check CHECK (
    logo_mime IS NULL OR logo_mime IN ('image/png', 'image/jpeg')),
  CONSTRAINT account_branding_logo_signature_check CHECK (
    logo_image IS NULL
    OR (logo_mime = 'image/png'  AND substring(logo_image FROM 1 FOR 8) = decode('89504e470d0a1a0a', 'hex'))
    OR (logo_mime = 'image/jpeg' AND substring(logo_image FROM 1 FOR 3) = decode('ffd8ff', 'hex'))),
  CONSTRAINT account_branding_logo_size_check CHECK (
    logo_image IS NULL OR octet_length(logo_image) <= 307200),
  CONSTRAINT account_branding_logo_sha256_check CHECK (
    logo_sha256 IS NULL OR logo_sha256 ~ '^[0-9a-f]{64}$'),
  CONSTRAINT account_branding_logo_dimensions_check CHECK (
    (logo_width  IS NULL OR logo_width  BETWEEN 1 AND 1000)
    AND (logo_height IS NULL OR logo_height BETWEEN 1 AND 1000))
);

COMMENT ON TABLE public.account_branding IS
  'documentos-marca-empresa (D1, capability document-branding): marca de la cuenta para los papeles que '
  'entrega a terceros (comprobante interno, presupuesto, remitos y, en la tanda B, la Factura C): nombre '
  'comercial, razón social, CUIT, domicilio, teléfono, email DEL NEGOCIO (nunca el de acceso), sitio web, '
  'leyenda al pie, paleta de colores y logo normalizado. Una fila por cuenta; sin fila = valores por defecto '
  '(paleta Neutro, sin logo). Escritura sólo owner/admin (disparador trg_account_branding_guard_owner_admin, '
  'P0401) además de la RLS is_account_writer; sin DELETE ni TRUNCATE para authenticated. Se LEE por '
  'rpc_commercial_issuer (que devuelve la huella del logo, nunca la imagen) y por GET /document-branding.';
COMMENT ON COLUMN public.account_branding.display_name IS
  'documentos-marca-empresa (D4): nombre comercial que encabeza los papeles (gana sobre el nombre de fantasía fiscal).';
COMMENT ON COLUMN public.account_branding.legal_name IS
  'documentos-marca-empresa (D4): razón social; sólo se usa si el perfil fiscal no la tiene.';
COMMENT ON COLUMN public.account_branding.tax_id IS
  'documentos-marca-empresa (D4): CUIT NN-NNNNNNNN-N (guiones opcionales); sólo se usa si el perfil fiscal no lo tiene.';
COMMENT ON COLUMN public.account_branding.address IS
  'documentos-marca-empresa (D4): domicilio; sólo se usa si el perfil fiscal no tiene domicilio comercial.';
COMMENT ON COLUMN public.account_branding.email IS
  'documentos-marca-empresa (D4): email DEL NEGOCIO para los papeles. El email de acceso de un usuario NO se imprime nunca.';
COMMENT ON COLUMN public.account_branding.palette_preset IS
  'documentos-marca-empresa (D3): neutro (por defecto, "blanco") | azul | verde | grafito | bordo | personalizado.';
COMMENT ON COLUMN public.account_branding.accent_color IS
  'documentos-marca-empresa (D3): #rrggbb en minúsculas; presente si y sólo si palette_preset = personalizado. '
  'El contraste (>= 4,5:1 contra blanco) lo verifica el servicio, no la base.';
COMMENT ON COLUMN public.account_branding.logo_image IS
  'documentos-marca-empresa (D2): imagen NORMALIZADA por el backend (PNG con transparencia o JPEG, lado mayor <= 1000 px, '
  'sin metadatos, <= 300 KB). Nunca viaja en rpc_commercial_issuer.';
COMMENT ON COLUMN public.account_branding.logo_sha256 IS
  'documentos-marca-empresa (D2): huella SHA-256 (hex) de logo_image; clave de caché del render y ETag de la API.';
COMMENT ON COLUMN public.account_branding.updated_by IS
  'documentos-marca-empresa (D1): usuario que guardó la marca por última vez (sin FK dura).';

ALTER TABLE public.account_branding ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "account_branding_member_select" ON public.account_branding;
CREATE POLICY "account_branding_member_select" ON public.account_branding
    FOR SELECT
    TO authenticated
    USING (account_id IN (SELECT current_account_ids()));

DROP POLICY IF EXISTS "account_branding_writer_insert" ON public.account_branding;
CREATE POLICY "account_branding_writer_insert" ON public.account_branding
    FOR INSERT
    TO authenticated
    WITH CHECK (is_account_writer(account_id));

DROP POLICY IF EXISTS "account_branding_writer_update" ON public.account_branding;
CREATE POLICY "account_branding_writer_update" ON public.account_branding
    FOR UPDATE
    TO authenticated
    USING     (is_account_writer(account_id))
    WITH CHECK (is_account_writer(account_id));

-- Privilegios de tabla. Los defaults del esquema public dan ALL a anon,
-- authenticated y service_role: anon pierde todo; authenticated conserva
-- SELECT/INSERT/UPDATE y pierde DELETE/TRUNCATE/REFERENCES/TRIGGER ("sin DELETE"
-- queda cerrado en la capa de privilegio, no sólo por la ausencia de política).
-- El backend no borra filas: retirar el logo es un UPDATE.
REVOKE ALL ON public.account_branding FROM anon;
REVOKE DELETE, TRUNCATE, REFERENCES, TRIGGER ON public.account_branding FROM authenticated;

-- Guard owner/admin (cuerpo espejo de scale_settings_guard_owner_admin,
-- 20261066000001:220-263): toda escritura exige que el actor sea owner o admin
-- de la cuenta. Además, una fila no se muda de cuenta.
CREATE OR REPLACE FUNCTION public.account_branding_guard_owner_admin()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
BEGIN
  IF TG_OP = 'UPDATE' AND NEW.account_id IS DISTINCT FROM OLD.account_id THEN
    RAISE EXCEPTION 'unauthorized: account_branding.account_id is immutable'
      USING ERRCODE = 'P0401';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM   public.account_members am
    JOIN   LATERAL unnest(public.member_active_roles(am.id)) AS r(code) ON true
    WHERE  am.account_id = NEW.account_id
      AND  am.user_id    = (SELECT auth.uid())
      AND  r.code IN ('owner', 'admin')
  ) THEN
    RAISE EXCEPTION 'unauthorized: only owner or admin can change account_branding'
      USING ERRCODE = 'P0401';
  END IF;
  RETURN NEW;
END;
$function$;

COMMENT ON FUNCTION public.account_branding_guard_owner_admin() IS
  'documentos-marca-empresa (D1): la RLS de account_branding habilita INSERT/UPDATE a los roles is_writer=true '
  '(is_account_writer); este disparador restringe la escritura a owner/admin (P0401), la misma regla que el '
  'backend aplica con CAN_CONFIGURE. Sólo lo invoca el trigger: sin EXECUTE para PUBLIC/anon/authenticated.';

-- SECURITY DEFINER (lee account_members/member_active_roles sin depender de la
-- RLS del actor) pero NUNCA una RPC de usuario: sin este REVOKE,
-- test_function_acl_gate.sql (1) la marca como función trigger SECURITY DEFINER
-- ejecutable por anon/authenticated.
REVOKE ALL ON FUNCTION public.account_branding_guard_owner_admin() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS trg_account_branding_guard_owner_admin ON public.account_branding;
CREATE TRIGGER trg_account_branding_guard_owner_admin
  BEFORE INSERT OR UPDATE ON public.account_branding
  FOR EACH ROW
  EXECUTE FUNCTION public.account_branding_guard_owner_admin();

-- ── 2. rpc_commercial_issuer (D4) ────────────────────────────────────────────
-- Desde el cuerpo VIVO de prod (pg_get_functiondef, md5 sin CR
-- 3abc66aee3eb3c2b19d5f8a3305941d9, idéntico a 20261067000001:939-980). El diff
-- son SÓLO las líneas marcadas "documentos-marca-empresa": el LEFT JOIN a
-- account_branding y las 12 claves nuevas. Misma firma (CREATE OR REPLACE: sin
-- overload posible y sin reseteo de la ACL).
CREATE OR REPLACE FUNCTION public.rpc_commercial_issuer(p_account_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_result jsonb;
BEGIN
  IF p_account_id IS NULL OR NOT EXISTS (
    SELECT 1 FROM public.current_account_ids() AS cai WHERE cai = p_account_id
  ) THEN
    RAISE EXCEPTION 'account_not_found: %', p_account_id USING ERRCODE = 'P0404';
  END IF;

  SELECT jsonb_build_object(
           'nombre_fantasia',     fp.nombre_fantasia,
           'razon_social',        fp.razon_social,
           'cuit',                fp.cuit,
           'domicilio_comercial', fp.domicilio_comercial,
           'business_name',       pr.business_name,
           'phone',               pr.phone,
           -- documentos-marca-empresa: claves nuevas, planas y aditivas (un backend viejo sigue leyendo las 6 de arriba).
           'iva_condition',       fp.iva_condition,
           'brand_display_name',  ab.display_name,
           'brand_legal_name',    ab.legal_name,
           'brand_tax_id',        ab.tax_id,
           'brand_address',       ab.address,
           'brand_phone',         ab.phone,
           'brand_email',         ab.email,
           'brand_website',       ab.website,
           'brand_footer_note',   ab.footer_note,
           'palette_preset',      ab.palette_preset,
           'accent_color',        ab.accent_color,
           'logo_sha256',         ab.logo_sha256)
  INTO   v_result
  FROM   public.accounts a
  LEFT JOIN public.fiscal_profiles fp ON fp.account_id = a.id
  LEFT JOIN public.profiles pr        ON pr.id = a.owner_user_id
  LEFT JOIN public.account_branding ab ON ab.account_id = a.id  -- documentos-marca-empresa
  WHERE  a.id = p_account_id;

  IF v_result IS NULL THEN
    RAISE EXCEPTION 'account_not_found: %', p_account_id USING ERRCODE = 'P0404';
  END IF;
  RETURN v_result;
END;
$function$;

REVOKE ALL ON FUNCTION public.rpc_commercial_issuer(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_commercial_issuer(uuid) TO authenticated;
COMMENT ON FUNCTION public.rpc_commercial_issuer(uuid) IS
  'commercial-document-pdf (D8) + document-branding (D4): datos del emisor y de la marca de la cuenta para los '
  'papeles — 18 claves: nombre_fantasia, razon_social, cuit, domicilio_comercial, iva_condition (fiscal_profiles); '
  'business_name, phone (profiles del dueño); brand_display_name, brand_legal_name, brand_tax_id, brand_address, '
  'brand_phone, brand_email, brand_website, brand_footer_note, palette_preset, accent_color y logo_sha256 '
  '(account_branding; NUNCA la imagen). Miembro de la cuenta o P0404 account_not_found. SECURITY DEFINER porque '
  'la RLS de profiles sólo deja ver el perfil propio. Sin ningún email de acceso (no lee auth.users).';

-- ── 3. Introspección: la migración se verifica a sí misma ───────────────────
DO $$
DECLARE
  v_count integer;
  v_acl   text;
  v_oid   oid;
BEGIN
  SELECT count(*) INTO v_count
  FROM   pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE  n.nspname = 'public' AND p.proname = 'rpc_commercial_issuer';
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'documentos-marca-empresa: rpc_commercial_issuer debe tener UNA sola definición, hay %', v_count;
  END IF;

  v_oid := to_regprocedure('public.rpc_commercial_issuer(uuid)');
  IF NOT (SELECT prosecdef FROM pg_proc WHERE oid = v_oid)
     OR (SELECT provolatile FROM pg_proc WHERE oid = v_oid) <> 's' THEN
    RAISE EXCEPTION 'documentos-marca-empresa: rpc_commercial_issuer debe seguir siendo SECURITY DEFINER y STABLE';
  END IF;

  SELECT string_agg(a, ',' ORDER BY a) INTO v_acl
  FROM   (SELECT unnest(proacl)::text AS a FROM pg_proc WHERE oid = v_oid) s;
  IF v_acl IS DISTINCT FROM 'authenticated=X/postgres,postgres=X/postgres,service_role=X/postgres' THEN
    RAISE EXCEPTION 'documentos-marca-empresa: ACL de rpc_commercial_issuer inesperada: %', COALESCE(v_acl, '<NULL>');
  END IF;

  SELECT count(*) INTO v_count FROM pg_policies WHERE schemaname = 'public' AND tablename = 'account_branding';
  IF v_count <> 3 THEN
    RAISE EXCEPTION 'documentos-marca-empresa: account_branding debe tener 3 políticas, tiene %', v_count;
  END IF;
  IF has_table_privilege('anon', 'public.account_branding', 'SELECT')
     OR has_table_privilege('authenticated', 'public.account_branding', 'DELETE')
     OR has_table_privilege('authenticated', 'public.account_branding', 'TRUNCATE') THEN
    RAISE EXCEPTION 'documentos-marca-empresa: privilegios de tabla inesperados sobre account_branding';
  END IF;
  IF has_function_privilege('authenticated', 'public.account_branding_guard_owner_admin()', 'EXECUTE')
     OR has_function_privilege('anon', 'public.account_branding_guard_owner_admin()', 'EXECUTE') THEN
    RAISE EXCEPTION 'documentos-marca-empresa: el guard de account_branding no debe ser ejecutable por anon/authenticated';
  END IF;

  RAISE NOTICE 'documentos-marca-empresa (introspección): account_branding con 3 políticas, privilegios y guard; rpc_commercial_issuer con una firma, DEFINER, STABLE y ACL exacta.';
END $$;
