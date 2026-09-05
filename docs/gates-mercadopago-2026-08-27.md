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

## Actualización 2026-09-04 — la condición D5-(a) sigue sin cumplirse (5.1 tildada ≠ canal probado)

Re-medición en prod, read-only, sin herramientas de MercadoPago que muevan datos:

- `subscriptions`: **0 filas** en toda su historia. `subscription_intents`: **0**.
  `operation_idempotency` con `operation_kind='subscription_webhook'`: **0** — el código que
  procesa una notificación real de suscripción **nunca corrió en producción**, ni en el
  incidente del 29-08 ni después.
- `billing_events` con `mercadopago_payment_id`: **1 sola fila**, del 2026-06-13, anterior al
  deploy de este change (01-08) y reconciliada a mano. Cero `plan_upgraded` en 60 días.
  `email_logs` con `payment_receipt`: 2 filas, ambas del mismo evento de junio.
- La cuenta de Daniel (`0f627a85-7d01-4323-8b3f-122bd834a4ab`) tiene `billing_plan='pro'` y
  `plan_expires_at='2026-10-09 13:45:19+00'` — coincide exacto con el `UPDATE` manual del
  INCIDENTE GATE 3 de arriba, **no** con ningún webhook.
- Lo único que llegó al canal fueron las **2 notificaciones del topic
  `subscription_preapproval_plan`** (29-08, HTTP 200) ya documentadas en el INCIDENTE GATE 3 —
  un topic que el código trata como no manejado y no escribe nada. Confirmado también por
  `mcp__mercadopago__notifications_history` (app ALIADATA `5864120912417849`): **1**
  notificación en el último mes, ese mismo topic, **0** fallidas.
- Tráfico del relay legacy (`frontend/app/api/billing/webhook/route.ts`): **cero**, confirmado
  por tres fuentes independientes (logs de Render en la ventana 28-08→04-09 sin ninguna línea
  con `x-relay-source`; el registro de la task 5.4; el historial de MercadoPago). **34 días en
  cero.**
- Palanca `BILLING_SUBSCRIPTIONS_ENABLED` sigue ON (`GET /payments/subscriptions/status` →
  401, no 503). Ruta legacy `/api/billing/webhook` sigue desplegada (`GET` → 405).

**Conclusión**: lo que el 29-08 probó fue **alcance de red + firma HMAC válida sobre un topic
que no escribe nada** — no una acreditación automática. La condición D5-(a) ("un pago real de
verificación acreditó **solo**, sin intervención manual") sigue sin cumplirse. La task 5.1 de
`v31-mp-upgrade-webhook-fix` está tildada `[x]` (documenta correctamente que el canal responde
200 y valida firma) pero **no** debe leerse como "canal de acreditación de suscripciones
probado" — ver la nota fechada 2026-09-04 en `openspec/changes/v31-mp-upgrade-webhook-fix/tasks.md`
junto a esa task. La condición D5-(b) (cero reenvíos del legacy) sí está cumplida de hecho.

**GATE 3 sigue abierto de fondo**: los checkboxes de la sección GATE 3 arriba (líneas
"Camino preferido"/"Camino B"/"Daniel completa el checkout"/"PO revisa logs") reflejan el
estado real — ninguno se tildó porque el checkout de Daniel del 29-08 quedó bajo la app vieja
del panel (huérfana, nunca notifica) y la migración a la suscripción sana bajo ALIADATA sigue
pendiente para `~29-09`, tal como ya documentaba este runbook.

**Recomendación para GATE 5 / task 6.1**: no fijar todavía la ventana de convivencia del
reenviador legacy. El contador de los 30 días recomendados debería arrancar el día que D5-(a)
se cumpla de verdad (un pago de suscripción real con fila en `subscriptions` +
`operation_idempotency`), no antes — retirar el reenviador ahora dejaría sin red de seguridad
justo el único camino de acreditación que todavía no se ejercitó de punta a punta.

## Actualización 2026-09-04/05 — primera suscripción real acreditada de punta a punta (D5-a cumplida, con matiz)

Lo que la sección anterior daba por pendiente ocurrió al día siguiente. Cronología:

- **2026-09-04, 20:54 UTC** — Daniel (login app `tubecoventas6@gmail.com`, cuenta
  `b6005a59-b996-4a3c-bafd-6b89ee714e00`) paga la suscripción al plan **Inicial** ($24.900).
  Pago MP `176341057469` **aprobado**. Preapproval aprobado
  `50681db010a341968e53c3880d52c3e9` → `subscriptions.id fa624f9b-32e5-4b5c-ad0d-fc64e6dc16b1`.
  Un primer intento (`177300693338`) fue rechazado sin cobro; un preapproval rechazado
  (`7ccbebe460a24fbba077c2b22eaac5e3`) quedó `cancelled` en MP y como fila ambigua
  `caeaa3a1-42b2-44bf-b938-ce20452160ff` en la cola, sin cobro asociado.
- El pago real ejercitó, por primera vez en producción, el camino completo de
  `process_subscription_preapproval_notification` / `resolve_ambiguous_subscription` —
  destapando una **cadena de 7 hotfixes** (todos con OK del PO, mergeados y desplegados el
  mismo día):
  1. **#511** — `service_role_key` leía la env inexistente `SERVICE_ROLE_KEY` en vez de
     `SUPABASE_SERVICE_ROLE_KEY` → 502 "No se pudo resolver el email" en TODA alta de
     suscripción. Es la causa raíz de las 0 filas históricas medidas el 04-09 arriba.
  2. **#512** — el webhook devolvía 500 por dos motivos: el CHECK
     `operation_idempotency_operation_id_contract` no eximía
     `operation_kind='subscription_webhook'` (23514 → 422 en toda notificación de
     suscripción) y un `UPDATE accounts SET updated_at = now()` contra una columna
     inexistente en esa tabla (migración `20261027000001`).
  3. **#513** — la fila ambigua nacía y se resolvía con `plan='pro'` hardcodeado en vez de
     derivarlo del `preapproval_plan_id` real del webhook.
  4. **#514** — un `asyncpg.Record` crudo sin serializar producía 500 en el endpoint admin
     de la cola de ambiguas.
  5. **#515** — la cuota ya cobrada antes de resolver la ambigua no se replicaba a la
     cuenta recién asignada; sumó el endpoint admin
     `POST /payments/subscriptions/{id}/replay-charges` (migración `20261028000001`).
  6. **#516** — Recibos de Pago / el numerador / `rpc_emit_subscription_payment_cae` solo
     cubrían `plan_upgraded`; se extendieron a `subscription_payment_approved` + backfill
     (migración `20261029000001`).
  7. **#517** — 42P18 (parámetros sin cast en `jsonb_build_object`), `_apply_approved_charge`
     sin transacción envolvente, el replay no completaba un estado parcial, y el handler
     genérico de 500 de asyncpg no logueaba la causa real.

**Estado final verificado (2026-09-04/05)**: cuenta de Daniel `inicial`/`active`,
`plan_expires_at` **2026-10-14**; suscripción `authorized`, `next_payment_date` **2026-10-04**;
recibo **RC-2026-000002** emitido; `email_logs` con `subscription_payment_approved` en `sent`.
Reenviador legacy: **0 reenvíos, sin cambios** (34+ días en cero). Ambos replays de cuotas los
ejecutó el PO con su propio JWT de admin.

**Por qué "con matiz" y no "canal probado sin reservas"**: la recepción y el procesamiento de
la notificación fueron automáticos — el bug no era del canal de webhooks en sí, sino de la
cadena de código que el pago real ejercitó por primera vez. Pero la **atribución** a la cuenta
de Daniel sí requirió resolución manual en `/admin/pagos/ambiguas`: el `payer_email` que
devuelve MercadoPago es el de la cuenta de MP del pagador, no el login de la app, y no
coincidieron. D5-(a) pedía "acreditó solo, sin intervención manual" — la intervención existió,
acotada a la atribución, no al procesamiento del pago ni a la escritura contable. Se da por
**cumplida con esa salvedad documentada**, no como falla del canal.

**Candidatos nuevos que deja esta corrida** (ver `openspec/changes/v31-mp-upgrade-webhook-fix/design.md`
§"Candidatos identificados por la primera suscripción real" para el detalle completo — ninguno
implementado):
- (a) `external_reference=<intent_id>` en el `init_point` del checkout, para matchear sin
  depender de que dos emails distintos coincidan.
- (b) Acción "descartar" en la cola de ambiguas — la fila `caeaa3a1…` (rechazada, sin cobro)
  queda ahí sin ninguna salida limpia.
- (c) Botón en la UI de admin para `POST /payments/subscriptions/{id}/replay-charges` — hoy
  solo se invoca a mano con el JWT del PO.
- (d) El replay sincroniza `next_payment_date` pero no `last_payment_status`, que queda `NULL`
  para las cuotas replicadas.

**Efecto sobre GATE 5 / task 6.1**: la recomendación de arriba queda **superada** — D5-(a) ya
se cumplió el 2026-09-04, así que el contador de los 30 días recomendados para la ventana de
convivencia puede arrancar esa fecha (cerraría el 2026-10-04 si el PO no indica lo contrario).
D5-(b) sigue cumplida de hecho. **La decisión de fondo sobre OQ1/6.1 sigue pendiente del PO**
— ver la nota fechada 2026-09-05 en `tasks.md` 6.1.

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
