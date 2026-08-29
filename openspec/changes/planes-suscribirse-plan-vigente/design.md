## Context

`/planes` es un Server Component (`frontend/app/(dashboard)/planes/page.tsx`) que resuelve el plan efectivo con el espejo TypeScript `getEffectivePlan` y se lo pasa como `currentPlan` a `PlanComparison` (Client Component), que a su vez renderiza cuatro `PlanCard`. La supresión del CTA vive hoy en **dos lugares que dicen lo mismo**:

- `PlanCard.tsx` L69 / L122: `const isCurrent = plan === currentPlan` → `disabled={isCurrent || loading || isFree}` y `ctaLabel = "Plan actual"`.
- `PlanComparison.tsx` L59: `if (plan === currentPlan || plan === "gratis") return`.

Ninguno de los dos pregunta si la cuenta **paga** ese tier. `currentPlan` es el plan *efectivo*, y `getEffectivePlan` lo otorga por tres vías distintas: exención de cortesía, trial vigente, o `billing_plan` pago. Las tres producen "acceso", ninguna produce "suscripción". El caso real del 2026-08-29 (`danielsevilla64`, PRO por cortesía con `plan_expires_at` futuro) cayó exactamente en el hueco: acceso sí, suscripción no, botón tampoco.

Lo que ya existe y este change **no** necesita construir:

- `POST /payments/subscriptions` admite el caso. `create_subscription_intent` (`backend/services/subscriptions.py` L85-87) rechaza con 409 **sólo** si `find_live_subscription(account_id)` devuelve fila; no compara el `plan` pedido contra el plan efectivo ni contra `accounts.billing_plan`. Verificado leyendo el servicio completo — el backend está listo, el gap es 100% frontend.
- El predicado canónico de "suscripción viva": `status IN ('pending','authorized')` (`backend/repositories/subscriptions_repository.py` L78-85).
- La lectura de esa fila desde una Server Component con RLS por membresía de cuenta: `/facturacion` ya la hace (`app/(dashboard)/facturacion/page.tsx` L138-145).
- El CTA que crea la intención y redirige al `init_point`: `createSubscription()` en `frontend/lib/api/subscriptions-client.ts` L64-85, con degradación a legacy ante 503, ya cableado en `PlanComparison.handleSelect` y cubierto por tres tests (`__tests__/PlanComparison.test.tsx`).

Restricción de contexto: `mp-real-subscriptions` es un change **activo** (55/77, en activación). Este change es una extensión de UX sobre su superficie y no lo pisa: no toca su backend, sus migraciones, su webhook ni su delta spec (que en `billing-ui` modifica sólo el requirement de `/facturacion`, no el de `/planes`).

## Goals / Non-Goals

**Goals:**

- Que una cuenta sin suscripción viva pueda contratar la suscripción recurrente de cualquier tier de pago, incluido el que ya es su plan efectivo, desde `/planes` y por el flujo normal (intención registrada → `init_point`), de modo que la reconciliación sea automática y no vuelva a producirse una fila `ambiguous`.
- Que el discriminante del CTA sea "¿hay suscripción viva?" y no "¿es este mi plan efectivo?", con un único predicado idéntico al que usa el backend para su 409.
- Que una cuenta exenta no reciba ofertas de pago.
- Que el usuario entienda **por qué** se le ofrece pagar un plan que ya está usando.

**Non-Goals:**

- Cambiar el tier de una suscripción viva (upgrade/downgrade in-place contra la API de MercadoPago). Hoy eso se hace cancelando en `/facturacion` y contratando de nuevo; unificarlo es otro change.
- Tocar `get_effective_plan` (SQL) o su precedencia.
- Corregir la divergencia del espejo TypeScript con `plan_expires_at` (ver D6 — se mide acá, se arregla en otro lado).
- Resolver la cola de ambiguos, ni migrar la fila ambigua que dejó el incidente del 29-08.
- Rehacer `PLAN_COLORS` de `PlanCard` (colores crudos preexistentes, ver D7).
- Prorrateo, créditos por días de trial no usados, o cualquier lógica de facturación nueva.

## Decisions

### D1 — La liveness de la suscripción se lee en el servidor, no con `getSubscriptionStatus()`

`/planes` suma la lectura de `public.subscriptions` a las consultas que ya hace, en vez de llamar `GET /payments/subscriptions/status` desde el cliente.

*Alternativa considerada:* `getSubscriptionStatus()` (existe, `subscriptions-client.ts` L109-132). Rechazada por tres razones concretas:

1. **Parpadeo del CTA.** `/planes` ya es Server Component y ya hace `getUser()` + lee `account_members`/`accounts`; sumar una lectura no agrega un round-trip. Con el fetch de cliente, en cambio, los CTAs tendrían que renderizar en un estado provisorio hasta que resuelva. Un botón que aparece tarde en la pantalla de conversión es peor que uno que nunca apareció: el usuario ya leyó "no hay botón" y se fue.
2. **La señal es ambigua.** `getSubscriptionStatus()` devuelve `{enabled:false}` tanto si la palanca está apagada como si falta `NEXT_PUBLIC_BACKEND_URL`; no distingue "no hay suscripción" de "no sé". Decidir la visibilidad de un CTA de pago sobre un "no sé" es exactamente cómo se construye el bug siguiente.
3. **La degradación con la palanca apagada ya está contratada.** Con la lectura directa: palanca OFF → cero filas → "sin suscripción viva" → se ofrece el CTA → click → `createSubscription` → 503 → cae al flujo legacy. Es la ruta que las tasks 8.1/8.2 de `mp-real-subscriptions` ya fijaron con tests. No hace falta una segunda palanca en el frontend, y no se agrega.

`subscriptions-client.ts` **no se toca**: sigue siendo el dueño de la *acción* (`createSubscription`). Lo que se reusa para la *lectura* es el patrón ya establecido en `/facturacion`.

### D2 — El predicado de "suscripción viva" nace en la capa canónica, con una sola definición

La consulta pasa a ser la segunda ocurrencia idéntica en el repo (`/facturacion` + `/planes`), así que se extrae a `frontend/lib/billing/live-subscription.ts` y `/facturacion` se migra a usarla en el mismo PR — regla PO "lo nuevo reusable nace en la capa canónica", y no es abstracción prematura: es una consulta ya escrita que se estaba por copiar.

**Invariante que el helper documenta y un test fija:** el conjunto de estados considerados vivos DEBE ser exactamente el de `find_live_subscription` del backend (`'pending'`, `'authorized'`). Si divergen, la UI ofrece contrataciones que el backend rechaza con 409, o las esconde sin motivo. El helper lleva el comentario que nombra la fuente; el test lo fija por enumeración explícita, no por copia de la constante (una constante compartida no existe entre Python y TypeScript, así que la duplicación es real y hay que vigilarla, no disimularla).

### D3 — Una sola regla para ofrecer contratación, con tres entradas

```
ofreceContratacion(tier) = tier !== 'gratis' && !billingExempt && !haySuscripcionViva
```

Sin ramas por upgrade/downgrade/igual. El plan efectivo deja de participar de esta decisión y queda con su único trabajo: el badge "Plan actual" y el destacado visual de la tarjeta.

Esto obliga a separar en `PlanCard` dos props que hoy están colapsadas en `isCurrent`: `currentPlan` (destacado) y la disponibilidad de contratación (CTA). Es el cambio estructural del change, y lo que la spec fija como requirement.

*Consecuencia deliberada:* una cuenta con PRO por cortesía verá CTA habilitado también en Inicial y Avanzado. Es correcto — puede querer pagar el tier barato cuando la cortesía se termine — y la etiqueta lo dirá con honestidad (D4).

### D4 — Etiquetas que nombran la acción real; el "downgrade" deja de mentir

Hoy `ctaLabel` deriva de la posición en la jerarquía: `"Pasarme a X"` hacia arriba, `"Cancelar y bajar a X"` hacia abajo. La segunda es falsa: `handleSelect` no cancela nada — llama `createSubscription(planInferior)` y manda al checkout de ese plan. Un usuario que lee "Cancelar y bajar a Inicial" y termina en una pantalla de pago de MercadoPago fue engañado por su propia UI.

- Cuando se ofrece contratación, la etiqueta es de contratación en todos los tiers (`"Suscribirme a X"` — copy exacto en OQ-1), sin importar si el tier está por encima o por debajo del plan efectivo. Es lo que la acción hace.
- Cuando **hay suscripción viva**, el tier distinto del contratado no ofrece compra: se degrada a un enlace a `/facturacion`, que es donde vive la cancelación. Esto **restaura** lo que la spec original de `billing-ui` ya pedía ("deshabilitado o muestra 'Bajar de plan' con link a `/facturacion`") y que la implementación había dejado de cumplir.

### D5 — El tier vigente explica por qué se le ofrece pagar

Un botón de pago en la tarjeta que dice "Plan actual" es desconcertante sin contexto: la lectura natural es "me van a cobrar dos veces". La tarjeta del tier que coincide con el plan efectivo lleva una línea de contexto derivada del **motivo** del acceso, que la página ya tiene o puede leer:

| Motivo | Origen del dato | Sentido de la línea |
|---|---|---|
| Cortesía | `billing_exempt = true` | No hay CTA (D3) — la línea explica la cortesía |
| Trial vigente | `trial_plan` + `trial_expires_at > now()` | Hasta cuándo va el trial, antes de decidir pagar |
| Plan pago con vencimiento | `plan_expires_at` | Cuándo se corta el acceso si no se suscribe |

`plan_expires_at` **no** está en el `select` actual de `/planes` (sí en el de `/facturacion`) — se suma.

**El motivo se deriva de los campos crudos, no del espejo `getEffectivePlan`.** Es deliberado: el espejo no lee `plan_expires_at` (D6) y usarlo haría que la línea nueva heredara esa mentira justo en el caso donde más importa.

### D6 — La divergencia del espejo TypeScript se mide acá y se arregla en otro change

Hallazgo de la investigación, no introducido por este change:

- SQL normativo (`supabase/migrations/20260829000001_mp_real_subscriptions_schema.sql` L435-442, D6 de `mp-real-subscriptions`): un `billing_plan` pago con `plan_expires_at <= now()` devuelve `'gratis'`.
- Espejo TypeScript (`frontend/lib/plan-utils.ts`, `getEffectivePlan`): `EffectivePlanInput` **no tiene** campo `plan_expires_at` y la función nunca lo consulta — devuelve el `billing_plan` sin más.
- El test de paridad (`frontend/__tests__/plan-utils.test.ts`), que el propio comentario del espejo invoca como garantía de no-divergencia, **no tiene ningún caso sobre ese eje** (verificado: cero coincidencias de `expires` para `plan_expires_at` en ese archivo).

Efecto: una cuenta paga vencida sigue viendo "Plan actual: PRO" y sus features desbloqueadas en el cliente, mientras el servidor ya la degradó.

*Por qué no se arregla acá:* `getEffectivePlan` gatea features en toda la app. Corregirlo puede cortarle features en la UI, de golpe, a cuentas que hoy las ven — blast radius muy superior al de este change y de otra categoría de governance. Arrastrarlo adentro convertiría un cambio de UI de billing en un cambio de gating.

*Lo que sí se hace acá:* (a) la línea de contexto de D5 no usa el espejo; (b) una task de medición en producción, read-only, que cuenta las cuentas con `billing_plan` pago y `plan_expires_at` pasado. Si el conteo es 0, el candidato es barato y sin daño histórico; si no lo es, hay cuentas viendo features que no les corresponden y eso es un incidente que merece su propio change con sign-off. El número decide, no la intuición.

### D7 — Estética: lo nuevo nace con tokens; lo viejo se registra

`PLAN_COLORS` (`PlanCard.tsx` L57-62) usa colores crudos (`bg-blue-100 text-blue-700`, `bg-slate-100 text-slate-700`, …) sin contraparte de tema oscuro — anterior a este change y contrario al patrón de tokens semánticos que estableció `tokens-contraste-aa`. **No se rehace acá** (es un refactor visual con su propio riesgo de regresión en la pantalla de conversión).

Lo que este change agrega — CTA nuevo, línea de contexto, aviso de exención, aviso de suscripción viva — nace con tokens semánticos y componentes base, y la verificación en **desktop + mobile** y **tema claro + oscuro** se hace sobre la pantalla completa. Si el contraste preexistente rompe la lectura de lo nuevo en oscuro, se corrige lo mínimo para que lo nuevo sea legible y el resto se registra como candidato.

### D8 — El 409 residual se maneja, aunque la UI no lo ofrezca

La regla de D3 evita ofrecer lo que el backend rechaza, pero hay una carrera real: el usuario abre `/planes`, completa un checkout en otra pestaña, vuelve y hace click sobre la página vieja. Hoy eso muestra en un toast el `detail` crudo del backend (`"Ya existe una suscripción viva para esta cuenta"`) y deja al usuario frente a un botón que no funciona.

`handleSelect` pasa a distinguir el 409: mensaje propio + `router.refresh()`, para que el Server Component recalcule con la suscripción ya viva y la pantalla se acomode sola. Sin el refresh, el usuario queda mirando un botón muerto.

## Risks / Trade-offs

- **[Ofrecer una contratación que el backend rechaza]** → predicado idéntico al de `find_live_subscription`, fijado por test (D2), más manejo explícito del 409 con refresh (D8).
- **[Regresión en la pantalla de conversión]** → los tres tests existentes de `PlanComparison` se ejecutan **antes** de tocar nada (safety net) y se conservan verdes sin editarlos. Si alguno necesita editarse, es señal de que se cambió un comportamiento que no estaba en el alcance.
- **[Un usuario en trial vigente contrata y paga desde el día 1, "perdiendo" los días que le quedaban]** → el trial no se cancela (`get_effective_plan` le da precedencia mientras esté vigente) pero el cobro empieza igual. Es una decisión de producto, no técnica → OQ-3. Mitigación mínima ya incluida: la línea de contexto (D5) dice hasta cuándo va el trial, para que decida informado.
- **[Cuenta exenta que quiere empezar a pagar y se queda sin camino]** → el aviso de exención incluye el canal de contacto que `/planes` ya monta para el tier Empresa (`aliadataWhatsAppUrl`); no se inventa un canal nuevo → OQ-2.
- **[La línea de contexto multiplica los estados visuales de la tarjeta]** → tres motivos × dos temas × dos anchos. Se acota a **una** línea de texto y se cubre con tests de render por motivo, no con variantes de componente.
- **[Trade-off aceptado]** una cuenta con suscripción viva pierde el botón directo hacia otro tier y debe pasar por `/facturacion`. Es un paso más para el caso menos frecuente, a cambio de eliminar un camino que hoy termina en un 409 crudo o en una compra que el usuario no pidió.

## Migration Plan

Sin migración de datos, sin cambios de schema, sin cambios de backend ni de contrato de API.

- **Deploy**: merge a `main` → Vercel construye y publica (pipeline habitual, sin paso manual).
- **Rollback**: revert del PR. No hay estado persistido que revertir — el change no escribe en ninguna tabla.
- **Interacción con la palanca**: `BILLING_SUBSCRIPTIONS_ENABLED` ya está en `true` en producción. Si se apagara, `createSubscription` devuelve 503 y el CTA cae al flujo legacy de pago único, que es la ruta ya cubierta por los tests existentes (D1.3).
- **Verificación en producción**: contratar el tier vigente desde una cuenta de prueba sin suscripción viva y comprobar que se creó la fila en `subscription_intents` **antes** de llegar al checkout — que es precisamente lo que faltó el 29-08 y mandó el cobro a la cola de ambiguos.

## Open Questions

- **OQ-1 (copy, PO)** — etiqueta del CTA cuando el tier coincide con el plan efectivo. Recomendación: **"Suscribirme a PRO"**, porque nombra la transición real (de acceso sin suscripción a suscripción) sin sugerir un cambio de tier que no ocurre. Alternativas: "Activar mi suscripción", "Contratar PRO".
- **OQ-2 (producto, PO)** — cuenta exenta: ¿aviso de cortesía con canal de contacto, o simplemente ningún CTA y sin explicación? Recomendación: **con aviso**, reusando el canal de contacto ya montado en `/planes`; el silencio se lee como una pantalla rota.
- **OQ-3 (producto, PO)** — ¿ofrecer contratación durante un trial vigente? Recomendación: **sí, con la línea de contexto de D5**. Es el caso de los 32+ trials que vencen a fin de agosto: si no se les ofrece el CTA hasta que el trial expire, se les pide que se queden sin servicio primero y paguen después.
- **OQ-4 (técnica, deriva del número)** — `plan_expires_at` ausente en el espejo TypeScript (D6). Se mide en este change (task de medición). Si el conteo de cuentas afectadas es 0 → candidato barato para un change chico junto con el caso faltante del test de paridad. Si es > 0 → hay cuentas con features que no les corresponden y merece change propio con sign-off.
- **OQ-5 (UX, PO)** — con suscripción viva, ¿la pantalla dice explícitamente "ya tenés una suscripción activa de este plan", o simplemente no muestra CTA? Recomendación: **decirlo**, por la misma razón que OQ-2.

Ninguna OQ bloquea el arranque de la implementación: las cinco tienen recomendación por defecto y ninguna cambia la estructura (D1-D3). Si el PO no responde, se implementa la recomendación y se registra la decisión en `CHANGES.md`.

**Sign-off del PO (2026-08-29, chat con el orquestador): "aplicalo con todas las recomendaciones".** Las cinco OQs quedan resueltas por su recomendación, sin más discusión:
- **OQ-1** → copy del CTA: **"Suscribirme a {Tier}"**.
- **OQ-2** → cuenta exenta: **con aviso de cortesía**, reusando `aliadataWhatsAppUrl` (sin canal nuevo).
- **OQ-3** → contratar durante trial vigente: **sí**, con la línea de contexto de D5.
- **OQ-4** → espejo TS de `getEffectivePlan` vs. `plan_expires_at`: se decide con el número medido en la task 8.1 (si da 0 afectados, se documenta y no se toca el gating en este change).
- **OQ-5** → suscripción viva: **se dice explícitamente** "ya tenés una suscripción activa de este plan".

El checkpoint 5.4 🔎 queda satisfecho por este sign-off (no bloquea la implementación). El checkpoint 10.6 🔎 (verificación en producción de que la intención se crea antes del checkout) queda **[MANUAL/post-merge]** — lo ejecuta el orquestador/PO, no este apply.
