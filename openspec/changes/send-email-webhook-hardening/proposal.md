## Why

La Edge Function pública `send-email` es hoy un **relay de correo abierto**. Corre con `verify_jwt = false` (obligatorio: la invoca `pg_net` desde un trigger de base de datos, que no tiene JWT de usuario) y **no valida absolutamente nada sobre el origen de la request**. El repositorio es público y la URL del proyecto es derivable del bundle del cliente, así que cualquier persona en internet puede hacer:

```
POST https://<project-ref>.supabase.co/functions/v1/send-email
{"type":"INSERT","table":"email_logs","record":{"id":"<uuid>","status":"pending",
  "recipient":"victima@ejemplo.com","subject":"...","event_type":"welcome"}}
```

…y Resend entrega un email **brandeado con el layout de ALIADATA desde `no-reply@aliadata.com.ar`**. Eso habilita phishing con el dominio propio, quema de cuota de Resend y daño a la reputación de envío del dominio. Severidad **alta**.

El segundo problema, que comparte causa raíz, es que la migración `20260628000003_email_webhook_prod.sql` crea el trigger `on_email_log_insert` con la **URL de producción hardcodeada**. Toda base que aplique las migraciones del repo —la DB efímera de CI (`supabase db reset` del job `validate-kpis`, en cada PR y cada push), la integración GitHub de Supabase, el proyecto de preview— queda con un trigger que **dispara contra producción**. Los gates de comportamiento de las migraciones corren justamente cuando `accounts` está vacía (es decir, en toda DB no-prod) y siembran usuarios sintéticos; cada uno de ellos hace que `handle_new_user` inserte dos filas en `email_logs` y por lo tanto dos POST a la función de prod.

Eso es lo que se observó el 2026-07-31: **ráfagas de ~40-45 POST → HTTP 400** contra `send-email` de prod a las 20:40, 20:57, 21:04 y 21:18 UTC, una ráfaga por cada evento de CI del repositorio. La investigación descartó que salieran de la DB de prod (`net._http_response` de prod: 360 requests hoy, todos 200, todos del cron `relay-process-pending-cae`) y del frontend (ningún llamado a `send-email`). El flujo real de prod funciona: `email_logs` tiene 4 filas hoy, todas `sent`.

Las ráfagas no enviaron mail porque terminaron en 400, pero eso es **suerte, no diseño**: el 400 llega por validaciones de forma del payload. Un payload bien formado —el que cualquiera puede construir leyendo el repo público— llega hasta Resend.

## What Changes

- **Autenticación del webhook por secreto compartido.** El trigger pasa a enviar un header `x-webhook-secret`; `send-email` lo exige y responde **401** sin él o con valor incorrecto, **antes** de parsear el payload y antes de cualquier llamada a Resend. Cierra el relay abierto y, de paso, las ráfagas foráneas: una DB de CI sin el secreto no puede hacerse pasar por prod.
- **Guard de entorno en el trigger.** La URL destino y el secreto se leen de **Supabase Vault** en vez de estar hardcodeados. Si cualquiera de los dos falta —CI, previews, local— el trigger **no dispara** (no-op observable vía `RAISE NOTICE`). Un solo mecanismo resuelve el relay abierto y el cross-environment.
- **Se elimina la URL de producción hardcodeada** de la definición del trigger.
- **Corte temprano en el trigger**: si la fila insertada no tiene `status = 'pending'`, no se emite HTTP (hoy se emite y la función responde 400).
- **Módulo compartido puro y testeable** `supabase/functions/_shared/webhook-auth.ts` con la verificación del secreto (comparación en tiempo constante), sin `Deno.*` en scope de módulo, importable desde vitest — patrón D6 de `billing-edge-effective-plan`.
- **Gates SQL** embebidos en la migración: estructurales siempre; de comportamiento solo con `accounts` vacía.
- **NO BREAKING** para el flujo real: en prod, con el secreto configurado, el comportamiento observable de los emails es idéntico.

## Capabilities

### New Capabilities

- `transactional-email-delivery`: el camino de entrega de correo transaccional `email_logs` → trigger `on_email_log_insert` → Edge Function `send-email` → Resend. Cubre la autenticación del webhook, el guard de entorno, el origen de configuración (Vault) y la actualización de estado de `email_logs`. Hoy **no existe ninguna spec** que gobierne este camino: las capabilities que mencionan `email_logs` (`branch-stock`, `payment-gateway`, `payment-webhook`, `transactional-outbox`, `trial-lifecycle`) solo describen *productores* que insertan filas, ninguna describe la entrega ni su control de acceso.

### Modified Capabilities

Ninguna. El camino de entrega está hoy sin especificar, así que todo el contenido normativo es nuevo. Los productores de `email_logs` no cambian su contrato: siguen insertando filas igual que antes.

> El traslado del destinatario hardcodeado `danielsevilla@alia-data.com` (dentro de `handle_new_user`, capability `user-registration`) a configuración se evalúa en **OQ4** y queda **fuera de alcance por defecto** — ver `design.md` §D7. El guard de entorno ya neutraliza la fuga cross-environment que ese hardcode podría causar.

## Impact

**Código afectado**

| Archivo | Cambio |
|---|---|
| `supabase/migrations/<nuevo>_send_email_webhook_hardening.sql` | Reescribe `public.send_email_log_webhook()`: lee URL + secreto de Vault, guard de entorno, corte por `status`, header `x-webhook-secret`. Recrea el trigger. Gates SQL. |
| `supabase/functions/send-email/index.ts` | Exige el header antes de todo lo demás; 401 si falta o no coincide; 503 si la función no tiene el secreto configurado. |
| `supabase/functions/_shared/webhook-auth.ts` | **Nuevo.** Verificación pura e inyectable del secreto. |
| `frontend/__tests__/send-email-webhook-auth.test.ts` | **Nuevo.** Cobertura vitest del módulo compartido. |

**Configuración fuera de banda (PO, antes del merge)**

- `vault.create_secret(<valor aleatorio>, 'send_email_webhook_secret', ...)` en el proyecto de prod.
- `vault.create_secret('https://<project-ref>.supabase.co', 'edge_functions_base_url', ...)`.
- Secret de Edge Functions `SEND_EMAIL_WEBHOOK_SECRET` con **el mismo valor**.

**Sistemas**

- `pg_net` y la extensión `vault` — ambos ya en uso en prod por el relay de CAE (`20260719000001`), no se agregan dependencias nuevas.
- El pipeline de `deploy.yml` aplica `db push` **antes** de `functions deploy` en el mismo job, así que el orden seguro (trigger empieza a mandar el header → función empieza a exigirlo) es automático en un único PR.

**Fuera de alcance explícito**

Migrar `send-email` a otro proveedor; tocar los templates HTML; el backlog viejo de `email_logs` en `pending`; el resto de las Edge Functions; el fan-out `recipient = 'all_users'` (riesgo documentado en `design.md` §Risks, decisión en OQ3).
