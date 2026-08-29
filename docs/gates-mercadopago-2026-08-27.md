# Gates de MercadoPago — runbook de activación (2026-08-27)

> Preparado por el orquestador OPSX. Cubre los gates `[MANUAL PO]` pendientes de
> `v31-mp-upgrade-webhook-fix` (27/38) y `mp-real-subscriptions` (55/77).
> Governance **CRÍTICO** (dinero real): el agente no dispara pagos ni toca el panel de MP —
> este documento deja cada gate listo para que el PO lo ejecute, con la verificación que
> el agente corre después de cada paso.

---

## Hallazgo principal: la palanca YA está encendida

La activación que las tasks §9 dan por pendiente **ocurrió (al menos en parte) el 2026-08-02
de madrugada** y el bookkeeping nunca se actualizó. Evidencia (verificada 2026-08-27):

1. **`BILLING_SUBSCRIPTIONS_ENABLED=true` en prod** — `GET /payments/subscriptions/status` y
   `GET /payments/subscriptions/ambiguous` sin auth devuelven **401** (2 mediciones cada uno).
   Con la palanca OFF devolverían **503** antes de evaluar auth: la palanca es dependencia de
   decorador (`routers/payments.py:188`) y FastAPI las resuelve antes que las de parámetro.
   No hay middleware de auth que explique el 401 (solo CORS en `backend/main.py:61`).
2. **La task 9.4 (migración de la cuenta de Daniel) ya se ejecutó** — `accounts.plan_expires_at`
   pasó de `NULL` (captura del 01-08) a `2026-09-01 03:09:21+00` = **02-08 03:09 UTC + 30 días
   exactos**, la fórmula "activación + 30 días" de la task. `get_effective_plan` sigue en `'pro'`.
3. La task 8.8 de `mp-real-subscriptions` dice literalmente "Agregada **post-activación**
   (2026-08-02)".
4. **El pago E2E (webhook-fix 5.1) NUNCA corrió**: `billing_events` no tiene ningún evento con
   `mercadopago_payment_id` (los últimos son `trial_pro_granted` del 31-07). La palanca se
   encendió **sin** cumplir la condición (1) documentada en `backend/core/config.py:71-83`.
5. `subscriptions` y `subscription_intents` existen y tienen **0 filas** — nadie inició una
   suscripción desde la activación.

## Dos riesgos con fecha

| Fecha | Riesgo | Estado |
|---|---|---|
| **30-08 (3 días)** | 32 trials PRO vencen y esas cuentas degradan a `gratis`. Su único camino de pago es el CTA de upgrade → `POST /payments/subscriptions`. Si los `MP_PLAN_ID_*` no estuvieran en Render, ese CTA estaría roto (400 sin fallback — el frontend solo cae al legacy con 503). | ✅ **MITIGADO 27-08 (GATE 1)**: los 3 `MP_PLAN_ID_*` están en Render. Residual: validez de los planes en MP — se confirma con el checkout del GATE 3 (o antes, probando los `init_point`) |
| **01-09 (5 días)** | La cortesía de Daniel (`0f627a85…`, la única cuenta paga real) vence. Con 0 suscripciones creadas, si no se suscribe antes, `get_effective_plan` lo degrada a `gratis`. | ⚠️ **VIGENTE** — lo cierra el GATE 3 |

## Estado verificado hoy (27-08, todo read-only)

| Pieza | Estado | Evidencia |
|---|---|---|
| Canal webhook backend | ✅ vivo y fail-closed | `/health` 200; POST diagnóstico firma inválida → 400 RFC 7807, cero escrituras |
| Relay legacy frontend | ✅ propaga errores | mismo POST vía `/api/billing/webhook` → 400 (no enmascara con 200) |
| D9 (firma de topics de suscripción) | ✅ en el código vivo | `data.id` del query param, lowercased para el manifiesto (`services/payments.py:37-38`); case original para la API de MP (`routers/payments.py:138-147`) |
| Firma antes del dispatch | ✅ | `routers/payments.py:108-111` — verificación antes de parsear/despachar |
| Migraciones (tablas, CHECK, RLS) | ✅ | `subscriptions` + `subscription_intents` existen; `operation_kind` incluye `subscription_webhook` |
| Precios reales (`plan_limits`) | ✅ | inicial **$24.900** / avanzado **$34.900** / pro **$69.900** ARS mensuales |
| Palanca | ✅ **ON — confirmado por el PO en Render (27-08)** | GATE 1 cerrado; la inferencia 401-vs-503 quedó validada |
| `MP_PLAN_ID_*` en Render | ✅ **presentes los 3 (PO, 27-08)** | GATE 1 cerrado; validez en MP se confirma en GATE 3 |
| Secretos MP en Render (1.3) | ✅ presentes (PO, 27-08) | 1.3 cerrada |
| Los 3 `preapproval_plan` en MP | ✅ activos, montos exactos (agente, 27-08) | checkout público + control negativo (412) |
| Panel MP: secreto alineado (1.4), URL (1.5), topics (9.2) | ✅ **cerrado (PO + agente, 27-08)** | simulación `subscription_preapproval` → 200 OK + 0 escrituras verificadas |

---

## GATE 1 — Render (PO, ~5 min, HOY) — ✅ CERRADO 2026-08-27

**Resultado (PO, 27-08)**: los 3 `MP_PLAN_ID_*` están en Render y `BILLING_SUBSCRIPTIONS_ENABLED=true`
— la inferencia del hallazgo 1 queda confirmada y el escenario "CTA roto" del riesgo 30-08
queda descartado. Los planes se habían creado el 02-08 junto con la activación.

En el dashboard de Render → servicio del backend → Environment, confirmar **presencia**
(nunca hace falta copiar valores):

- [x] `BILLING_SUBSCRIPTIONS_ENABLED` = `true` — **confirmado PO 27-08**
- [x] `MP_PLAN_ID_INICIAL` — **confirmado PO 27-08**
- [x] `MP_PLAN_ID_AVANZADO` — **confirmado PO 27-08**
- [x] `MP_PLAN_ID_PRO` — **confirmado PO 27-08**
- [x] `MERCADOPAGO_ACCESS_TOKEN` — **confirmado PO 27-08**
- [x] `MERCADOPAGO_WEBHOOK_SECRET` — **confirmado PO 27-08** (su alineación con el panel es GATE 2)

**Residual verificado por el agente (27-08)** — los 3 `preapproval_plan` existen y están
activos en MP, con los montos exactos de `plan_limits` (control negativo: un ID inventado
devuelve HTTP 412 sin nombre ni monto — la señal discrimina):

| Tier | `preapproval_plan_id` | Nombre en MP | Monto |
|---|---|---|---|
| inicial | `43ee5d917f6c4d92948b186c13f76826` | ALIADATA Inicial | $ 24.900 ✓ |
| avanzado | `664b441e1cde41fca49134bb8a096757` | ALIADATA Avanzado | $ 34.900 ✓ |
| pro | `45acf9a340354574ba31435e92508f99` | ALIADATA Pro | $ 69.900 ✓ |

→ **9.1 verificada de punta a punta; 1.3 cerrada; 9.7 confirmada.**

**Si falta algún `MP_PLAN_ID_*`** hay dos salidas, en orden de preferencia:

a) Los planes quizá ya existen en MP (creados el 02-08): panel MP → *Suscripciones → Planes*.
   Si están, copiar sus IDs (32 chars alfanuméricos) a las 3 variables y redeploy.

b) Si no existen, crearlos (uno por tier — el `transaction_amount` sale de `plan_limits`):

```bash
curl -X POST https://api.mercadopago.com/preapproval_plan -H "Authorization: Bearer $MP_ACCESS_TOKEN_PROD" -H "Content-Type: application/json" -d '{"reason":"Aliadata Plan Inicial","back_url":"https://www.aliadata.com.ar/facturacion","auto_recurring":{"frequency":1,"frequency_type":"months","transaction_amount":24900,"currency_id":"ARS"}}'
```

```bash
curl -X POST https://api.mercadopago.com/preapproval_plan -H "Authorization: Bearer $MP_ACCESS_TOKEN_PROD" -H "Content-Type: application/json" -d '{"reason":"Aliadata Plan Avanzado","back_url":"https://www.aliadata.com.ar/facturacion","auto_recurring":{"frequency":1,"frequency_type":"months","transaction_amount":34900,"currency_id":"ARS"}}'
```

```bash
curl -X POST https://api.mercadopago.com/preapproval_plan -H "Authorization: Bearer $MP_ACCESS_TOKEN_PROD" -H "Content-Type: application/json" -d '{"reason":"Aliadata Plan Pro","back_url":"https://www.aliadata.com.ar/facturacion","auto_recurring":{"frequency":1,"frequency_type":"months","transaction_amount":69900,"currency_id":"ARS"}}'
```

Guardar el `id` de cada respuesta en su `MP_PLAN_ID_*` de Render.
**Plan C** (si no hay tiempo antes del 30-08): apagar `BILLING_SUBSCRIPTIONS_ENABLED`
→ el CTA vuelve solo al flujo legacy de pago único (reversión sin deploy, solo restart).

**Cierra**: webhook-fix 1.3 · mp-real 9.1 · confirma 9.7. → Avisar al agente: verifica que el
CTA de upgrade responde (y deja registrado el estado en las tasks).

## GATE 2 — Panel de MercadoPago (PO, ~10 min) — ✅ CERRADO 2026-08-27

**Resultado (PO + agente, 27-08)**:

- [x] **1.5** — el PO revisó el panel y **no existe** ninguna URL apuntando al frontend viejo
  (`aliadata.com.ar/api/billing/webhook`); el webhook configurado es el del backend.
- [x] **9.2** — los topics ya estaban tildados (habilitados el 02-08 junto con la activación).
- [x] **1.4** — secreto alineado, **probado empíricamente**: "Simular notificación" con un
  `subscription_preapproval` (data.id `123456`) → **200 OK** en el panel. Un secreto
  desalineado habría dado 400.
- [x] **9.3 parcial** — una notificación de topic de suscripción llegó, verificó firma y fue
  procesada. Verificación del agente post-simulación: **0 escrituras** (`subscriptions` 0,
  `subscription_intents` 0, idempotencia `subscription_webhook` 0, `billing_events` 0 y
  emails de suscripción 0 en las últimas 6 h) — el preapproval inexistente se descartó
  limpio (task 6.7/6.10). El **9.3 pleno** (una notificación de cada topic con datos reales)
  se cierra solo con el checkout del GATE 3.

~~*Micro-pendiente*~~ **Resuelto (PO, 27-08)**: el campo URL del panel apunta al backend
(`emprende-smart-backend.onrender.com/payments/webhook`) — GATE 2 sin residuales.

## INCIDENTE GATE 3 (29-08) — checkout OK, notificaciones al vacío — ✅ RESUELTO el mismo día

Daniel se suscribió (checkout 10:45 ART, $69.900 cobrados, "Al día") pero **MP no emitió ni una
notificación**. Diagnóstico con evidencia triple (DB 0 filas · Render 0 POSTs con control
positivo · historial MP vacío) + sonda activa (PUT al preapproval → tampoco emitió).

**Causa raíz**: los 3 planes del 01-08 se crearon **desde el panel de MP** (instrucción del
paso a paso de esa noche) → pertenecen a la app interna del panel (`3909856389923111`), no a
ALIADATA (`5864120912417849`) donde vive el webhook. Las suscripciones heredan la app del plan
→ eventos ruteados a una config inexistente. **Regla dura nueva: los `preapproval_plan` se
crean SIEMPRE por API con el token de la app del webhook, NUNCA desde el panel — y se chequea
`application_id` en cada respuesta de creación.**

**Fix ejecutado (29-08)**: 3 planes recreados por API bajo ALIADATA + `MP_PLAN_ID_*` nuevos en
Render (los 32 trials del 30-08 ya apuntan a planes sanos):

| Tier | `preapproval_plan_id` NUEVO (ALIADATA) | Viejo (panel — muerto, no usar) |
|---|---|---|
| inicial | `024813393f994f819327459602d1f8a1` | ~~`43ee5d917f6c4d92948b186c13f76826`~~ |
| avanzado | `40ed6824eab14ac2b457ded0851a7b46` | ~~`664b441e1cde41fca49134bb8a096757`~~ |
| pro | `7c756ee46c4942c1ac3d749740ed4ae6` | ~~`45acf9a340354574ba31435e92508f99`~~ |

**Canal validado de punta a punta sin dinero**: dos PUTs al plan PRO nuevo (14:59 UTC) →
2 POSTs en Render `type=subscription_preapproval_plan` → **200 OK** (firma validada, topic no
manejado → descarte limpio). Emisión + entrega + firma, todo confirmado.

**Daniel (suscripción huérfana bajo la app del panel, cobrada hoy — NO cancelar)**:
`plan_expires_at` ajustado manualmente a **2026-10-09 13:45 UTC** (fin del período pagado
29-09 + 10 días de gracia; UPDATE aprobado por el PO, ejecutado en el SQL Editor, verificado).
**~29-09**: cancelar su suscripción vieja y que entre por el link del plan PRO nuevo
(`…checkout?preapproval_plan_id=7c756ee46c4942c1ac3d749740ed4ae6`) — desde ahí notifica
normal. Su cobro de hoy queda sin fila en `billing_events` (gap conocido y documentado; la
suscripción vieja jamás notificará). Los planes viejos del panel quedan sin cancelar hasta
confirmar que cancelarlos no arrastra la suscripción activa.

**Pendiente de seguridad (HOY)**: el access token de prod se filtró en el chat → renovar en
*Credenciales de Producción → Más opciones → Renovar* (las credenciales viejas siguen activas
**12 horas** — ventana para actualizar `MERCADOPAGO_ACCESS_TOKEN` en Render y en Vercel sin
corte). En Vercel la var existe con ese mismo nombre (`lib/mercadopago.ts:25`).

## GATE 3 — E2E con dinero real = la suscripción de Daniel (PO, antes del 01-09)

**Reinterpretación necesaria**: la 5.1 original (pago único por Preference) ya no es alcanzable
desde la UI — con la palanca ON el CTA crea suscripciones. El E2E que prueba el canal con
dinero real ES la primera suscripción real, y la candidata natural es la de Daniel (D12):
mata los dos pájaros (valida el canal + evita que la única cuenta paga degrade el 01-09).

- [ ] Camino preferido: guiar a Daniel: login → `/planes` → botón "Suscribirme a PRO" (crea su
  `subscription_intent` y la reconciliación al llegar la notificación es automática).
  ~~Ojo: la UI puede no ofrecer botón~~ **Resuelto 29-08**: el change
  `planes-suscribirse-plan-vigente` (PR #473, mergeado `1ab55a3`) hace que /planes ofrezca el
  CTA del plan vigente cuando no hay suscripción viva — el camino B ya no es necesario para
  la migración del ~29-09.
- [ ] Camino B: enviarle el link directo del plan PRO:
  `https://www.mercadopago.com.ar/subscriptions/checkout?preapproval_plan_id=45acf9a340354574ba31435e92508f99`
  (verificado activo 27-08). Sin intent previa, la suscripción entra a la **cola de ambiguos**
  (por diseño D2bis) → se asigna a su cuenta en `/admin/pagos/ambiguas` — el agente avisa
  cuando aparezca.
- [ ] Daniel completa el checkout con su tarjeta. **El agente no dispara ni simula este pago.**
- [ ] PO: revisar los logs de Render del momento (webhook-fix 5.3): firma validada, origen
  `direct`, sin secretos en la salida.

**Verifica el agente después (5.2 + 9.3 pleno + 9.5)**: fila en `subscriptions` con su
`preapproval_id`; intent matcheada (`matched_at`); exactamente **una** fila por evento
(idempotencia); plan efectivo de la cuenta intacto en `'pro'`; email correspondiente en
`email_logs`; registra la línea base de reenvíos del relay (5.4).

## GATE 4 — Primer cobro real (9.6)

MP suele cobrar la primera cuota al autorizar; si no, al mes. Cuando el PO confirme que el
cobro figura acreditado en MP:

**Verifica el agente**: `billing_events` con `subscription_payment_approved` y su
`mercadopago_payment_id`; `plan_expires_at` corrido a `next_payment_date` + 10 días de gracia;
email de renovación en `email_logs`; sin duplicados.

*Notas técnicas del canal (doc oficial de MP, 27-08 vía su MCP)*: MP da 22 s de timeout y
reintenta cada 15 min — el cold start de Render (~50 s) lo mitiga `keep-backend-warm` y el
handler idempotente absorbe cualquier reintento sin duplicar. El detalle del cobro se consulta
en `GET /authorized_payments/{id}` (ya implementado así). Watch-item para GATE 3: confirmar
empíricamente que `subscription_preapproval` notifica también suscripciones creadas desde un
plan (la tabla de la doc es ambigua); si no llegara, el síntoma es pago visible en MP sin fila
en `subscriptions`.

## GATE 5 — Cierre y limpieza (después de 3-4)

- [ ] **PO decide OQ1** (webhook-fix 6.1): ventana de convivencia del relay legacy —
  recomendación vigente: **30 días y retirar**. Al cierre (6.2): si hubo 0 reenvíos, retirar
  `frontend/app/api/billing/webhook/route.ts` (PR aparte, 6.3).
- [ ] Bookkeeping (agente, vía PR): tildar 1.3-1.6, 5.1-5.4, 9.1-9.7 con la evidencia de cada
  gate; corregir la ficha de `CHANGES.md` ("activación sigue apagada" quedó falsa el 02-08);
  `/opsx:archive` de ambos changes.

---

## Qué NO se pudo verificar sin acceso (por diseño)

Valores/presencia de env vars en Render, logs de Render, panel de MP (secreto, topics, URL
a nivel app, existencia de los 3 planes), y si Daniel recibió el link. Todo eso es
exactamente lo que cubren los GATES 1-3.

**Fuera de alcance**: el tercer gate PO pendiente del cluster (hook de claims en el Auth
Dashboard de Supabase) no es de MercadoPago — sigue pendiente aparte.

**Nota de gobernanza**: la palanca se encendió el 02-08 sin el pago E2E previo que el gate
documentado en `config.py` exigía. No hay daño (0 suscripciones, 0 intents, el flujo legacy
siguió siendo el fallback), pero el GATE 3 es ahora la deuda de verificación que ese salto
dejó abierta.
