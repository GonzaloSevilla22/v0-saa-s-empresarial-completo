## Context

`/seguros` está en producción desde 2026-03, con entrada de sidebar (`Ecosistema → Seguros`, sin gating de plan), CRUD de admin en `/admin/seguros`, servicio canónico en `frontend/lib/services/insuranceService.ts`, tracking de clicks vía `public.increment_seguros_clicks(uuid)` y 7 tests en `frontend/__tests__/seguros-click-tracking.test.tsx`. **Nunca tuvo contenido**: 0 filas en `community.seguros` (verificado en prod el 2026-09-01), así que todo usuario ve el empty state.

Estado verificado de la tabla (prod, `community.seguros`):

| Columna | Tipo | Nota |
|---|---|---|
| `id` | uuid PK | default `uuid_generate_v4()` |
| `title` | text NOT NULL | |
| `description`, `coverage`, `price`, `contact_url` | text | libres, nullable |
| `is_visible` | boolean | default `true`; es el predicado de la policy de lectura |
| `created_at`, `updated_at` | timestamptz | `updated_at` por trigger `update_seguros_updated_at` |
| `clicks_count` | integer | default 0; lo incrementa el RPC |

RLS viva: `Public items are viewable by everyone` (SELECT, `USING (is_visible = true)`) y `seguros_admin_all` (ALL, admin por `profiles.role`). **Alcanzan tal cual para el perfil**: el perfil es exactamente "una fila visible leída por cualquiera", que es lo que la policy ya permite. No hace falta tocar RLS.

**Material fuente** (`docs/Julian_Dupas_PAS_v5_260814_174911.pdf`, 1 página institucional, texto extraído y leído): 3 líneas de servicio numeradas (01 Autos y motos / 02 Hogar y comercio / 03 Empresas, flotas y ART), cada una con su bajada; frase ancla *"Un seguro no termina cuando se emite la póliza."* con párrafo de apertura; 4 pilares desarrollados (comparación de alternativas, transparencia y asesoramiento, acompañamiento durante el siniestro, cobertura actualizada); contacto tel. 2266 474348 y mail julian_dupas@argbroker.com.ar; 14 ciudades de alcance (Necochea, Mar del Plata, Rosario, Concordia, C.A.B.A, General Pico, Trenque Lauquen, Pergamino, Pilar, Río Cuarto, **Mendoza**, Tandil, La Plata, Balcarce).

**Dos correcciones al brief de esta tarea, encontradas al leer las fuentes en vez de asumirlas:**

1. **La matrícula SÍ está en el material.** El brief afirmaba que no estaba y pedía no inventarla. El PDF la declara **dos veces**: `PRODUCTOR ASESOR DE SEGUROS — MATRÍCULA N.º 98506` y `www.argbroker.com.ar · Mat. N.º 98506`. No hay que pedirle el número al partner: hay que **confirmarlo y decidir la leyenda** (ver OQ-3). El mismo hallazgo aporta una **web que el brief daba por inexistente** (`www.argbroker.com.ar`), que es justamente lo que hoy le falta a `contact_url`.
2. **La numeración de migración del brief estaba vieja.** Decía que la última en `main` era `20261014000001`; `origin/main` tiene dos más (`20261015000001_gastos_forma_pago`, `20261016000001_qa_integral_fixes`) y prod confirma `MAX(version) = 20261016000001`. La correlativa correcta es **`20261017000001`**.

## Goals / Non-Goals

**Goals:**
- Publicar el material del partner **completo y estructurado**, no aplastado en 4 campos de texto.
- Que `/seguros` se vea bien **con un solo asesor** y siga funcionando con varios, sin otra migración.
- Que **todo** lo nuevo sea editable desde `/admin/seguros` — contenido que nadie puede cargar es contenido que no existe.
- Saber **por qué vía** contactan al asesor, sin romper el contador de clicks actual ni su test.
- Identificar al PAS con su matrícula y dejar claro el rol de Aliadata.

**Non-Goals:**
- Cotizar, contratar, cobrar o intermediar. Aliadata publica un contacto; la relación es directa entre el usuario y el asesor.
- Landing pública. El perfil vive dentro de la app autenticada (OQ-5).
- Serie temporal de clicks por evento. El agregado por vía alcanza para la decisión de hoy (ver D6).
- Formulario de lead / captura de datos del usuario dentro de la app. Sumaría tratamiento de datos personales de terceros y sube la governance sin necesidad.
- Multi-tenancy. `community.seguros` es catálogo global sin `account_id`, y así se queda.

## Decisions

### D1 — Extender `community.seguros`, no crear una tabla nueva de asesores

**Alternativa considerada:** tabla nueva `community.insurance_advisors` con su propio servicio, sus policies, su CRUD y su ruta de admin, dejando `seguros` como catálogo de ofertas.

**Elegido: extender.** Razones, en orden de peso:
1. **Regla de reutilización antes que repetición.** Una tabla nueva obliga a duplicar el servicio canónico, las 2 policies, el CRUD de admin, las métricas y el tracking. Es exactamente el patrón que en este proyecto ya produjo bugs silenciosos (3 Edge Functions calculando su propio "plan efectivo"; criticidad de stock rehecha en 5 lugares).
2. **La tabla está vacía.** No hay filas de "oferta" que queden cargando columnas que no les sirven. El costo clásico de extender —nullables sin sentido para las filas viejas— es cero acá porque no hay filas viejas.
3. **El destino real de la tabla son asesores.** El acuerdo comercial es con una persona, no con una aseguradora que publique productos.

**Lo que compramos con esto:** una tabla con dos formas posibles. Se paga con D2.

### D2 — Discriminador explícito `entry_type`, no inferido

Con dos formas conviviendo, hace falta saber cuál es cuál. Se podría **inferir** ("si tiene `slug` y `advisor_name`, es un asesor"), pero un discriminador implícito se rompe callado en cuanto alguien guarda una fila a medias desde el admin.

**Elegido:** `entry_type text NOT NULL DEFAULT 'offer' CHECK (entry_type IN ('offer','advisor'))`. Conjunto cerrado por CHECK, que es el idioma del proyecto (`payment_methods.kind`, `sales_orders.payment_method`). El default `'offer'` hace la migración compatible hacia atrás por construcción.

La integridad de "un asesor necesita slug" se expresa como **CHECK condicional** en la misma tabla: `CHECK (entry_type <> 'advisor' OR slug IS NOT NULL)`. Es una invariante de datos, no una regla de UI: si vive sólo en el formulario, se evade por API.

### D3 — jsonb para las listas ordenadas, escalares para todo lo que el sistema lee

Ésta es la decisión que el brief pedía justificar.

**Alternativa A — tablas hijas** (`community.insurance_advisor_services`, `..._pillars`): 2 tablas más, 4 policies más, 2 CRUDs anidados más en el admin, y `ORDER BY sort_order` en cada lectura.
**Alternativa B — todo en un `advisor_profile jsonb`**: 1 columna, cero churn futuro, pero el `slug` (clave de ruta, tiene que ser único e indexado) queda dentro de jsonb y hay que sostenerlo con un índice de expresión; y se pierde CHECK/NOT NULL sobre los campos que sí valen validar.

**Elegido: híbrido, con un criterio explícito** — *jsonb sólo donde la forma es un grupo ordenado que se repite y siempre se lee entero; escalar para todo lo que el sistema consulta, valida o indexa.*

- **jsonb**: `service_lines` (`[{title, description}]`) y `pillars` (`[{title, body}]`). Son contenido editorial, ordenado, que se lee siempre completo, nunca se filtra por predicado, nunca se agrega y nunca se joinea. Hay precedente en el mismo schema: `community.fair_recommendations.recommendation`.
- **`text[]`**: `coverage_areas` — lista plana de strings; el tipo nativo de Postgres es más simple que jsonb y soporta `@>` si algún día hay que filtrar por ciudad.
- **Escalares**: `slug` (clave de ruta, UNIQUE), `entry_type`, `is_featured`, `sort_order`, `advisor_name`, `advisor_role`, `license_number`, `license_authority`, `headline`, `bio`, `photo_url`, `contact_email`, `contact_phone`, `contact_whatsapp`, `contact_clicks`.

**Límite honesto de la validación en DB:** un CHECK no puede llevar subconsulta, así que no se puede validar en Postgres que *cada elemento* del array tenga sus claves. Lo que sí se hace: `CHECK (jsonb_typeof(service_lines) = 'array')` para que la columna no pueda contener un objeto o un escalar, y **validación de forma con Zod en el borde de la app** (el proyecto ya usa Zod + React Hook Form). El tipo TypeScript se define en la capa canónica, nunca `any`.

**Cuándo migraríamos a tablas hijas:** el día que haga falta consultar *"qué asesores cubren ART"* o *"qué asesores llegan a Mendoza"* de forma indexada y con varios partners. Con un partner y lectura completa, no se paga hoy.

### D4 — Slug como clave de ruta, con índice único parcial

`/seguros/[slug]` con `slug = 'julian-dupas'`. Hay precedente en el schema (`community.landing_sections.slug`).

Índice **único parcial**: `CREATE UNIQUE INDEX ... ON community.seguros (slug) WHERE slug IS NOT NULL`. Parcial porque las filas de tipo `offer` no tienen slug, y en Postgres los `NULL` no colisionan entre sí en un índice único — pero el índice parcial deja la intención escrita en vez de depender de esa sutileza.

El slug es **estable**: es una URL que el partner puede compartir. Renombrarlo rompe links. Se documenta como tal en la spec.

### D5 — El índice `/seguros` se adapta al conteo de asesores visibles

Con un asesor la grilla de 3 columnas muestra 1 card y 2 huecos, que es la mitad de por qué el PO descartó la ficha simple.

- **1 asesor visible y 0 ofertas** → la página presenta al asesor con su contenido, sin fingir catálogo. Es el estado del día 1.
- **2+ asesores** → grilla de cards, cada una linkeando a `/seguros/[slug]`.
- **Ofertas legacy (`entry_type = 'offer'`)** → siguen renderizando como hoy, con su link saliente. No se rompe nada de lo que ya existe.

El discriminante es **el conteo real de filas visibles**, no una constante. Ésta es la misma lección que dejó `planes-suscribirse-plan-vigente`: cuando el discriminante de una UI se cablea a un supuesto ("hay un solo partner") en vez de al dato, envejece mal y nadie lo nota. Con 2 asesores esto se comporta bien sin tocar código.

### D6 — Tracking por vía: función nueva, contador viejo intacto

El contrato actual es fuerte y está testeado: `incrementClicks(id)` llama `increment_seguros_clicks(row_id)`, y **ante cualquier error loguea y sigue** — el tracking jamás rompe la UX (decisión PO 2026-08-01, 7 casos en `seguros-click-tracking.test.tsx`, incluido que ante error *no* toque la tabla por un fallback no atómico).

**Elegido:** función nueva `public.increment_seguros_contact_click(row_id uuid, channel text)` que en **un solo UPDATE atómico** incrementa `clicks_count` (el total, que sigue significando lo mismo que hoy) y el contador de la vía dentro de `contact_clicks jsonb DEFAULT '{}'`. El `channel` se valida contra un conjunto cerrado dentro de la función y una vía desconocida no escribe nada raro: se ignora el desglose y se cuenta el total.

Réplica exacta del patrón de `20260831000001`: `SECURITY DEFINER` (la RLS de escritura es admin-only y el usuario común no puede hacer UPDATE), `SET search_path = ''` con referencia calificada `community.seguros`, y **`REVOKE EXECUTE ... FROM PUBLIC, anon` + `GRANT ... TO authenticated`** — el gate `supabase/tests/test_function_acl_gate.sql` corta el CI si falta.

**`increment_seguros_clicks` no se toca**, ni se deprecia, ni se cambia su firma. La página de ofertas legacy la sigue usando y sus tests siguen verdes sin editarlos. Es la red de seguridad del change: si esos 7 casos se ponen rojos, algo se rompió.

**Por qué no una tabla de eventos:** existe `public.analytics_events` (`event_name`, `event_data` jsonb, `user_id`, `account_id`, `created_at`) y es el camino canónico si algún día se quiere serie temporal o embudo por usuario. Se deja anotado como el punto de extensión, y **no se construye ahora**: con un partner, el agregado por vía responde la única pregunta de negocio real ("¿por dónde lo contactan?"). Construir las dos cosas sería doble contabilidad de lo mismo.

### D7 — Vías de contacto: deep links nativos, sin formulario propio

- **WhatsApp** → `https://wa.me/<E164 sin +>`, en pestaña nueva con `rel="noopener noreferrer"`.
- **Mail** → `mailto:`
- **Teléfono** → `tel:` — útil de verdad en mobile, que es donde más se usa la app.
- **Web** → el `contact_url` existente (`www.argbroker.com.ar`, del PDF).

**Cada vía se renderiza sólo si su dato está cargado.** Nada de botones muertos: si el partner no confirma WhatsApp, ese botón no existe y el perfil sigue completo. Esto es lo que permite publicar sin esperar las respuestas de las OQs.

El número se guarda **normalizado en E.164 sin `+`** (`contact_whatsapp`), separado del `contact_phone` legible para mostrar. Guardar un solo campo y formatear en el cliente es la receta para que un espacio o un `15` rompan el link en silencio.

### D8 — Foto opcional con degradación a iniciales

`photo_url` nullable. Sin foto, el avatar rinde las **iniciales** derivadas de `advisor_name` (el mockup aprobado usa "JD"), con el mismo tamaño y forma que tendría la imagen — para que la ausencia no cambie el layout. No usamos Storage ni subida de imágenes en este change: si el partner manda una foto, entra como URL desde el admin.

### D9 — Identificación regulatoria: campo del modelo, texto a firmar

Un PAS matriculado se identifica con su matrícula en la publicidad de seguros. El número **está en el material** (98506), pero **qué leyenda corresponde publicar no es una decisión técnica** y no la toma el agente: va como OQ-3 con recomendación.

El modelo lo soporta con dos campos separados: `license_number` (el número) y `license_authority` (el organismo/leyenda). Separarlos evita quedar atados a un formato de texto: si mañana la leyenda cambia, se edita un campo desde el admin, no se migra nada.

Dato relevante para la consulta: el mail y la web del partner son de **`argbroker.com.ar`**, es decir opera bajo/junto a un broker. Puede haber **dos** identificaciones en juego (la matrícula personal del PAS y la del broker). Vale preguntarlo explícitamente en vez de asumir que con una alcanza.

El disclaimer de Aliadata va en `disclaimer text` **por fila**, no como constante en el código: es texto legal-adyacente y tiene que poder corregirse sin un deploy.

### D10 — Carga del partner: seed idempotente, no backfill

La tabla está vacía: no hay nada que reparar. La fila del partner se carga con un `INSERT ... ON CONFLICT (slug) DO UPDATE` en la migración, idempotente (Supabase reaplica migraciones por auto-apply desde GitHub, gotcha ya conocido en este proyecto).

Se siembra **sólo lo que está verificado en el PDF**. Los campos que dependen de una OQ (`contact_whatsapp`, `license_authority`, `disclaimer`) se cargan vacíos y el PO los completa desde `/admin/seguros` cuando tenga las respuestas — sin migración nueva. Por eso D7 exige que cada vía degrade sola.

La fila se siembra con **`is_visible = false`**. La publicación es una decisión del PO, con un click en el toggle que ya existe en el admin — no un efecto colateral de mergear un PR. Esto también hace inocuo el deploy: si algo del contenido está mal, nadie lo vio.

### D11 — Sin gating de plan

Hoy la entrada de sidebar es `pro: false, proOnly: false` (`app-sidebar.tsx:89`) y `/seguros` no está gateada. Se mantiene: es un beneficio del ecosistema y un acuerdo comercial que **le conviene a Aliadata que se vea**, no una feature premium. Gatearlo reduciría el valor que le entregamos al partner. Ver OQ-2.

## Risks / Trade-offs

- **[Publicamos la identidad profesional y la matrícula de una persona real bajo marca Aliadata]** → El número sale del material que el propio partner entregó, no de una búsqueda nuestra. Aun así se siembra `is_visible = false` y la publicación requiere acción explícita del PO (D10), con la leyenda firmada en OQ-3.
- **[La leyenda regulatoria podría ser incorrecta o insuficiente]** → `license_authority` y `disclaimer` son campos editables desde el admin, no strings en el código: corregir es editar, no deployar. El riesgo residual se acota publicando recién con la OQ firmada.
- **[Una tabla con dos formas es más difícil de razonar que dos tablas]** → Mitigado por el discriminador explícito con CHECK (D2) y por el CHECK condicional de `slug`. Es el precio consciente de no duplicar servicio, policies y CRUD (D1).
- **[jsonb no valida la forma de cada elemento en la DB]** → Zod en el borde + `jsonb_typeof = 'array'` en la DB. Reconocido explícitamente en D3, no barrido bajo la alfombra.
- **[Romper el tracking existente]** → La función vieja no se toca y sus 7 tests corren sin editarse como red de seguridad (D6). Cualquier regresión aparece en CI antes del merge.
- **[El número de teléfono podría no tener WhatsApp]** → Si no se confirma, el botón no se renderiza (D7) y el perfil queda igual de completo con mail y teléfono. No bloquea el change.
- **[La grilla adaptativa se prueba con un solo caso real]** → El comportamiento con 2+ asesores se cubre con tests (no con datos de prod), justamente porque no hay un segundo partner para verificarlo a mano.
- **[Un slug renombrado rompe links compartidos]** → Se documenta como clave estable en la spec; el admin no ofrece renombrarlo como operación casual.

## Migration Plan

1. **Migración `20261017000001_seguros_perfil_asesor.sql`**, aditiva e idempotente:
   - `ADD COLUMN IF NOT EXISTS` para todas las columnas nuevas (todas nullable o con default).
   - CHECK de `entry_type`, CHECK condicional de `slug`, CHECK de `jsonb_typeof` en las dos columnas jsonb — todos agregados de forma guardada para poder reaplicar.
   - Índice único parcial sobre `slug`.
   - `CREATE OR REPLACE FUNCTION public.increment_seguros_contact_click(uuid, text)` + `REVOKE ... FROM PUBLIC, anon` + `GRANT ... TO authenticated`.
   - Seed del partner con `ON CONFLICT (slug) DO UPDATE`, `is_visible = false`.
   - Aplicación **por `npx supabase db push` vía CLI**, nunca por el MCP `apply_migration` (regla dura: desincroniza el historial).
2. **Frontend** en el mismo PR: servicio extendido, ruta de perfil, índice adaptativo, admin extendido.
3. **Verificación** desktop + mobile, claro + oscuro, y la suite de tracking en verde.
4. **Publicación**: el PO revisa el perfil con `is_visible = false` (visible sólo para admin) y lo activa con el toggle existente cuando el contenido esté firmado.

**Rollback:** el change es aditivo. Bajar `is_visible` a `false` despublica sin tocar código ni datos. Revertir el PR devuelve la UI anterior dejando las columnas nuevas huérfanas pero inertes (ninguna es NOT NULL sin default, ninguna afecta a las filas `offer`). No hace falta migración de reversa.

## Open Questions

Las 6 quedan con recomendación para que el PO firme. Ninguna bloquea escribir el código: el diseño degrada limpio si alguna no se responde (D7, D10).

**OQ-1 — ¿Cuál es la vía de contacto principal, y el teléfono recibe WhatsApp?**
*Recomendación:* WhatsApp primero, mail segundo, teléfono tercero, web como link secundario. El número del PDF es `2266 474348`; el código de área **2266 corresponde a Necochea (Buenos Aires)**, consistente con que Necochea encabece las 14 ciudades. En formato internacional para móvil argentino sería **`+54 9 2266 474348`** → `wa.me/5492266474348`.
*Lo que hay que confirmar:* que ese número sea un **móvil con WhatsApp** y no una línea fija. No es verificable desde el material y no se puede asumir. Si no se confirma, el botón simplemente no se muestra (D7).

**OQ-2 — ¿El módulo queda abierto a todos los planes?**
*Recomendación:* **sí, abierto**, como está hoy (D11). Es un beneficio del ecosistema y un acuerdo comercial cuya exposición nos conviene; gatearlo le quita valor al partner. Requiere no hacer nada — se documenta para que sea decisión y no inercia.

**OQ-3 — Matrícula y leyenda regulatoria.**
*Corrección al supuesto de partida:* la matrícula **no falta**. El PDF declara `Mat. N.º 98506` dos veces. Lo que falta es la **decisión editorial y regulatoria**, no el dato.
*Recomendación:* publicar `Julián Dupás — Productor Asesor de Seguros · Mat. N.º 98506` y **preguntarle a él o a su broker** dos cosas concretas: (a) si la leyenda que corresponde exige nombrar al organismo (SSN) o algún texto adicional; (b) si, operando bajo `argbroker.com.ar`, hay que identificar **también** al broker con su propia matrícula. No inventar organismo ni formato: `license_authority` queda vacío hasta que lo respondan, y el perfil no lo renderiza si está vacío.

**OQ-4 — Disclaimer de Aliadata.**
*Recomendación:* incluirlo. Texto propuesto, **a validar por el PO** (hay marca y un acuerdo comercial de por medio): *"Aliadata no es aseguradora ni intermediaria. La contratación se realiza directamente con el asesor y la compañía correspondiente."* Va en `disclaimer` por fila para poder corregirlo sin deploy (D9).

**OQ-5 — Alcance de publicación.**
*Recomendación:* **sólo dentro de la app**, para usuarios logueados. No en la landing pública, salvo indicación contraria. Es lo que el diseño asume; llevarlo a la landing sería otro change (y otra conversación sobre datos del partner expuestos sin login).

**OQ-6 — Foto o logo del asesor.**
*Recomendación:* pedírsela, pero **no bloquear**: sin foto el perfil rinde iniciales sin romper el layout (D8). Si llega, se carga como URL desde el admin, sin migración.
