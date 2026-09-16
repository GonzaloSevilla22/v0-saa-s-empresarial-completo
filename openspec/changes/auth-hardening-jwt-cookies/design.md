## Context

Este design implementa los 13 hallazgos abiertos de la **auditoría de JWT y cookies del 2026-09-12 → 2026-09-14** (árbol en `main` al `6e42be2c`). Toda cita `archivo:línea` de este documento sale de esa auditoría o de una re-verificación hecha durante el propose; las mediciones contra producción están marcadas **F1–F6** (curl anónimo sobre `www.aliadata.com.ar`, el JWKS público, el backend de Render y `pg_get_functiondef` vía MCP de sólo lectura — nunca con navegador ni credenciales).

### Estado actual, en once hechos

1. **Dónde vive la sesión.** Sólo en cookies (`sb-gxdhpxvdjjkmxhdkkwyb-auth-token` + chunks `.0`, `.1`, … + `…-auth-token-code-verifier`), nunca en localStorage. El valor es el JSON base64url de la sesión **completa** — access **y** refresh token —, trivialmente decodificable, no cifrado (`@supabase/ssr/dist/main/utils/chunker.js:8`, `:23-26`, `:63`; `createBrowserClient.js:21`; `cookies.js:156-157`).
2. **Con qué atributos.** Ninguno de los cuatro sitios que construyen cliente pasa `cookieOptions` — `frontend/lib/supabase/client.ts:4`, `frontend/lib/supabase/server.ts:6`, `frontend/lib/supabase/middleware.ts:69`, `frontend/app/auth/callback/route.ts:13` —, así que rige `DEFAULT_COOKIE_OPTIONS = { path:"/", sameSite:"lax", httpOnly:false, maxAge:400*24*60*60 }` (`@supabase/ssr/dist/main/utils/constants.js:4-11`), mergeado tanto en el camino navegador (`cookies.js:168-172`) como en el de servidor (`cookies.js:325-329`). **No hay clave `secure`**. Resultado en prod: `Path=/; SameSite=Lax; Max-Age=34560000`, sin `HttpOnly` y sin `Secure` (**F3**).
3. **Por qué hoy no puede ser httpOnly.** `createBrowserClient(url, anonKey)` sin opción `cookies` implementa el storage sobre `document.cookie` — escritura en `cookies.js:103`, lectura en `:94` —, y de ahí sale el Bearer de **todas** las llamadas a FastAPI (`frontend/lib/api/python-client.ts:17-21`). Un `httpOnly:true` en el cliente de navegador sería un no-op; en los clientes de servidor volvería la sesión ilegible para el navegador. Es estructural, no un olvido.
4. **Qué corre en cada request.** `frontend/middleware.ts:5` llama `updateSession(request)` para todo path salvo `_next/static`, `_next/image`, `favicon.ico` y extensiones de imagen (matcher en `:17`). La validación es por red y está explícitamente protegida por comentario: `getUser()` nunca `getSession()` (`frontend/lib/supabase/middleware.ts:88-89`, llamada en `:93`).
5. **Cobertura de rutas.** `PROTECTED_PREFIXES` tiene 17 entradas (`middleware.ts:57-61`) contra **29 árboles** bajo `frontend/app/(dashboard)/`. Faltan **12**: `banco`, `caja`, `cobranzas`, `estadisticas`, `exportaciones`, `facturacion`, `finanzas`, `organizacion`, `planes`, `rentabilidad`, `reportes`, `sucursales`. Medido en prod (**F1**): `GET /ventas` → 307 a `/auth/login?next=%2Fventas`; `GET /caja`, `/cobranzas`, `/banco`, `/estadisticas`, `/planes`, `/facturacion` → **200 anónimo**.
6. **El fallback de página está roto.** Cuatro Server Components chequean sesión por su cuenta y redirigen a `redirect("/login")` — `planes/page.tsx:30`, `planes/success/page.tsx:27`, `facturacion/page.tsx:78`, `ventas/ordenes/[id]/page.tsx:60` — y `/login` **no existe** (no hay `frontend/app/login` ni redirect en `frontend/next.config.mjs`, verificado: el archivo sólo declara `rewrites()` de dev, `:3-23`). Prod: `GET /planes` anónimo → 200 con `/login;307;` en el stream → 404 (**F2**).
7. **Cierre de sesión.** Tres call sites y **ninguno** es local: `frontend/contexts/auth-context.tsx:295` (`logout`), `:344` (`closeAllSessions`, `{scope:'global'}` explícito) y `frontend/lib/auth/idle-logout.ts:43`. El `signOut()` pelado **también** es global (`@supabase/auth-js@2.104.1 GoTrueClient.js:3150`: `async signOut(options = { scope: 'global' })`). El repo lo sabe en un lugar (`frontend/e2e/auth.spec.ts:41`) y lo desmiente en otro (`idle-logout.ts:25` y `:42` dicen "local scope"). Residuos divergentes: `logout()` borra sólo `tenant:active` (`auth-context.tsx:298`), `performIdleLogout` sólo `tenant:active` (`idle-logout.ts:50`), `closeAllSessions` **ninguna** (`auth-context.tsx:341-347`), y sólo `middleware.ts:148` borra `auth:last-activity` — de ahí el bounce del primer re-login post-idle.
8. **La rama idle del middleware no revoca.** Borra cookies (`middleware.ts:144-149`) pero no hay un solo `signOut` en ese archivo: la sesión sigue viva en GoTrue.
9. **Verificación en FastAPI.** Prod firma **ES256** (JWKS con una sola clave EC P-256, kid `cb5c6fc1-0196-4faa-b48c-c9190956381d`, **F4**), así que corre la rama JWKS. Esa rama valida firma y, cuando están presentes, `exp`/`nbf`/`iat`; **no** valida audiencia (`options={"verify_aud": False}` en las dos ramas, `backend/core/auth.py:83` y `:91`) ni emisor (nunca se pasa `issuer=`), `require` queda vacío (un token firmado **sin `exp`** se acepta) y `leeway` en 0. Un `sub` ausente da KeyError y sale como **500** por el catch-all (`backend/main.py:132-140`). `PyJWKClientError` hereda de `PyJWTError`, así que una caída del endpoint JWKS se reporta como "Invalid token", indistinguible de un token forjado y sin log propio (`auth.py:93-94`).
10. **La rama HS256 es alcanzable por configuración.** La elección es por prefijo de string — `if isinstance(supabase_url, str) and supabase_url.startswith("http"):` (`auth.py:76`) — sobre defaults `supabase_jwt_secret = "dev-secret"` (`backend/core/config.py:6`) y `supabase_url = ""` (`:12`). `app_env` se declara (`:7`) y **no se lee en ninguna línea de la app**. Toda la suite de backend corre por esa rama: `jwt.encode(payload, TEST_SECRET, algorithm="HS256")` (`backend/tests/conftest.py:5`, `:21`) con `mock_settings.supabase_url = ""` (`conftest.py:112-113`); grep de `jwks|ES256|RS256|get_signing_key|PyJWKClient` sobre `backend/tests/` → **0 hits**. La única rama que corre en producción no está ejercitada.
11. **CORS.** `allow_origins=[settings.backend_allowed_origin]` con `allow_credentials=True` (`backend/main.py:64-70`) sobre un default `"*"` (`config.py:10`). Starlette resuelve esa combinación **reflejando** el Origin, y `backend/core/errors.py:78-85` reproduce la reflexión a mano para los cuerpos RFC 7807. Prod (**F5**): preflight con `Origin: https://evil.example` → `access-control-allow-origin: https://evil.example` + `access-control-allow-credentials: true`.

### Tres hallazgos laterales, re-verificados durante el propose

- **`fiscal_documents` no está en la publicación de realtime.** `SELECT tablename FROM pg_publication_tables WHERE pubname='supabase_realtime'` sobre prod (2026-09-16, MCP de sólo lectura) devuelve **una sola fila: `notifications`**. La suscripción de `frontend/components/fiscal/FiscalDocumentBadge.tsx:76-96` (UPDATE sobre `fiscal_documents` mientras el estado es `pending_cae`) **nunca recibió un evento**. La auditoría lo daba como incierto (§9.4); ahora es un hecho.
- **`rpc_accept_invitation` no tiene caller.** Verificado por grep: los únicos hits fuera de `database.types.ts` son comentarios (`frontend/app/(dashboard)/organizacion/invitar/page.tsx:31-41`, `frontend/components/settings/TeamSection.tsx:13`) y mapeos de error (`backend/core/errors.py:190`). Firma única en prod: `rpc_accept_invitation(text)`, `prosecdef=true`, `proacl={postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}`, md5 del cuerpo vivo `02517dd9bcbbabd723a5bbb0f1c1a406`, 4853 chars. El hardening es **preventivo**, antes de que alguien cablee la ruta de aceptación.
- **`/ws` sigue registrado.** `app.include_router(ws.router)` en `backend/main.py:143`, y `openspec/specs/python-backend/spec.md:57` lo lista como router obligatorio.

### Restricciones

- **Governance CRÍTICO** (auth). El PO firmó el **enfoque** el 2026-09-16; cada parte necesita sign-off de merge.
- **Regla de integridad de función**: toda RPC reescrita parte de su cuerpo **vivo de prod**, nunca del último archivo de migración. *Gotcha registrado*: el md5 local difiere del de prod por los CRLF del checkout de Windows — comparar por líneas con `\r` removido.
- **Nunca commitear a `main`**; todo por PR. **Nunca** `apply_migration` del MCP para migraciones de prod (desincroniza el historial): siempre `npx supabase db push`.
- **TDD estricto** en el apply: cada task de implementación tiene su test escrito y **visto fallar** antes del código.
- **Regla del PO (2026-08-02)**: superficie frontend planificada en el propose. Acá no hay pantalla nueva — ver "Superficie frontend" en el proposal — pero sí recableado de siete pantallas existentes, con verificación desktop+móvil y claro+oscuro antes del merge de la Parte C.
- **Reutilización antes que repetición**: el bus de eventos de sesión **reutiliza** `frontend/lib/auth/idle-transport.ts` (BroadcastChannel con fallback a localStorage, `:43-49`, `:115-118`), no nace un segundo transporte cross-tab.

## Goals / Non-Goals

**Goals:**

1. Que el **refresh token deje de ser legible por JavaScript**: un XSS ya no puede exfiltrar una credencial renovable de 400 días.
2. Que **ninguna ruta del dashboard quede sin gate de sesión**, y que agregar una ruta nueva sin cobertura **rompa CI**, en vez de descubrirse en una auditoría.
3. Que la **única rama de verificación de JWT que corre en producción tenga tests**, y que valide emisor, audiencia, `exp` y `sub`.
4. Que un **origen ajeno deje de recibir `Access-Control-Allow-Origin`** del backend.
5. Que **cerrar sesión signifique lo mismo en los tres caminos** (botón, inactividad de cliente, inactividad de servidor): revocar del lado del servidor y dejar el navegador sin residuos.
6. Que la **superficie de auth se achique**: se retira el canal WebSocket que autentica pero no autoriza, y el Edge Function deja de aceptar una ruta de storage del body.
7. Que **la documentación deje de afirmar cosas falsas** sobre las variables que gobiernan la verificación del JWT.

**Non-Goals:**

- **No** se cambia el modelo de claims ni el `custom_access_token_hook` (cuerpo vivo byte-idéntico al repo, md5 `1ca8d63c42fc12a2666bb22885ebbd35` = `20261048000001:248-334`). El hook queda como está.
- **No** se implementa "hard enforcement" del idle contra la base (actividad por sesión en Postgres). Sigue siendo defensa en profundidad, como ya declara `idle-session-server-enforcement`.
- **No** se agrega rotación ni cifrado propio de cookies por encima del que ya hace GoTrue: la sesión sigue siendo la de Supabase, sólo cambia quién puede leerla.
- **No** se toca la elección de PKCE ni el flujo de links por email más allá de validar `next`.
- **No** se migran las 43 pantallas a un patrón nuevo de data fetching: el cliente de navegador sigue siendo un cliente de Supabase, sólo cambia de dónde saca el token.
- **No** se implementa BFF completo (proxy de todo el tráfico de datos por Next.js). El token handler es el punto intermedio del estándar: sesión en el servidor, access token efímero en el cliente.
- **No** se corrige la duplicación del criterio de "cuenta activa" replicado en tres lenguajes (`20261048000001:273-277`, `backend/core/deps.py:27-30`, `frontend/contexts/auth-context.tsx:101-103`). Es deuda real, ajena a este change.

## Decisions

### D1 — La sesión vive sólo en cookies httpOnly escritas por el servidor, y el navegador recibe un access token efímero en memoria (patrón *token handler*)

**Qué.** Las cookies `sb-*` pasan a `HttpOnly`, `Secure` en producción, `SameSite=Lax`, `Path=/`, escritas **únicamente** por `createServerClient` con `cookieOptions` (soportado: `@supabase/ssr/dist/main/createServerClient.js:27-28`, `:59`) desde middleware, Route Handlers y Server Actions. Un único `frontend/lib/supabase/cookie-options.ts` es la fuente de esas opciones, consumido por los tres caminos de servidor.

Todas las operaciones de `supabase.auth.*` que hoy corren en el navegador se mueven al servidor: `signInWithPassword` (+`captchaToken`), `signUp`, `signInWithOtp`, `resetPasswordForEmail`, `resend`, `updateUser`, `exchangeCodeForSession` y `signOut`. Son las 9 llamadas de `frontend/contexts/auth-context.tsx` (`:74`, `:202`, `:231`, `:243`, `:271`, `:295`, `:327`, `:333`, `:344`) más las de las pantallas de auth.

El cliente de navegador pasa de `createBrowserClient` a:

```
createClient(url, anonKey, { accessToken: async () => getAccessToken() })
```

Soportado por `@supabase/supabase-js` **2.104.1** ya instalado: el callback alimenta REST, Storage y Functions (`node_modules/.pnpm/@supabase+supabase-js@2.104.1/.../dist/index.mjs:135-138`, `:527`) y Realtime lo recibe como `{ accessToken: this._getAccessToken.bind(this) }` (`:395`) más un `setAuth` de inicialización (`:398`); `realtime-js` 2.104.1 lo soporta en `RealtimeClient` (`dist/main/RealtimeClient.js:119-120`, `:166`, `:333-344`).

`getAccessToken()` mantiene el access token **en memoria del módulo** y lo obtiene de un Route Handler (`GET /api/auth/token`) que lee la cookie httpOnly con el cliente de servidor, refresca si hace falta —reescribiendo las cookies rotadas en la respuesta— y devuelve `{ access_token, expires_at, user }`. **Nunca** devuelve el refresh token. La renovación se agenda antes del vencimiento, en `visibilitychange`, y ante un 401 de cualquier consumidor.

**Por qué el `onAuthStateChange` desaparece.** Con `accessToken` configurado, cualquier acceso a `supabase.auth.*` **lanza** (`index.mjs:389`) y `_listenForAuthEvents` no se instala (`:407`). Las dos suscripciones actuales (`auth-context.tsx:202` y la otra del árbol) se reemplazan por un **bus de eventos de sesión de la app** montado sobre `frontend/lib/auth/idle-transport.ts` — el transporte cross-tab que ya existe y ya tiene tests (`frontend/__tests__/idle-transport.test.ts`).

**Compatibilidad con las sesiones vivas.** Los **nombres y el contenido** de las cookies no cambian. Una sesión abierta hoy sigue siendo válida: el servidor simplemente la reescribe con `HttpOnly` en el primer refresh. **Cero re-login forzado** — requisito duro, con 38 cuentas reales en producción.

**Alternativas rechazadas.**

- *Pasar `cookieOptions:{ httpOnly:true }` a los clientes existentes.* No funciona: en el cliente de navegador es un no-op (`cookies.js:103` escribe `document.cookie`, que no puede emitir `HttpOnly`) y en el de servidor volvería la sesión ilegible justo para el código que hoy la lee. El hallazgo F3 de la auditoría lo dice explícito.
- *BFF completo: proxyear todo el tráfico de datos por Route Handlers de Next.js.* Cierra el mismo vector y algunos más, pero reescribe los 69 archivos que importan `@/lib/supabase/client` y mete a Vercel en el hot path de PostgREST y de FastAPI. Desproporcionado; el token handler obtiene el beneficio principal (refresh token fuera del alcance de JS) con un diff acotado.
- *Sesión en memoria sin cookie (login en cada pestaña).* Rompe la recarga de página y el SSR. Inaceptable para una app de mostrador.
- *Mover la sesión a `localStorage` y firmar los requests.* Peor: `localStorage` es tan legible por XSS como `document.cookie` y encima pierde el envío automático al servidor.

### D2 — `SameSite=Lax`, no `Strict`

**Qué.** Las cookies de sesión conservan `SameSite=Lax`.

**Por qué.** Los links de email (recuperación de contraseña, magic link, confirmación de signup, cambio de email) entran por `/auth/callback` como **navegación top-level desde otro sitio**, y ese request necesita llevar la cookie PKCE `…-auth-token-code-verifier` para que `exchangeCodeForSession(code)` (`frontend/app/auth/callback/route.ts:34`) funcione. Con `Strict`, esa cookie no viaja y **todos** los flujos por email se rompen. `Lax` sí envía cookies en navegaciones top-level GET, que es exactamente el caso.

`tenant:active` conserva su `SameSite=Strict` actual (`frontend/lib/cookies.ts:40`): no participa de ningún flujo de entrada.

**Alternativa rechazada.** *`Strict` con una cookie PKCE aparte en `Lax`.* Agrega una tercera clase de cookie y una divergencia de atributos entre miembros del mismo conjunto `sb-*`, para un beneficio marginal: con `Lax` el vector CSRF que queda (GET top-level) no puede hacer mutaciones, porque toda mutación va por POST a FastAPI con Bearer, no por cookie.

### D3 — CSP con nonce por request y `'strict-dynamic'`; `'unsafe-eval'` sólo fuera de producción

**Qué.** `buildContentSecurityPolicy()` (`frontend/lib/supabase/middleware.ts:40-52`) pasa de

```
script-src 'self' 'unsafe-inline' 'unsafe-eval' https://challenges.cloudflare.com
```

(con el comentario "loosen for Next.js hydration; tighten later with nonces" desde que se escribió, `:42`) a, en producción:

```
script-src 'self' 'nonce-<base64>' 'strict-dynamic' https://challenges.cloudflare.com
```

`'unsafe-eval'` sobrevive sólo cuando `NODE_ENV !== "production"`. `style-src` conserva `'unsafe-inline'`: Tailwind y Radix inyectan estilos en runtime y `frontend/components/ui/chart.tsx:81` usa `dangerouslySetInnerHTML` para un `<style>` — es `style-src`, no `script-src`.

El nonce se genera en el middleware (`crypto.randomUUID()` base64), viaja al render por el header de request `x-nonce`, y se aplica a `next-themes` (`frontend/components/theme-provider.tsx:10` — el `ThemeProvider` acepta `nonce` y lo propaga al script inline que inyecta para evitar el flash de tema).

**Por qué importa que vaya junto a D1.** httpOnly saca el refresh token del alcance de un XSS; la CSP con nonce reduce la probabilidad del XSS. Ninguno de los dos solo es "el estándar": el par sí.

**Verificado que no hay obstáculos**: cero `<Script>`/`next/script` en el árbol; el único `dangerouslySetInnerHTML` es el `<style>` de arriba; Turnstile carga desde `https://challenges.cloudflare.com`, que queda listado como host y además lo cubre `'strict-dynamic'` si el propio Turnstile inyecta hijos.

**Alternativas rechazadas.**

- *Hashes en vez de nonce.* Habría que recalcular el hash de cada script inline de Next en cada build; frágil y silencioso al romperse.
- *Dejar `'unsafe-inline'` y confiar en httpOnly.* Deja al XSS actuando como el usuario desde la página abierta sin ninguna fricción, que es justo lo que el PO pidió acotar ("que sólo se puedan usar dentro de la página").
- *`script-src 'self'` sin nonce.* Rompe la hidratación de Next (que emite scripts inline de bootstrap) y el script de tema de `next-themes`.

### D4 — Cobertura de rutas por allow-list pública, con un test que lee el árbol del filesystem

**Qué.** `PROTECTED_PREFIXES` (17 entradas enumeradas a mano, `middleware.ts:57-61`) se invierte: se declara una **allow-list de rutas públicas** (`/`, `/auth/*`, `/legal/*`, landing, assets) y **todo lo demás bajo `app/(dashboard)` queda protegido por construcción**. Un test de vitest lee `frontend/app/(dashboard)/` del filesystem y falla si algún directorio de ruta no queda cubierto.

**Por qué por causa raíz y no enumerando los 12.** El único test que hoy fija la lista assertea **un** prefijo (`frontend/__tests__/lib/protected-prefixes-proveedores.test.ts`). Agregar los 12 que faltan resuelve el síntoma de hoy y deja el mecanismo que produjo el problema intacto: la próxima ruta nueva vuelve a nacer sin gate. El test de filesystem convierte "acordarse de agregar el prefijo" en "CI falla".

`/auth/*` queda **fuera** de la lista protegida, como hoy y por la misma razón documentada en el archivo (`middleware.ts:129-130`): gatear `/auth/callback` o `/auth/verify-email` produce un loop.

**Alternativas rechazadas.**

- *Agregar los 12 prefijos faltantes.* Cierra F1 hoy, no mañana.
- *Mover el gate al `layout.tsx` del grupo `(dashboard)` con `getUser()`.* Cubriría por construcción, pero pierde las otras tres puertas que el middleware ya aplica en el mismo lugar (email no confirmado, idle de servidor, bounce de admin) y agrega una llamada de red por render de layout.
- *Generar un manifiesto en build time.* Equivalente en efecto al test de filesystem, con un paso de build extra y un artefacto más que puede quedar desactualizado.

### D5 — Un solo `safeNext()`, consumido por el middleware y por el callback; y cookies rotadas copiadas en cada redirect

**Qué.** La validación que hoy vive sólo en el middleware — `url.pathname = next.startsWith("/") ? next : "/dashboard"` (`middleware.ts:186`) — se extrae a un helper compartido y lo consume también `frontend/app/auth/callback/route.ts`, que hoy concatena sin validar: `` `${siteUrl}${next}` `` (`:9`, `:43`). Es un open redirect latente (`@evil.example/` cambia el host); hoy ningún productor del repo alimenta `next` con input del usuario, pero el contraste entre dos caminos con criterios distintos es exactamente cómo nace el bug.

Además, las **seis salidas por redirect** del middleware construyen su propia `NextResponse` y no copian las cookies de sesión que `setAll` (`middleware.ts:77-82`) escribió sobre `supabaseResponse` (devuelto en un único punto, `:191`). Hoy es autocurativo —el redirect vuelve a entrar por el matcher dentro de la ventana de `refresh_token_reuse_interval`— pero la receta de `@supabase/ssr` es copiarlas, y con D1 (cookies escritas sólo por el servidor) dejar de copiarlas deja de ser recuperable de la misma forma.

Los cuatro `redirect("/login")` de F2 pasan a `redirect("/auth/login?next=…")`, con un test que prohíbe el literal `"/login"` en el árbol de páginas.

**Alternativa rechazada.** *Allow-list de destinos en vez de "empieza con `/`".* Más estricto, pero hay que mantener la lista al mismo ritmo que las rutas — el mismo problema que D4 resuelve. `startsWith("/")` sin `//` ni `\` es suficiente y no envejece.

### D6 — Un solo cierre de sesión: `clearAuthUxCookies()` compartido, `scope: 'local'` por default, y revocación server-side también en la rama idle

**Qué.**

- Un helper `clearAuthUxCookies()` borra `auth:last-activity` **y** `tenant:active`, y lo usan los tres caminos: `logout()` (`auth-context.tsx:295-298`), `performIdleLogout()` (`idle-logout.ts:43-50`) y `closeAllSessions()` (`auth-context.tsx:341-347`, que hoy no borra ninguna).
- El logout ordinario y el de inactividad pasan a `signOut({ scope: 'local' })`; `closeAllSessions()` conserva `'global'`.
- La rama idle del **middleware** revoca del lado del servidor (signOut local con el cliente de servidor) **antes** de borrar las cookies `sb-*` (`middleware.ts:144-149`).

**Por qué `local`.** Hoy el `signOut()` pelado es global (`GoTrueClient.js:3150`), así que cerrar sesión en el celular **desloguea la tablet del mostrador**. Para una PyME con un POS abierto todo el día eso no es un detalle de seguridad: es una interrupción de venta. El botón "cerrar todas las sesiones" existe precisamente para el otro caso y conserva su semántica.

**Por qué revocar en el middleware.** Sin eso, la rama idle del servidor borra cookies y la sesión **sigue viva en GoTrue** con su refresh token utilizable desde cualquier copia que se haya hecho. Es el caso exacto que D1 pretende hacer imposible de explotar; cerrarlo del lado del emisor es gratis.

**Efecto colateral que se cierra**: con `auth:last-activity` borrado en `performIdleLogout`, desaparece el bounce del **primer** re-login post-idle (hoy el middleware descarta las cookies `sb-*` recién emitidas porque la cookie de actividad sobrevivió con `max-age` de una semana, `frontend/lib/cookies.ts:43`).

**Alternativa rechazada.** *Dejar el `scope` global y documentarlo.* Es el statu quo, y el statu quo ya está documentado al revés en dos archivos (`idle-logout.ts:25`, `:42`). Un comportamiento que sorprende al usuario y que el propio repo describe mal no se arregla escribiéndolo mejor.

### D7 — El 401 del backend deja de recomendar "recargá la página"

**Qué.** `frontend/lib/api/python-client.ts:26-30` consulta el endpoint de token; si no hay sesión, navega a `/auth/login?reason=expired&next=…`. Si la hay (el 401 fue por otra razón), conserva el error actual. Lo mismo para el transporte duplicado `frontend/lib/api/subscriptions-client.ts:47-57` y los dos `fetch` a mano que hoy mandan `Bearer ` con token vacío en vez de omitir el header (`frontend/components/ventas/sale-receipt-button.tsx:132-140`, `frontend/app/(dashboard)/admin/pagos/page.tsx:146-152`).

**Por qué.** El comentario actual delega la renovación al middleware, y esa delegación **sólo es cierta en los 17 prefijos protegidos**: en las 12 rutas de F1 la recomendación literal del mensaje no recupera nada. D4 cierra la premisa; D7 cierra el consejo.

### D8 — La verificación del JWT exige emisor, audiencia, `exp` y `sub`, con tolerancia de reloj

**Qué.** `_decode_supabase_jwt` (`backend/core/auth.py:63-95`) pasa a:

- `issuer = f"{settings.supabase_url}/auth/v1"`,
- `audience = "authenticated"` con `verify_aud` **encendido** (hoy apagado en las dos ramas, `:83` y `:91`),
- `options={"require": ["exp", "sub"]}` — hoy `require` está vacío y un token válidamente firmado **sin `exp`** se acepta,
- `leeway = 30` segundos — hoy 0 con `verify_iat` activo, así que un reloj del host atrasado rechaza con 401 tokens recién emitidos.

`sub` ausente pasa de **500** (hoy `payload["sub"]` en `:130` da KeyError y cae en el catch-all de `backend/main.py:132-140`) a **401**. Un `PyJWKClientError` se loguea como **warning propio** antes de devolver el mismo 401 (hoy es indistinguible de un token forjado porque hereda de `PyJWTError`, `:93-94`).

**Por qué `verify_aud` puede encenderse ahora.** La spec vigente justifica el `False` diciendo que `aud: "authenticated"` es "string no-URL" y produciría falsos 401. Eso es cierto sólo si no se pasa `audience=`: PyJWT compara el claim contra el valor esperado, no exige una URL. Pasando `audience="authenticated"` la validación es correcta y el 401 falso no ocurre. El requisito "Sin verificación de audience" de `backend-auth` se reescribe en consecuencia.

**Tests de la rama que corre en prod.** Se agrega un camino de test JWKS/ES256: clave EC generada en el test, token firmado con ella, y `PyJWKClient.get_signing_key_from_jwt` parcheado para devolverla. Cierra el hueco de §10 (0 hits de `jwks|ES256|RS256|PyJWKClient` en `backend/tests/`). Los tests HS256 existentes siguen corriendo bajo la palanca de D9.

### D9 — HS256 sólo bajo palanca explícita, y fail-fast de configuración en el arranque

**Qué.** Se agrega `auth_allow_hs256_fallback: bool = False` a `Settings`. La rama HS256 (`auth.py:85-92`) se ejecuta **sólo** si esa palanca está en `True`. Si está en `False` y `supabase_url` no empieza con `https://`, la app **no arranca**: el `model_validator` de `Settings` (hoy `config.py:130-143`, que sólo valida las palancas de tenancy) lo rechaza.

El fixture de tests activa la palanca explícitamente, de modo que los 17 bloques de patch de `backend/tests/test_auth.py` y el `conftest.py` sigan funcionando sin reescribirse.

**Por qué fail-fast en el arranque y no en el primer request.** Con el comportamiento actual, un `SUPABASE_URL` mal puesto en Render produce un **apagón funcional silencioso**: la rama HS256 con secreto `"dev-secret"` da 401 al 100% del tráfico legítimo (visible, no un downgrade sigiloso) pero acepta cualquier token forjado con ese secreto público — y el `sub` forjado es `auth.uid()` aguas abajo (`backend/core/database.py:116`), es decir impersonación completa. Que el proceso no levante convierte un incidente de seguridad latente en un despliegue que falla ruidosamente.

**Por qué no usar `app_env`.** Se declara y **no se lee en ninguna línea de la app** (`config.py:7`). Un flag que nadie lee no es un gate; se prefiere una palanca con nombre propio, leída en el único lugar que decide, más el `app_env` como condición adicional para prohibir `"*"` en CORS (D10).

**Alternativa rechazada.** *Eliminar HS256 por completo.* Rompe la suite entera del backend (que corre por esa rama, `conftest.py:5`, `:21`, `:112-113`) y el desarrollo local sin JWKS. La palanca conserva el camino de dev haciendo explícito que no es el de producción.

### D10 — CORS por expresión regular, sin credenciales, con `"*"` prohibido en producción

**Qué.** `backend/main.py:64-70` pasa a `allow_origin_regex` con dos patrones — `^https://(www\.)?aliadata\.com\.ar$` y `^https://v0-saa-s-empresarial-completo-eie(-[a-z0-9-]+)?\.vercel\.app$` — más `http://localhost:3000` fuera de producción, y **`allow_credentials=False`**. `backend/core/errors.py:78-85` (la reflexión manual para los cuerpos RFC 7807) usa el mismo criterio. Con `app_env == "production"`, `backend_allowed_origin == "*"` es error de arranque.

Los defaults son seguros **por sí solos**: prod sigue funcionando aunque `BACKEND_ALLOWED_ORIGIN` no se configure nunca en Render, que es el estado real de hoy (**F5** lo prueba indirectamente).

**Por qué `allow_credentials=False`.** No hay ninguna credencial ambiental que un origen ajeno pueda reutilizar: cero lecturas de cookie en `backend/` (fuera de `.venv`), todo es `Authorization: Bearer`, y ningún caller del frontend manda `credentials:'include'` — `python-client.ts` no pasa `credentials`, así que rige el default `same-origin` de fetch y, siendo el backend otro origen, no viaja ninguna cookie. Quitar `allow_credentials` es lo que permite que Starlette deje de reflejar.

**Alternativa rechazada.** *Poner `BACKEND_ALLOWED_ORIGIN` en Render y no tocar código.* Arregla prod y deja el default `"*"` + `allow_credentials=True` esperando al próximo entorno mal configurado; y no arregla los previews de Vercel, que tienen host variable.

### D11 — Se retira `/ws/{room_id}`, en vez de endurecerlo

**Qué.** Se eliminan `backend/routers/ws.py`, `backend/core/ws_manager.py`, `backend/tests/test_ws.py` y el `app.include_router(ws.router)` de `backend/main.py:143`. La capability `realtime-websocket` pierde sus requisitos de comportamiento y pasa a declarar el invariante negativo, con el mismo molde que ya usa este repo para `organizations` (`openspec/specs/python-backend/spec.md`, requisito "El dominio organizations no existe en el backend").

**Por qué retirar.** El endpoint autentica el handshake pero **no autoriza la sala**: descarta la identidad validada (`ws.py:49`) y nunca compara `room_id` contra la cuenta del portador (`:54`, `:60`). Recibe el JWT por **query string** (`:41`), que queda escrito en los logs de Render (retención 7 días), y valida **una sola vez** para toda la vida de la conexión. Y no tiene productor ni consumidor: cero `new WebSocket`/`ws://`/`wss://` en el fuente del frontend; el único caller de `broadcast` es el eco del propio cliente. DEC-16 lo declara fuera de producción (`knowledge-base/09_decisiones_y_supuestos.md:90`) y `openspec/specs/in-app-notifications/spec.md:86` prohíbe usarlo.

Endurecerlo es escribir autorización de sala, rotación de token y límites de conexión para un canal que **nadie usa y que una decisión vigente prohíbe usar**. Borrarlo es más barato y elimina la superficie entera, incluido el segundo decoder de JWT (`ws.py:12-34`) que hoy diverge del canónico (sin rama HS256, sin `iss`, sin `aud`) y que nadie ejercita (`test_ws.py` sólo prueba `ConnectionManager` con `AsyncMock`).

**Alternativa rechazada.** *Dejarlo registrado y sólo documentar.* Es el estado actual, y la auditoría lo califica de "cerrarlo **antes** de que alguien cablee el primer productor". Un endpoint sin autorización de sala en el `openapi.json` es una invitación.

### D12 — Para acciones de configuración, la base es la autoridad; el claim es un caché

**Qué.** `require_account_role` (`backend/core/guards.py:49-75`) conserva sus tres pasos actuales, con una excepción: cuando el conjunto permitido es un **conjunto de configuración** (`owner`/`admin`, declarado en `backend/core/rbac.py:26` como `CAN_CONFIGURE`), se consulta `rpc_my_active_account_roles()` **aunque el claim `account_roles` esté presente**, y la decisión se toma con lo que devuelve la base.

**Por qué sólo para configuración.** Hoy el claim presente gana sobre la base (`guards.py:63-71`), así que un rol **revocado o vencido** sigue autorizando hasta la próxima emisión de token. El riesgo está aceptado con sign-off del PO para el caso general (`openspec/changes/archive/2026-09-12-v3-rbac-multirole/design.md:70`, `:132-136`) y la ventana está acotada a una vida de token. Pero las acciones de configuración son pocas, poco frecuentes y las de mayor daño: pagar una query por request ahí es barato; pagarla en cada lectura del POS no lo es.

**Alternativa rechazada.** *Consultar siempre la base.* Anula el propósito del claim (evitar una query por request en el hot path) para cerrar una ventana que el PO ya aceptó para el resto de las superficies. Queda como **OQ-4**.

### D13 — `invoice-ocr` lee `storage_path` de la fila validada, no del body

**Qué.** El `SELECT` de `invoice_documents` (`supabase/functions/invoice-ocr/index.ts:112-115`) suma `storage_path` a las columnas que trae, y la descarga con el cliente de service role (`:132-135`) usa **ese** valor. El `storage_path` del body se sigue aceptando por compatibilidad (`:104-107`) pero **nunca** se usa.

**Por qué.** Hoy se autoriza `document_id` contra `user_id` y después se descarga **otro objeto** con SERVICE_ROLE — confused deputy de manual. La política que anularía el chequeo existe (`supabase/migrations/20260510215934_invoice_ocr_system.sql:57-61`). Hoy lo compensan un path con UUID de 122 bits (`frontend/lib/services/invoiceOcrService.ts:81-82`) y que ninguna superficie publique paths del bucket `invoices`, pero son controles de oscuridad, no de autorización.

**Por qué seguir aceptando el campo.** No romper el caller existente en el mismo PR que endurece el servidor. La regla del repo aprendida en `feedback_contract_hardening_callers` es migrar todos los callers al endurecer un contrato; acá el caller es uno (`invoiceOcrService.ts:117-119`) y seguirá mandando el campo sin efecto.

### D14 — Una sola migración `20261051000001`: binding de email, lock de la invitación, y publicación de `fiscal_documents`

**Qué.**

1. `rpc_accept_invitation(text)` reescrita **desde su cuerpo vivo de prod** (md5 `02517dd9bcbbabd723a5bbb0f1c1a406`, 4853 chars, `prosecdef=true`, firma única — verificado el 2026-09-16), agregando:
   - **binding de email**: si `account_invitations.email` no es nulo, se exige `lower(email) = lower(auth.jwt()->>'email')`; si no coincide, se rechaza con el `{error}` del contrato existente y el ERRCODE de la familia 403 que ya usa el codebase (`P0403`, mapeado en `backend/core/errors.py`). Hoy la RPC valida **sólo** token + `status='pending'` + `expires_at > now()` (`20261050000001:338-344`) e inserta la membresía para `auth.uid()` (`:401-404`) sin comparar nunca la columna `email`.
   - **`SELECT … FOR UPDATE`** sobre la fila de la invitación antes de validar: hoy el `status='accepted'` es la última sentencia, sin lock (`:417`), así que dos aceptaciones concurrentes del mismo token compiten.
   - `DROP FUNCTION` + `CREATE` (nunca `CREATE OR REPLACE` con firma cambiada — gotcha `42725` ya registrado) y **re-emisión de las ACLs** tras el `DROP` (el `proacl` vivo es `{postgres,authenticated,service_role}`; un `DROP`/`CREATE` las resetea y Supabase otorga `EXECUTE` a `anon` por default en función nueva, así que hay que **revocar `anon` explícitamente**).
2. `ALTER PUBLICATION supabase_realtime ADD TABLE public.fiscal_documents`, **guardado idempotentemente** contra `pg_publication_tables` (verificado en prod: la publicación contiene sólo `notifications`). `fiscal_documents` ya tiene RLS por `account_id` (`openspec/specs/afip-fiscal-document/spec.md`, requisito de persistencia), que es lo que hace segura la publicación — el filtro del canal es optimización de red, no el límite.
3. **Gate de integridad de función** siguiendo el patrón que ya usa el repo: `pg_get_functiondef('public.rpc_accept_invitation(text)'::regprocedure)` con asserts sobre el texto vivo (molde de `supabase/tests/test_operacion_party_guard.sql:521-561`), más bloques de comportamiento (invitación con email ajeno rechazada, invitación sin email aceptada, cero overloads, ACLs exactas). Cableado a `.github/workflows/KPI_Validation.yml` junto a los 77 gates ya existentes, y la migración sumada a la cadena de reaplicación idempotente.

**Una sola migración y no tres.** Las dos piezas son independientes entre sí pero ambas son de la Parte A y ninguna tiene backfill. Partirlas multiplica el riesgo de renumerado (ya ocurrió tres veces en `cuenta-corriente-party-guard`) sin ganar nada.

**Sin backfill de invitaciones.** Verificado: `rpc_accept_invitation` no tiene caller en la app, así que no hay membresías históricas creadas por ese camino que auditar.

### D15 — La documentación deja de afirmar lo contrario del código

**Qué.**

- `openspec/specs/backend-auth/spec.md:11` — la línea normativa dice "SHALL … `HS256`". Pasa a declarar JWKS ES256/RS256 como el camino normativo y HS256 como fallback **bajo palanca explícita** (D9).
- `knowledge-base/08_arquitectura_propuesta.md:238`/`:310` — documentan HS256 sin mencionar `SUPABASE_URL`, que es la variable que **elige la rama**. Y `:132` dice que el service role es "solo Edge Functions", cuando `backend/services/payments.py:117-126` lo usa.
- `backend/core/config.py:11-12` — `supabase_url` vive bajo el header de *pagos*; pasa a estar documentada como variable de **auth**.
- `CLAUDE.md` + `AGENTS.md` — la nota de divergencia `python-jose` vs `PyJWT` ya no aplica (ambos manifiestos declaran sólo `PyJWT[crypto]`: `backend/requirements.txt:3`, `backend/pyproject.toml:8`), y la mención de `ws.py`/`ws_manager` en la superficie del backend desaparece con D11. Se corre `python scripts/ci/check_docs_sync.py --fix` **en el mismo PR** (el gate `Docs Sync` lo verifica).
- `supabase/config.toml:396`/`:407`/`:418`/`:429`/`:449` — cinco `verify_jwt = true` que el deploy contradice en cada push con `--no-verify-jwt` a toda la flota (`.github/workflows/deploy.yml:63`; medición del proyecto vivo: 12/12 funciones con `verify_jwt:false`). Pasan a `false` con un comentario que explica que cada función autentica en código, fail-closed (decisión ya registrada en `openspec/changes/archive/2026-07-31-send-email-webhook-hardening/design.md:33`, `:55`).
- Los comentarios falsos del código: `frontend/lib/cookies.ts:5` ("tokens stay in Supabase httpOnly cookies"), `frontend/lib/api/python-client.ts:14` ("reads from local storage"), `frontend/lib/auth/idle-logout.ts:25` y `:42` ("local scope"), y el docstring envejecido de `backend/core/guards.py:81` ("no existe custom access token hook" — el hook **sí** copia `profiles.role` a `app_metadata.role`, `20260827000001:151-153`).

**Por qué entra en el change y no en un "docs refresh" aparte.** Cada una de esas líneas **desvía a quien audite** justo en el punto que este change toca. Corregirlas después es garantizar que la próxima auditoría vuelva a perder tiempo en lo mismo.

### D16 — Tres partes, tres PRs, en ese orden

**Qué.** Parte A (backend + DB + Edge Function + docs) → Parte B (rutas y cierre de sesión, **sin** cambiar dónde vive la sesión) → Parte C (token handler httpOnly + CSP con nonce). Cada parte se mergea, se verifica en prod y recibe humo del PO antes de empezar la siguiente.

**Por qué ese orden.** A y B son independientes del transporte de la sesión y bajan el riesgo de C: cuando C mueve la sesión al servidor, las rutas ya están cubiertas (si algo del token handler falla, el usuario cae en `/auth/login`, no en una pantalla anónima con datos vacíos) y el backend ya rechaza lo que debe rechazar. Al revés, un token handler nuevo sobre 12 rutas sin gate es un incidente esperando el deploy.

**Por qué B no incluye httpOnly.** El atributo `Secure` es una línea en las opciones compartidas y es compatible con el modelo actual; `HttpOnly` **no lo es** (rompe el Bearer de FastAPI hasta que exista el token handler). Separarlos permite que B se mergee sin depender de C.

### D17 — Lo que no es código: cinco acciones del PO en dashboards

**Qué.** Van a `tasks.md` como grupo final "Operación (PO)", no como tasks de código: (a) `Access token expiry` a **900 s** en el Dashboard de Supabase, una vez vivo el token handler; (b) confirmar el toggle del hook de Customize Access Token; (c) `BACKEND_ALLOWED_ORIGIN`, `SUPABASE_URL` y `SUPABASE_JWT_SECRET` en Render; (d) Turnstile habilitado en el Dashboard si aún no lo está; (e) el humo real con login propio (los `Set-Cookie` de una sesión real los mide el PO, **nunca** el agente).

**Por qué.** El repo **no puede probar** ninguna de las cinco (§9 de la auditoría): `deploy.yml` nunca corre `supabase config push` (`:57`, `:60`, `:63`), así que todo el bloque `[auth]` de `config.toml` —`jwt_expiry`, rotación de refresh tokens, ventana de reuso, confirmación de email obligatoria— describe el stack **local**, no producción. Escribirlas como tasks de código sería fingir una capacidad que no existe.

## Risks / Trade-offs

| Riesgo | Mitigación |
|---|---|
| **El token handler rompe el login de todos los usuarios en el deploy de la Parte C.** Es el riesgo mayor del change: toca el camino por el que entra el 100% del tráfico. | Nombres y contenido de cookie **sin cambios** (D1) → cero re-login forzado; la Parte C se mergea sola, con humo real del PO antes y después; rollback = revertir un PR (las cookies no-httpOnly de la versión anterior siguen siendo legibles por el código viejo). Las Partes A y B ya dejaron las rutas cubiertas, así que un fallo del handler manda a `/auth/login`, no a una pantalla anónima. |
| **La CSP con nonce rompe la hidratación o el widget de Turnstile en producción y no se ve en local.** El CSP de dev es más laxo y Turnstile tiene un stub local. | Verificación obligatoria en un preview de Vercel (no sólo local) con la consola abierta, en las 7 pantallas de auth + una del dashboard con gráficos y una con 3D, antes del merge; `'strict-dynamic'` cubre los hijos que inyecte Turnstile; el host sigue listado además del nonce. |
| **`verify_aud=True` empieza a rechazar tokens legítimos** si algún emisor usa otro `aud`. | Prod emite `aud: "authenticated"` (constatado por la propia spec vigente, que lo cita como razón del `False`); el cambio se acompaña de un test con un token de `aud` distinto y otro con el correcto; la Parte A se verifica en prod con una llamada real antes de cerrar. |
| **El fail-fast de D9 tira el backend en el próximo deploy** si `SUPABASE_URL` no está puesta en Render. | Es el **objetivo**, no un efecto colateral — pero se ordena: la task de configuración del PO (D17-c) es **previa** al merge de la Parte A, y el propio arranque emite el mensaje con el nombre exacto de la variable faltante. `SUPABASE_URL` ya debe estar puesta hoy (prod corre la rama JWKS, **F4**), así que el fail-fast no debería dispararse. |
| **`scope: 'local'` deja vivas sesiones en dispositivos robados** que antes el logout ordinario cerraba. | Es la semántica correcta y la que el usuario espera; `closeAllSessions()` conserva `'global'` y es el camino explícito para ese caso. El riesgo que se cambia —desloguear el POS del mostrador— es más frecuente y más caro. |
| **El binding de email de la invitación rechaza aceptaciones legítimas** (alias, mayúsculas, `+tag`). | `lower()` en ambos lados cubre mayúsculas; el `+tag` es parte del email, no un alias — si el invitado usa otro email, la invitación se reemite. Hoy no hay ni un caller, así que no hay tráfico real que romper. Ver **OQ-6**. |
| **El test de filesystem de D4 falla por un directorio que no es una ruta** (`_components`, `(grupo)`). | El test ignora directorios que empiezan con `_` y los grupos de ruta `(…)`, y se escribe **RED primero** contra el árbol real de hoy, que ya tiene ambos casos. |
| **Con `accessToken` configurado, cualquier `supabase.auth.*` que quede en el navegador lanza en runtime** (`index.mjs:389`), y son 43 archivos. | El grep exhaustivo ya está hecho (getUser ×30, getSession ×16, signOut ×4, updateUser ×3, onAuthStateChange ×2, y 7 más ×1) y cada uno tiene destino en las tasks de la Parte C; el error es ruidoso e inmediato, no silencioso; `tsc` no lo detecta, así que la verificación es la suite de vitest + el humo manual de las 7 pantallas. |
| **Riesgo residual declarado: el XSS no desaparece.** Con httpOnly, un script inyectado sigue pudiendo pedir el access token al endpoint y actuar como el usuario **mientras la pestaña está abierta**. | Es el límite honesto del patrón token handler y se declara como tal en la spec: lo que se cierra es la **exfiltración del refresh token** (credencial renovable de 400 días, usable fuera del navegador de la víctima) y la persistencia más allá del TTL del access token. D3 (CSP con nonce) ataca la probabilidad; D1 ataca el impacto. |
| **Dos partes tocan el mismo archivo (`middleware.ts`) en PRs distintos.** | B y C se mergean en serie, nunca en paralelo; C parte de `main` con B ya mergeada (regla ya aprendida en la saga de cobranzas: commitear entre partes con capability compartida). |

## Migration Plan

**Parte A** — `npx supabase db push` lo dispara el pipeline al mergear (regla del repo: merge = build + deploy + migración automáticos). Antes del merge: checkpoint del cuerpo vivo de `rpc_accept_invitation` re-medido (el md5 de este documento es del 2026-09-16) y confirmación de que `20261051000001` sigue libre. Después del merge, verificación en prod (sólo lectura): `MAX(version) = 20261051000001`, una sola definición de `rpc_accept_invitation` sin overload, ACLs sin `EXECUTE` para `anon`, `pg_publication_tables` con `notifications` **y** `fiscal_documents`, y `GET /openapi.json` sin ninguna ruta `/ws`.

**Parte B** — sin migración. Verificación post-merge: `curl` anónimo sobre las 12 rutas de F1 → **307** a `/auth/login?next=…` (hoy 200); `curl` anónimo sobre `/planes` → 307, sin `/login` en el stream.

**Parte C** — sin migración. Verificación post-merge: el PO hace un login real y reporta los atributos de `Set-Cookie` (`HttpOnly`, `Secure`, `SameSite=Lax`, `Path=/`) — **el agente no hace login en prod** (regla: nunca el Browser pane en `/auth/login` de prod, cuelga el cliente). Y `curl -I` de una página cualquiera para leer el `Content-Security-Policy` y confirmar el nonce sin `'unsafe-inline'`.

**Rollback.** Cada parte es un PR revertible. La Parte A es la única con estado en la base: el `ALTER PUBLICATION` se revierte con `DROP TABLE` de la publicación y la RPC con el cuerpo previo (guardado en el checkpoint). Ninguna de las tres escribe datos de negocio, así que un revert no deja filas huérfanas.

**Verificación de que no hay daño histórico.** No aplica a A ni a C. Para B, se mide antes del merge cuántas sesiones tienen hoy `auth:last-activity` sin cookie `sb-*` — el estado que produce el bounce del primer re-login — para tener un antes/después.

## Open Questions

**OQ-1 — ¿Prefijo `__Host-` en las cookies de sesión?**
El prefijo `__Host-` fuerza `Secure`, `Path=/` y **prohíbe** `Domain`, cerrando el subdomain-shadowing. **Recomendación: NO ahora.** Renombrar la cookie fuerza un **logout único de todos los usuarios** en el deploy, que es exactamente lo que D1 promete evitar. Queda como follow-up barato para una ventana en que el PO acepte el re-login masivo. *(Riesgo que queda abierto: un subdominio comprometido de `aliadata.com.ar` podría sobrescribir la cookie; hoy no hay subdominios de app.)*

**OQ-2 — ¿Retirar `/ws` o endurecerlo (bindear `room_id ↔ account_id`, token por subprotocolo, rotación)?**
**Recomendación: retirar** (D11). Sin productor ni consumidor, con DEC-16 y una spec vigente prohibiéndolo, endurecerlo es escribir autorización para un canal muerto. Si el futuro lo necesita, nace con su propio change, su matriz de roles y su spec.

**OQ-3 — ¿El logout ordinario usa `scope: 'local'` o conserva `'global'`?**
**Recomendación: `local`** (D6). El comportamiento actual —global por default de la librería— desloguea el POS del mostrador cuando el dueño cierra sesión en el celular. `closeAllSessions()` conserva `'global'`. *(Contra: un teléfono robado ya no se cierra con "cerrar sesión" desde otro dispositivo; se cierra con el botón que existe para eso.)*

**OQ-4 — ¿El re-chequeo en base aplica sólo a los conjuntos de configuración o a todo guard de rol de tenant?**
**Recomendación: sólo a los conjuntos de configuración** (D12). Siempre es más seguro y más caro: una query por request en el hot path del POS para cerrar una ventana que el PO ya aceptó con sign-off (`archive/2026-09-12-v3-rbac-multirole/design.md:70`, `:132-136`). Si el PO prefiere cerrarla del todo, la alternativa estructural no es consultar siempre sino **invalidar sesiones al revocar un rol**, que es otro change.

**OQ-5 — ¿`Access token expiry` a 900 s o se deja en 3600 s?**
**Recomendación: 900 s**, una vez vivo el token handler (D17-a). Con la sesión en memoria y renovación automática, el usuario no percibe diferencia, y la ventana de un access token filtrado baja de 1 hora a 15 minutos. Antes del token handler **no** conviene: cuadruplicaría los refresh escritos sobre cookies legibles por JS. *(Nota: el valor real de hoy no lo prueba el repo — `config.toml:158` describe el stack local.)*

**OQ-6 — ¿El binding de email de la invitación es estricto o sólo deja aviso?**
**Recomendación: estricto** (D14). Hoy la RPC **no tiene ni un caller**, así que no hay tráfico real que romper y el costo de equivocarse es cero. Un binding "warn-only" es un control que no controla: la membresía se crea igual. Si el PO quiere permitir que un invitado acepte con otro email, el camino correcto es reemitir la invitación, no relajar el chequeo.

## Diagrama de secuencia — el flujo de sesión después de la Parte C

```mermaid
sequenceDiagram
    autonumber
    participant B as Navegador (JS)
    participant SA as Server Action /<br/>Route Handler (Next)
    participant MW as Middleware (Next)
    participant GT as Supabase Auth (GoTrue)
    participant PR as PostgREST / Realtime
    participant API as FastAPI (Render)

    Note over B: 1. Login
    B->>SA: POST (form action) email+password+captchaToken
    SA->>GT: signInWithPassword(...)
    GT-->>SA: access_token (ES256) + refresh_token
    SA-->>B: Set-Cookie sb-*-auth-token (+chunks)<br/>HttpOnly · Secure · SameSite=Lax · Path=/
    Note over B: el refresh token NUNCA llega a JS

    Note over B: 2. Arranque de la app
    B->>SA: GET /api/auth/token (cookies httpOnly viajan solas)
    SA->>SA: createServerClient(cookieOptions) -> getUser()
    SA-->>B: { access_token, expires_at, user }
    Note over B: token en memoria del módulo;<br/>renovación agendada antes de expires_at

    Note over B: 3. Uso normal
    B->>PR: .from(...) con accessToken() -> Bearer (en memoria)
    PR-->>B: filas (RLS por auth.uid())
    B->>API: POST /cash-movements · Authorization: Bearer (en memoria)
    API->>GT: JWKS -> clave ES256 (kid)
    API->>API: decode con iss + aud + require[exp,sub] + leeway 30s
    API-->>B: 200 (o 401 RFC 7807)
    B->>PR: realtime.setAuth(accessToken()) en cada refresh

    Note over B: 4. Renovación
    B->>SA: GET /api/auth/token (antes de expirar / visibilitychange / tras 401)
    SA->>GT: refresh con el refresh_token de la cookie
    GT-->>SA: access+refresh rotados
    SA-->>B: Set-Cookie httpOnly rotadas + { access_token, expires_at }
    B-->>B: bus de sesión (idle-transport) avisa a las otras pestañas

    Note over B: 5. Navegación con sesión vencida
    B->>MW: GET /caja
    MW->>GT: getUser() (valida por red)
    MW-->>B: 307 /auth/login?next=%2Fcaja + CSP con nonce
    Note over MW: cobertura derivada del árbol (dashboard)<br/>cookies rotadas copiadas en el redirect

    Note over B: 6. Logout
    B->>SA: POST logout action
    SA->>GT: signOut({ scope: 'local' })
    SA-->>B: Set-Cookie sb-* borradas + clearAuthUxCookies()
    B-->>B: bus de sesión: SIGNED_OUT a todas las pestañas
```
