# Design — v31-mp-upgrade-webhook-fix

## Context

**Estado actual verificado en el código** (no supuesto):

| Pieza | Archivo | Estado |
|---|---|---|
| Creación de preferencia | `frontend/app/api/billing/preferences/route.ts:85` | `notification_url: ${appUrl}/api/billing/webhook` |
| Webhook legacy | `frontend/app/api/billing/webhook/route.ts` | Firma HMAC **correcta**; escrituras con `createClient()` de `@/lib/supabase/server` (cliente anónimo + cookies) → RLS las bloquea |
| Webhook correcto | `backend/routers/payments.py:58` + `backend/services/payments.py:104` | HMAC + idempotencia por `mercadopago_payment_id` + `get_service_conn` + modo `?shadow=true` |
| URL del backend en el frontend | `NEXT_PUBLIC_BACKEND_URL` | Ya en uso por `frontend/lib/api/python-client.ts` y por el `connect-src` del CSP (`frontend/lib/supabase/middleware.ts:47`) |

El legacy devuelve **HTTP 200 igual** cuando la escritura falla: los `if (updateError)` que devolverían 500 nunca se alcanzan porque el cliente anónimo no lanza — la RLS filtra las filas y el update afecta 0 registros sin error. MercadoPago da la notificación por entregada y no reintenta. De ahí que el bug sea silencioso.

**Restricción dura del dominio**: MercadoPago **hornea `notification_url` dentro de la preferencia** en el momento de crearla. No hay forma de re-apuntar una preferencia ya emitida. Toda preferencia creada antes del deploy de este change va a notificar a `/api/billing/webhook` por el resto de su vida útil.

**Governance**: CRÍTICO (dinero real, 34 cuentas, 1 pagador). Sign-off del PO sobre el rumbo el 2026-07-31.

## Goals / Non-Goals

**Goals:**
- Que un pago aprobado de MercadoPago acredite el plan **sin intervención manual**, tanto para preferencias nuevas como para las ya emitidas.
- Un único componente escribiendo la acreditación → firma e idempotencia verificadas una sola vez.
- Cutover reversible y decidido con evidencia observable.
- Dejar el canal de notificaciones sano para que `mp-real-subscriptions` construya encima.

**Non-Goals:**
- Atomicidad transaccional del webhook y lookup determinista de cuenta → **H-19 / `v31-mp-webhook-atomic`** (P1, change propio).
- Suscripciones recurrentes, `plan_expires_at` real, dunning, downgrade por impago → **`mp-real-subscriptions`**.
- Tocar `/api/billing/cancel` — sigue igual hasta que las suscripciones reales lo reemplacen.
- Mover la creación de preferencias al backend. Es la alternativa "limpia" pero mueve el flujo de checkout entero (auth, `plan_limits`, CORS, contrato con `PlanComparison.tsx`) sin arreglar nada que el cambio de una URL no arregle. **Rechazada por relación riesgo/beneficio** en un dominio CRÍTICO; queda disponible si `mp-real-subscriptions` la necesita para crear `preapproval` server-side.

## Decisions

### D1 — El route legacy se convierte en reenviador, no se borra

**Decisión**: `frontend/app/api/billing/webhook/route.ts` pasa a ser un proxy sin estado hacia `POST {NEXT_PUBLIC_BACKEND_URL}/payments/webhook`. Se le quita todo acceso a Supabase y toda lógica de plan.

**Por qué**: es la única forma de cubrir las preferencias en vuelo. Un usuario que abrió el checkout ayer y paga mañana genera una notificación contra la URL vieja; si esa ruta ya no existe (404) o sigue rota (200 mudo), el pago se cobra y el plan no acredita — exactamente el bug que este change cierra. Borrar el route sería arreglar el caso nuevo y dejar abierto el viejo.

**Alternativa considerada**: un redirect HTTP 307/308 hacia el backend. Rechazada — depende de que el cliente HTTP de MercadoPago siga redirects **preservando método, cuerpo y headers custom** (`x-signature`, `x-request-id`). No está documentado que lo haga, y si perdiera un header la firma falla y el síntoma vuelve a ser "cobrado, no acreditado". El reenvío explícito controla exactamente qué se propaga.

### D2 — El reenvío es de bytes crudos, nunca de un objeto re-serializado

**Decisión**: leer el cuerpo con `await req.text()` (o `arrayBuffer()`) y reenviarlo tal cual, junto con `x-signature` y `x-request-id`. Prohibido `JSON.parse` → `JSON.stringify`.

**Por qué**: la firma HMAC no cubre el cuerpo, pero el `data.id` que entra al template firmado se extrae del payload; y cualquier normalización (orden de claves, escapes unicode, espacios) puede alterar lo que el backend interpreta. La regla operativa —reenviar bytes, no objetos— elimina la clase entera de bugs. El backend ya lee `await request.body()` crudo (`payments.py:64`), así que la cadena queda byte-a-byte de punta a punta.

### D3 — Una sola variable de entorno para la URL del backend

**Decisión**: tanto la `notification_url` de la preferencia como el destino del reenviador salen de `NEXT_PUBLIC_BACKEND_URL`. Ambos fail-closed si falta.

**Por qué**: dos variables para el mismo destino es una fuente garantizada de drift entre entornos. Que sea `NEXT_PUBLIC_` no agrega exposición — es una URL pública que ya viaja al bundle y ya está declarada en el `connect-src` del CSP.

### D4 — La convivencia se satisface con dos caminos de entrada y un solo escritor

**Decisión**: durante la ventana conviven la entrada legacy (reenviada) y la directa, ambas terminando en el mismo endpoint del backend. **No se usa `?shadow=true` para este cutover.**

**Por qué, y en qué se desvía de la regla literal del proyecto** (`CLAUDE.md`: *"migrarlo corriendo en paralelo al webhook actual y comparando resultados antes de cortar"*): esa regla asume dos implementaciones que **ambas funcionan**, donde comparar salidas detecta divergencias. Acá no aplica: el webhook legacy **no escribe nada** en producción — comparar sus resultados contra el backend produciría, en el mejor caso, "el legacy no hizo nada / el backend acreditó bien", que es el diagnóstico ya conocido. Y correr el backend en `shadow=true` significaría que **nadie** acredita, sosteniendo el bug.

Lo que sí se preserva es el **propósito** de la regla: no cortar a ciegas y poder volver atrás. Se cumple con (a) el legacy sigue vivo y recibiendo, (b) el backend es idempotente por `mercadopago_payment_id`, así que una doble entrega colapsa en una sola acreditación verificable, (c) hay traza de origen para saber cuándo el camino viejo dejó de usarse, y (d) el retiro está condicionado a evidencia. **Esta desviación se señaliza al PO en tasks.md antes de ejecutar el cutover.**

### D5 — El cutover se decide por evidencia, no por fecha

**Decisión**: el reenviador se retira cuando se cumplan **las dos** condiciones: (a) un pago real de verificación acreditó solo, y (b) cero reenvíos registrados durante la ventana acordada con el PO.

**Por qué**: no se sabe cuántas preferencias hay emitidas y sin pagar. La condición (b) mide directamente lo que importa —¿queda tráfico viejo?— en vez de estimarlo.

### D6 — Cold start de Render: se absorbe con los reintentos de MercadoPago

**Decisión**: no se agrega infraestructura nueva. Se documenta que un 502/timeout por arranque en frío es recuperable.

**Por qué**: MercadoPago reintenta las notificaciones no confirmadas con backoff, y el endpoint es idempotente — un reintento sobre un pago ya acreditado devuelve `{"ok": true, "idempotent": true}` sin efecto. Un servicio de ping periódico a `/health` es una mitigación conocida (ya anotada en `CLAUDE.md`) pero es una decisión de infraestructura del PO, no de este change.

**Trade-off aceptado**: la acreditación puede demorar minutos en el peor caso en vez de segundos. Para un upgrade de plan es tolerable; se avisa en la UI de éxito del checkout.

### D7 — La verificación de firma no se toca en este change (y por qué eso es deliberado)

**Decisión**: `verify_mp_signature` (`backend/services/payments.py:22`) queda como está.

**Contexto que hay que dejar escrito**: la documentación de MercadoPago especifica que el `id` del template firmado sale del **query param `data.id` de la URL de notificación**, y que **si es alfanumérico debe pasarse a minúsculas**. La implementación actual lo lee del **cuerpo** y no normaliza a minúsculas. Para `type=payment` las dos lecturas coinciden —los IDs de pago son numéricos y MP manda el mismo valor en query y en body— por eso funciona hoy y por eso no se toca en un change CRÍTICO donde el cambio no arregla nada observable.

**Dónde deja de ser cierto**: los IDs de `preapproval` **son alfanuméricos**. `mp-real-subscriptions` tiene que corregir ambos puntos (leer el query param, bajar a minúsculas) o las notificaciones de suscripción van a fallar la firma de forma sistemática. Queda anotado acá para que ese change no lo descubra en producción.

## Risks / Trade-offs

- **[Riesgo] El secreto HMAC de Render no coincide con el del panel de MP** → el backend rechaza todo con 400 y el síntoma es idéntico al bug actual. **Mitigación**: verificación previa al cutover [MANUAL PO] por presencia de la variable y por un pago de prueba que valide firma; el spec exige además que el log distinga "falta configuración" de "firma inválida" para que el diagnóstico sea inmediato. **Nunca se imprime ni se compara el valor del secreto.**

- **[Riesgo] Existe además una URL de webhook configurada a nivel panel** (*Tus integraciones → Webhooks*), que notifica con independencia de la `notification_url` de cada preferencia → podría seguir apuntando al frontend. **Mitigación**: OQ2, verificación [MANUAL PO] en el panel. El reenviador cubre este caso aunque no se toque, lo cual es otra razón para no borrarlo apurado.

- **[Riesgo] Doble acreditación si una notificación llega por los dos caminos** → **Mitigación**: la idempotencia por `mercadopago_payment_id` ya existe y está cubierta por escenario de spec. No es un riesgo nuevo introducido por este change; es la propiedad que lo hace seguro.

- **[Riesgo] `NEXT_PUBLIC_BACKEND_URL` mal poblada en Vercel producción** → se emitirían preferencias notificando a una URL inválida. **Mitigación**: guard fail-closed (500 al crear la preferencia) — un checkout que no abre es un fallo ruidoso y reversible; un pago que no acredita es silencioso y cuesta plata.

- **[Trade-off] Un salto de red extra** (MP → Vercel → Render) para el tráfico viejo, con el cold start de Render sumándose. Aceptado: es tráfico decreciente por definición y la idempotencia lo hace reintentables.

- **[Riesgo] El pago E2E de verificación mueve dinero real** → **Mitigación**: es tarea **[MANUAL PO]** exclusivamente. El agente no crea, dispara ni simula pagos reales bajo ninguna circunstancia. Si hay credenciales de test de MercadoPago disponibles, la verificación se hace primero en sandbox.

## Migration Plan

**Fase 0 — Preparación (sin efecto en producción)**
1. Verificar `MERCADOPAGO_WEBHOOK_SECRET` y `MERCADOPAGO_ACCESS_TOKEN` presentes en Render [MANUAL PO].
2. Verificar `NEXT_PUBLIC_BACKEND_URL` poblada en Vercel producción.
3. Revisar la config de webhooks del panel de MP (OQ2) [MANUAL PO].

**Fase 1 — Reenviador (cierra el caso de las preferencias en vuelo)**
4. Convertir el route legacy en reenviador. Deploy.
5. A partir de acá, **toda** notificación —vieja o nueva— llega al backend.

**Fase 2 — Ruta directa (elimina el salto extra para lo nuevo)**
6. Cambiar `notification_url` a la URL del backend + guard fail-closed. Deploy.
7. Las preferencias nuevas notifican directo.

**Fase 3 — Verificación**
8. Pago real de verificación [MANUAL PO] → confirmar `accounts.billing_plan`, fila en `billing_events`, fila en `email_logs`, todo sin tocar nada a mano.

**Fase 4 — Retiro [MANUAL PO, condicionado a D5]**
9. Con las dos condiciones cumplidas, eliminar el route legacy y sus tests.

**Rollback**
- Fase 2 → revertir la constante de `notification_url`; el reenviador (Fase 1) sigue cubriendo todo. Rollback sin pérdida.
- Fase 1 → revertir al handler anterior devuelve al estado roto conocido; solo tiene sentido si el reenviador introdujera un fallo peor. Ningún dato se pierde: MercadoPago conserva los pagos y son reconciliables a mano como se hizo en junio.
- Sin migraciones de base de datos → no hay rollback de esquema.

## Open Questions

- **OQ1 — Duración de la ventana de convivencia y destino final del reenviador.** ¿Cuántos días con cero reenvíos antes de retirarlo? ¿O se deja permanente como red de seguridad barata (unas 30 líneas sin estado)? *Opciones*: (a) 30 días y retirar; (b) 90 días y retirar; (c) dejarlo indefinidamente y solo documentarlo. **Recomendación**: (a) — es el orden de magnitud de un ciclo de facturación mensual, así que cualquier preferencia en vuelo razonable ya venció. **Decide el PO.**

- **OQ2 — ¿Hay una URL de webhook configurada a nivel de aplicación en el panel de MercadoPago**, además de la `notification_url` por preferencia? Si existe y apunta al frontend, hay que re-apuntarla al backend. **Requiere que el PO mire el panel** (el agente no tiene acceso). No bloquea las Fases 1-2; sí bloquea la Fase 4.
