## Context

### Estado actual del camino de entrega

```
productor (trigger/backend) → INSERT public.email_logs
      → trigger AFTER INSERT on_email_log_insert
      → public.send_email_log_webhook()   [SECURITY DEFINER]
      → net.http_post(URL_DE_PROD_HARDCODEADA, body = {type,table,record})
      → Edge Function send-email  [verify_jwt = false, sin validación de origen]
      → Resend  (from: ALIADATA <no-reply@aliadata.com.ar>)
      → UPDATE email_logs SET status = 'sent' | 'partial' | 'failed' WHERE id = record.id
```

Definiciones vigentes:

- `supabase/migrations/20260628000003_email_webhook_prod.sql` — el trigger y su función; URL de prod literal en el cuerpo.
- `supabase/functions/send-email/index.ts` — la función; 325 líneas, 12 plantillas por `event_type`.
- `supabase/config.toml:438-443` — `[functions.send-email] verify_jwt = false`.

### Las dos superficies del mismo defecto

**(1) Relay abierto.** `send-email` no verifica nada sobre quién la llama. Sus cuatro respuestas 400 (JSON inválido; `type`/`table` distintos de `INSERT`/`email_logs`; `record.status !== 'pending'`; "All emails failed") son validaciones de **forma del payload**, no de **origen**. Un payload bien formado llega a Resend. El repo es público, así que la forma exacta del payload es de lectura libre.

Detalle relevante para el modelo de amenaza: cuando todos los envíos fallan, la función hace `UPDATE email_logs ... WHERE id = <id del payload>`. Con un `id` inventado el UPDATE afecta 0 filas y **no deja ningún rastro en la base**. Un atacante que use UUIDs al azar es invisible desde `email_logs`; solo aparece en los logs de la Edge Function.

**(2) Cross-environment.** La URL hardcodeada convierte a cualquier base que aplique las migraciones del repo en un cliente de la función de prod. La DB efímera de CI corre `supabase db reset` en cada PR y cada push; los gates de comportamiento de las migraciones corren **exactamente cuando `accounts` está vacía**, que es toda base no-prod, y siembran usuarios sintéticos vía `auth.users`. Cada usuario sintético dispara `handle_new_user`, que inserta **dos** filas en `email_logs` (`welcome` al usuario + `new_user_admin_notice` a la casilla real del administrador). De ahí las ráfagas de ~40-45 POST correlacionadas 1:1 con eventos de CI.

Ambas superficies tienen la misma raíz: **no hay ninguna prueba de que quien llama sea el trigger de producción**. Un único mecanismo —un secreto compartido que solo prod posee— las cierra a las dos. Eso ordena todo el diseño.

### Restricción central

`verify_jwt` **no puede activarse**. El llamador es `pg_net` desde un trigger de base de datos: no hay sesión de usuario ni JWT que enviar. Además `deploy.yml:63` despliega con `supabase functions deploy --no-verify-jwt`, que lo fuerza globalmente. La autenticación tiene que ser propia, a nivel de aplicación.

### Precedente que ya existe en el repo

`20260719000001_c27_cae_relay_trigger.sql` resolvió **el mismo problema** para el relay de CAE: `pg_cron` → backend en Render. Su solución es una función `SECURITY DEFINER` que lee secreto y URL de `vault.decrypted_secrets`, y si falta cualquiera de los dos **registra un WARNING y retorna sin hacer la llamada HTTP**. El secreto se crea fuera de banda por el PO; la migración nunca lo contiene.

Ese patrón resuelve las dos superficies de este change y ya está probado en producción. Reutilizarlo, en vez de inventar un mecanismo nuevo, es la decisión de diseño más importante de este documento.

## Goals / Non-Goals

**Goals:**

- Que `send-email` rechace toda request que no provenga del trigger de producción, antes de parsear el payload y antes de tocar Resend.
- Que ninguna base no-prod (CI, previews, local) pueda emitir tráfico hacia la función de prod.
- Que la URL de destino deje de estar hardcodeada en una migración de un repo público.
- Que el comportamiento observable del correo en prod sea **idéntico** al actual una vez configurado el secreto.
- Que la lógica de verificación quede cubierta por tests en el runner que el repo ya tiene.

**Non-Goals:**

- Cambiar de proveedor de correo, tocar plantillas HTML o el layout de marca.
- Reprocesar el backlog histórico de `email_logs` en `pending`.
- Endurecer otras Edge Functions (`ai-*`, `generate-export`, `invoice-ocr`). Comparten el modelo `verify_jwt=false`, pero validan el JWT del usuario en el header `Authorization`; `send-email` es la única sin ninguna verificación.
- Rotación automática de secretos, rate limiting, o alertas sobre intentos rechazados.
- Corregir el fan-out `recipient = 'all_users'` (riesgo documentado abajo; decisión en OQ3).

## Decisions

### D1 — Supabase Vault como origen del secreto y de la URL

**Decisión:** reutilizar literalmente el patrón de `rpc_trigger_cae_relay()`. Dos secretos en Vault, creados fuera de banda por el PO:

| Nombre | Contenido |
|---|---|
| `send_email_webhook_secret` | valor aleatorio (`openssl rand -hex 32`) |
| `edge_functions_base_url` | `https://<project-ref>.supabase.co` |

La función del trigger es `SECURITY DEFINER` y las lee de `vault.decrypted_secrets`. La migración **nunca contiene los valores**.

**Alternativas consideradas:**

- **GUC de base de datos** (`ALTER DATABASE ... SET app.send_email_secret = '...'`). Descartada: el valor viaja en un `ALTER DATABASE` que o bien queda en la migración (repo público — inaceptable) o bien exige un paso manual equivalente al de Vault sin ganar nada. Además `current_setting()` sobre un GUC no está protegido por rol: cualquier sesión autenticada podría leerlo, mientras que `vault.decrypted_secrets` está restringido y el valor está cifrado en reposo.
- **Tabla de configuración propia** (`app_config(key, value)`). Descartada: reimplementa Vault peor. Necesitaría RLS estricta, cifrado propio y una política de acceso nueva; Vault ya es exactamente eso, es built-in de Supabase, y ya está instalado y en uso en esta base.
- **Hardcodear el secreto en la migración.** Inaceptable: el repo es público.

**Por qué Vault gana:** cifrado en reposo, sin exposición a roles de aplicación, cero dependencias nuevas, y **consistencia con el único otro trigger→HTTP autenticado del sistema**. Un solo patrón para "trigger de Postgres que llama a un endpoint autenticado" es más barato de operar que dos.

### D2 — El guard de entorno es el *mismo* chequeo que el guard de seguridad

**Decisión:** la función del trigger lee ambos secretos; si **cualquiera** es `NULL`, emite `RAISE NOTICE` y retorna sin llamar a `net.http_post`.

Esta es la pieza elegante del diseño: no hay una "detección de entorno" separada (nada de comparar `current_database()`, ni un flag `is_production`, ni una variable de entorno). **La posesión del secreto *es* la definición de producción.** Una base que no tiene el secreto no puede autenticarse contra la función aunque lo intentara, así que no tiene sentido que emita la request. Un mecanismo, dos problemas cerrados, sin estado redundante que pueda desincronizarse.

Consecuencia directa: en CI, previews y local el trigger queda instalado y es un no-op silencioso. Las ráfagas desaparecen desde la migración misma, **sin depender del deploy de la función**.

`RAISE NOTICE` y no `WARNING`: a diferencia del cron de CAE (una vez por minuto), este trigger corre **por fila insertada**. En un `db reset` de CI con decenas de usuarios sintéticos, `WARNING` inundaría la salida y podría confundirse con un fallo real. `NOTICE` mantiene la observabilidad sin ruido.

### D3 — Verificación en la función: fail-closed, con 401 y 503 distinguidos

**Decisión:** `send-email` compara el header `x-webhook-secret` contra `Deno.env.get('SEND_EMAIL_WEBHOOK_SECRET')`, **como primera operación del handler**, antes de `req.text()`.

Tres resultados distintos, deliberadamente:

| Situación | Respuesta | Razón |
|---|---|---|
| La función no tiene el secreto configurado | **503** `misconfigured` | Es un error de operación nuestro, no un ataque. Distinguirlo evita diagnosticar mal un deploy incompleto. |
| Header ausente o distinto | **401** `unauthorized` | Rechazo de origen. |
| Header correcto | continúa | — |

**Fail-closed y no fail-open:** si el secreto no está configurado la función rechaza todo (503) en vez de degradar al comportamiento actual. Un fail-open convierte un olvido de configuración en un relay abierto silencioso — exactamente el defecto que este change existe para eliminar. El precio es que una configuración incompleta rompe el correo de forma ruidosa y visible, que es la falla preferible.

**Comparación en tiempo constante:** la verificación usa comparación de longitud fija sobre los bytes, no `===` sobre strings. Sobre HTTPS y con un secreto de 256 bits el riesgo real de un ataque de temporización remoto es marginal, pero el costo de hacerlo bien es una función de cinco líneas y evita tener que justificar la excepción en cada auditoría futura.

**El rechazo no toca `email_logs`.** Un 401 no escribe nada en la base: la request rechazada nunca fue legítima, así que no hay fila propia que marcar. Esto además cierra el vector de "UPDATE con id ajeno" descrito en Context — sin header válido no se llega al `UPDATE`.

### D4 — El header, no el `Authorization` bearer

**Decisión:** header propio `x-webhook-secret`.

El relay de CAE usa `Authorization: Bearer <secreto>` porque su destino es FastAPI, donde ese header es idiomático. Acá el destino es una Edge Function detrás del gateway de Supabase, que **interpreta `Authorization` como su propio token de proyecto**. Enviar un secreto arbitrario ahí invita a que el gateway lo evalúe antes que nuestro código, con resultados dependientes de configuración (`verify_jwt`) en lugar de dependientes de nuestra lógica. Un header propio no tiene semántica para el gateway y llega intacto al handler.

### D5 — Módulo compartido puro para poder testear (patrón D6 de `billing-edge-effective-plan`)

**Decisión:** `supabase/functions/_shared/webhook-auth.ts` exporta la verificación como función pura e inyectable, **sin referencias a `Deno.*` en scope de módulo**:

```ts
export type WebhookAuthResult =
  | { ok: true }
  | { ok: false; status: 401 | 503; reason: "unauthorized" | "misconfigured" }

export function verifyWebhookSecret(
  provided: string | null,
  expected: string | undefined,
): WebhookAuthResult
```

`index.ts` queda como el único lugar que lee `Deno.env` y traduce el resultado a `Response`.

El repo **no tiene harness de Deno** (no hay `deno.json` de test, ni `*_test.ts` bajo `supabase/functions/`, ni `deno` en ninguno de los tres workflows). La convención vigente, fijada por `billing-edge-effective-plan` §D6, es **vitest desde `frontend/__tests__/` importando el archivo real por ruta relativa**; vitest resuelve con esbuild en runtime y no depende del `tsconfig` que excluye `supabase/`. La restricción de no usar `Deno.*` en scope de módulo es justamente lo que lo hace importable.

Se evita deliberadamente el antipatrón que documenta `frontend/__tests__/ai-precio.test.ts`: **re-declarar la lógica dentro del test**. Un test que copia la regla no detecta que la función divergió — y en una verificación de seguridad esa divergencia sería invisible hasta que alguien la explote.

### D6 — Corte temprano por `status` en el trigger

**Decisión:** el trigger no emite HTTP si `NEW.status IS DISTINCT FROM 'pending'`.

Hoy toda fila insertada genera un POST, y la función responde 400 para las que no están `pending`. Es tráfico y latencia por nada. El chequeo en origen es una línea y hace que el volumen de requests refleje el trabajo real. No cambia ningún comportamiento observable: esas requests ya no producían correo.

### D7 — Disciplina de alcance: el destinatario del aviso al admin queda fuera

`handle_new_user` inserta el `new_user_admin_notice` con `danielsevilla@alia-data.com` **literal en el cuerpo SQL** — el mismo defecto de hardcode que este change corrige para la URL. Aun así queda **fuera de alcance** (OQ4), por tres razones:

1. **El riesgo ya está cerrado por D2.** El daño concreto del hardcode era que bases no-prod le mandaran avisos espurios; con el guard, esas bases no emiten nada. Lo que queda es higiene, no exposición.
2. **El valor ya es público e irreversible.** Está en el historial de un repo público desde `20260628000002`. Moverlo a Vault hoy no lo despublica.
3. **El costo es desproporcionado al beneficio.** `handle_new_user` es governance CRÍTICO (camino de signup) y se mantiene por `CREATE OR REPLACE` encadenados: la versión vigente es `20260801000003`, que a su vez copia el cuerpo completo de `20260801000002`. Cambiar una constante obliga a re-emitir ~100 líneas de función crítica exactas, en un change cuyo objetivo es reducir superficie de riesgo. Introducir riesgo de regresión en el signup para higienizar un valor ya público es un mal intercambio.

Si el PO decide lo contrario (OQ4), es una tarea aditiva de bajo costo **en un change aparte**, no un bloqueante de este.

## Risks / Trade-offs

- **[Configuración incompleta corta todo el correo transaccional]** → Es el precio consciente del fail-closed (D3). Mitigación: el orden de despliegue lo hace improbable (Migration Plan), los tres resultados son distinguibles en logs (503 ≠ 401), y la tarea de verificación post-deploy comprueba un envío real antes de dar el change por cerrado. Rollback: revertir el deploy de la función restaura el comportamiento previo en minutos y el trigger sigue funcionando (manda un header de más, que la versión vieja ignora).

- **[Desincronización entre el valor de Vault y el de las Edge Functions]** → Son dos sistemas de configuración distintos que deben contener el mismo valor. Mitigación: se fijan en el mismo paso operativo antes del merge, y la verificación post-deploy detecta la desincronización de inmediato (todo 401). Documentado como procedimiento en tasks; la rotación futura exige el mismo cuidado (OQ2).

- **[El fan-out `recipient = 'all_users'` sigue siendo un multiplicador de daño]** → Los triggers de comunidad (`20250101000010`, `meeting_notice` / `pool_notice`) insertan filas con `recipient = 'all_users'`, y en ese caso la función hace `auth.admin.listUsers()` y envía a **todos los usuarios reales**. Tras este change ya no es alcanzable desde afuera (hace falta el secreto), así que deja de ser un vector de ataque y queda como riesgo de *accidente interno*: un `INSERT` equivocado en `email_logs` produce un envío masivo sin confirmación. Mitigación propuesta en OQ3 (allowlist de `event_type` que pueden usar el fan-out); no se implementa sin decisión del PO porque cambia comportamiento de producto.

- **[Un atacante que ya observó la ráfaga puede haber deducido la superficie]** → El diagnóstico no encontró evidencia de explotación (las 4 ráfagas se explican 1:1 por eventos de CI y todas terminaron en 400). No hay forma de descartarlo con certeza porque un envío exitoso desde un `id` inventado no deja rastro en `email_logs` (Context). Mitigación: el secreto se genera nuevo en este change, así que cualquier conocimiento previo de la superficie queda obsoleto al desplegarlo. Confirmación de si Resend llegó a entregar algo: OQ1.

- **[Vault agrega una lectura por fila insertada]** → `send_email_log_webhook()` hace dos `SELECT` sobre `vault.decrypted_secrets` por INSERT en `email_logs`. El volumen real es de unidades por día (4 filas hoy en prod) y el corte por `status` (D6) lo reduce más. Costo despreciable; no se agrega caché para no introducir estado que invalidar en una rotación.

## Migration Plan

**Orden obligatorio** — la propiedad que lo hace seguro es que el trigger empiece a **mandar** el header antes de que la función empiece a **exigirlo**. Un header de más es ignorado por la versión vieja de la función; un header de menos sería un 401 masivo.

1. **PO, fuera de banda, ANTES del merge** (sin esto el correo se corta al desplegar):
   - `SELECT vault.create_secret('<valor>', 'send_email_webhook_secret', '...')` en el proyecto de prod.
   - `SELECT vault.create_secret('https://<project-ref>.supabase.co', 'edge_functions_base_url', '...')`.
   - Secret de Edge Functions `SEND_EMAIL_WEBHOOK_SECRET` = **el mismo valor** (dashboard o `supabase secrets set`).
   - Verificar: `SELECT name FROM vault.secrets WHERE name IN ('send_email_webhook_secret','edge_functions_base_url');` → 2 filas.

2. **Merge a main.** `deploy.yml` corre `db push --include-all` (línea 60) y **después** `functions deploy` (línea 63) **en el mismo job**. El orden seguro es automático: entre ambos pasos el trigger ya manda el header y la función todavía no lo exige. No hace falta partir el change en dos PRs.

3. **Verificación post-deploy** (tasks §7): un `INSERT` real en `email_logs` termina en `status = 'sent'`; una request sin header a la URL pública devuelve 401; los logs de la función no muestran 503.

**Rollback:** re-desplegar la versión anterior de `send-email` (deja de exigir el header). La migración no necesita revertirse: sin la función que lo exige, el header extra es inocuo, y el guard de entorno es deseable de todos modos. Si hiciera falta revertir también el trigger, `20260628000003` es re-aplicable tal cual.

**Idempotencia:** el pipeline aplica las migraciones **dos veces por diseño** (integración GitHub de Supabase al mergear + `db push` de Actions). Todo el archivo usa `CREATE OR REPLACE FUNCTION` + `DROP TRIGGER IF EXISTS` + `CREATE TRIGGER`, sin efecto acumulativo. La migración **no** ejecuta `vault.create_secret` (fallaría en la segunda pasada por nombre duplicado, y obligaría a poner el valor en el repo).

## Open Questions

**OQ1 — ¿Resend llegó a entregar algo de las ráfagas?** ¿Recibió `danielsevilla@alia-data.com` avisos de "Nuevo registro en ALIADATA" con nombres sintéticos de CI (p. ej. "Sin nombre") el 2026-07-31 alrededor de 20:40, 20:57, 21:04 y 21:18 UTC?
*Recomendación:* revisar esa casilla y el dashboard de Resend antes del apply. El análisis dice que las ráfagas terminaron en 400 y por lo tanto **no** hubo envío; una confirmación negativa cierra el incidente, y una positiva cambiaría la severidad y obligaría a revisar reputación de dominio. No bloquea el diseño.

**OQ2 — Política de rotación del secreto.** ¿Con qué frecuencia se rota, y se acepta la micro-ventana de corte durante la rotación?
*Recomendación:* rotar solo ante sospecha de compromiso. Procedimiento sin corte: agregar el valor nuevo al secret de la función aceptando **dos** valores válidos transitoriamente, actualizar Vault, y quitar el viejo. Si esa complejidad no se justifica hoy, aceptar una ventana de segundos rotando primero la función y después Vault — con el correo transaccional en volumen de unidades por día, el impacto real es nulo. Decidir antes del apply solo si el PO quiere el soporte de dos valores desde el día uno (cambiaría la firma de `verifyWebhookSecret`).

**OQ3 — ¿Se restringe el fan-out `all_users`?** Hoy cualquier fila con `recipient = 'all_users'` envía a todos los usuarios reales.
*Recomendación:* sí, con una allowlist de `event_type` (`meeting_notice`, `pool_notice`) — es barato y convierte un envío masivo accidental en un no-op. Como cambia comportamiento de producto, no se implementa sin el sí explícito del PO. Si se aprueba, entra como tarea §6 de este mismo change; si no, queda registrado como riesgo aceptado.

**OQ4 — ¿Se mueve `danielsevilla@alia-data.com` a configuración?**
*Recomendación:* **no en este change** — ver D7. El riesgo real ya lo cierra el guard de entorno, el valor ya es público de forma irreversible, y tocar `handle_new_user` (signup, CRÍTICO) para higienizar una constante introduce riesgo de regresión desproporcionado. Si el PO lo quiere, proponerlo como change aparte junto con otra intervención sobre `handle_new_user`, para pagar una sola vez el costo de re-emitir la función.

**OQ5 — ¿Se endurece también el proyecto de preview (`pudaxiwqhwsxuaofsqda`)?** Es inaccesible desde el MCP actual, así que no se pudo verificar su estado.
*Recomendación:* no hace falta acción específica. Tras esta migración, ese proyecto queda sin los secretos en Vault y por lo tanto su trigger es un no-op: el guard de D2 lo cubre por construcción, sin necesidad de acceder a él. Confirmar de todos modos que no tenga secretos con esos nombres si en algún momento se recupera el acceso.
