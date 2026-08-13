## Context

`CaptchaWidget` (Cloudflare Turnstile vía `@marsidev/react-turnstile`) es el único punto de emisión de tokens de captcha del producto y lo consumen 4 superficies: `/auth/login`, `/auth/register`, `/auth/forgot-password` y `MagicLinkForm`. Las 4 lo cablean igual: `onVerify={setCaptchaToken}`, `onExpire`/`onError` limpian el token, el botón de envío se deshabilita con `!captchaToken` y el `catch` del submit hace `captchaRef.current?.reset()`.

Ese cableado asume que **el token del estado es válido mientras exista**. La asunción se rompe en un solo escenario: el idle-logout redirige a `/auth/login?reason=idle` con la pestaña en segundo plano. El widget se monta, Turnstile resuelve solo, emite el token — y ahí queda. Los timers internos del widget (y el `onExpire` que dependería de ellos) no corren de forma confiable en una pestaña suspendida, así que el token envejece más allá de los ~300s de vida útil sin que nadie lo note. El usuario vuelve, el botón está habilitado, envía, y Cloudflare devuelve `timeout-or-duplicate`. El `catch` resetea, por eso el 2º intento entra: el bug es de **frescura**, no de validación.

Restricciones que enmarcan el diseño:

- Dominio auth, gobernanza CRÍTICA: alcance congelado a la frescura del token en el cliente. No se toca `auth-context`, middleware, el flujo de idle-logout ni la configuración server-side de Supabase/Turnstile.
- Regla de reutilización del proyecto: la política de frescura se resuelve **una vez**, no cuatro.
- Prohibido `any`. El stub local de Playwright (`NEXT_PUBLIC_PLAYWRIGHT_LOCAL`) debe seguir funcionando idéntico. Tests deterministas con vitest/jsdom.

## Goals / Non-Goals

**Goals:**

- Que al volver a una pestaña donde el token envejeció haya un token **fresco** esperando, sin acción del usuario.
- Que un token viejo nunca llegue a Supabase: se renueva antes de enviar.
- Que un rechazo de captcha se recupere solo, **una vez**, sin que el usuario vea un error que no cometió.
- Que las 4 superficies hereden el arreglo desde una implementación compartida.

**Non-Goals:**

- Cambiar la vida útil del token, el modo del widget o cualquier parámetro server-side de Turnstile/Supabase.
- Tocar el idle-logout, su temporizador o su redirección (sólo se consume su efecto).
- Reintentar errores que no sean de captcha (credenciales, red, rate limit): esos siguen mostrándose tal cual, al primer intento.
- Agregar pantallas, rutas o entradas de menú. Este change no tiene superficie frontend nueva.

## Decisions

### D1 — `mintedAt` vive dentro de `CaptchaWidget`, en un `ref`

El instante de emisión se registra en el mismo lugar donde se emite el token: un `useRef<number | null>` que se setea en el handler de `onSuccess` (antes de propagar `onVerify`) y se limpia en `reset()`, en `onExpire` y en `onError`.

- **Por qué el widget y no cada pantalla**: es el único que sabe cuándo nació el token. Si el dato viviera en el consumidor habría que replicarlo 4 veces y mantenerlo sincronizado con 3 callbacks; exactamente la duplicación que la regla del proyecto prohíbe.
- **Por qué `ref` y no `state`**: la edad no se pinta; usar estado provocaría un re-render por token sin ningún beneficio.
- **Alternativa descartada**: entregar `{ token, mintedAt }` en `onVerify`. Rompe la firma que usan las 4 pantallas (`onVerify={setCaptchaToken}`) y los tests existentes, y obliga a cada consumidor a guardar y comparar tiempos. Se descarta por costo y por duplicación.

### D2 — La edad se consulta por el handle; `onVerify` conserva su firma

`CaptchaWidgetHandle` pasa de `{ reset }` a:

| Miembro | Contrato |
|---|---|
| `reset(): void` | Igual que hoy: re-lanza el challenge. Además limpia `mintedAt`. |
| `isStale(maxAgeMs?: number): boolean` | `true` sólo si hay un token emitido y su edad supera el umbral. Sin token emitido → `false` (el botón ya está deshabilitado por `!captchaToken`; no hay nada viejo que renovar). |
| `refresh(timeoutMs?: number): Promise<string>` | Resetea y resuelve con el **próximo** token emitido. Rechaza si no llega dentro del timeout. |

`refresh()` es la pieza que hace posible el reintento sin máquinas de estado en las pantallas: el consumidor `await`ea el token nuevo dentro del mismo `handleSubmit` en vez de armar un efecto "cuando llegue el token, reenviá". Internamente mantiene una lista de `resolve` pendientes que el handler de `onSuccess` drena; el timeout rechaza con un error tipado propio.

- **Alternativa descartada**: una prop `onFreshToken` + flag `pendingRetry` en cada consumidor. Reintroduce la lógica en las 4 pantallas y hace el flujo dependiente del orden de renders.

### D3 — Auto-renovación por `visibilitychange`, dentro del widget

`CaptchaWidget` registra un listener de `visibilitychange` (con cleanup en unmount). Al pasar a `visible`, si `isStale()` → `reset()` + notificación al consumidor para que limpie el token viejo.

- **Umbral**: `CAPTCHA_MAX_TOKEN_AGE_MS = 120_000` (2 min) contra una vida útil real de ~300s. Margen ~2,5× para cubrir el tiempo entre la renovación y el submit real del usuario, sin resetear en cada alt-tab corto.
- **Notificación al consumidor: se reutiliza `onExpire`**. Las 4 superficies ya lo cablean a `setCaptchaToken("")`, que es exactamente el efecto buscado (botón deshabilitado el instante que dura el re-challenge, imposible enviar el token muerto). Agregar una 5ª prop `onStaleReset` obligaría a cablear lo mismo 4 veces para el mismo efecto. Semánticamente es honesto: el widget está declarando que el token dejó de servir. Queda documentado en el JSDoc de la prop.
- **Sin loop posible**: `reset()` limpia `mintedAt`, y sin `mintedAt` `isStale()` es `false`. Un segundo `visibilitychange` antes de que llegue el token nuevo no dispara nada.

### D4 — La política de envío vive en un helper puro compartido

Módulo nuevo `frontend/lib/captcha-freshness.ts` (capa canónica, mismo criterio que `lib/product-stock.ts`):

- `CAPTCHA_MAX_TOKEN_AGE_MS` — umbral único, consumido por el widget y por el helper.
- `isTokenStale(mintedAt: number | null, now: number, maxAgeMs?: number): boolean` — predicado **puro con `now` explícito**. El widget lo llama con `Date.now()`; los tests lo ejercitan con instantes inyectados, sin timers.
- `isCaptchaError(error: unknown): boolean` — reconoce el rechazo de captcha por el mensaje de Supabase (`captcha protection`, `timeout-or-duplicate`, `invalid-input-response`), estrechando `unknown` sin `any` (soporta `Error`, `string` y objetos con `message`).
- `submitWithFreshCaptcha<T>({ captcha, token, run }): Promise<T>` — la política completa:
  1. Si `captcha.isStale()` → `token = await captcha.refresh()`.
  2. `run(token)`.
  3. Si falla **y** `isCaptchaError(error)` **y** todavía no se reintentó → `token = await captcha.refresh()` y `run(token)` **una sola vez**.
  4. Cualquier otro error, o el fallo del reintento (incluido el timeout de `refresh`), se propaga al `catch` del consumidor tal como hoy.

El contador de reintentos es una variable local de la llamada: no hay estado compartido entre submits, y no existe forma de encadenar dos reintentos.

- **Por qué una función y no un hook**: no necesita estado de React, y como función pura respecto del handle inyectado se testea con un handle falso — determinismo total, sin `render`.
- **Los consumidores no pierden su `catch`**: siguen haciendo `reset()` + limpiar token + toast. El helper sólo intercala la política de frescura.

### D5 — El stub de Playwright cortocircuita la frescura

En modo stub (`NEXT_PUBLIC_PLAYWRIGHT_LOCAL` + `NODE_ENV !== "production"` + localhost) no hay widget real: `reset()` no re-emite nada. Por lo tanto, en ese modo:

- `isStale()` devuelve **siempre `false`** (el token del stub no caduca),
- `refresh()` resuelve **inmediatamente** con el token del stub,
- no se registra el listener de `visibilitychange`.

Sin esto, `refresh()` esperaría un `onSuccess` que jamás llega y colgaría los E2E hasta el timeout. Es la decisión de mayor riesgo operativo del change y por eso tiene test propio.

### D6 — Determinismo de los tests

- Predicado puro (`isTokenStale`) → instantes inyectados como argumento.
- Widget → `vi.useFakeTimers()` + `vi.setSystemTime()` para envejecer el token, `Object.defineProperty(document, "visibilityState", …)` + `document.dispatchEvent(new Event("visibilitychange"))` para simular el regreso a la pestaña.
- Helper de envío → handle falso (`isStale`/`refresh`/`reset` como `vi.fn()`), sin DOM ni timers.
- Pantallas → mock de `@marsidev/react-turnstile` como ya hace `CaptchaWidget.test.tsx`.

## Risks / Trade-offs

- **El challenge exige interacción del usuario (modo managed) → `refresh()` no resuelve** → el timeout rechaza y el usuario ve el error normal con el widget listo para resolver: el mismo comportamiento que hoy, nunca peor. El timeout debe ser corto (orden de segundos) para no dejar el botón en "cargando".
- **Ventana con el botón deshabilitado durante la renovación** → dura lo que tarda el re-challenge no interactivo (típicamente <1s) y ocurre mientras el usuario recién vuelve a la pestaña, antes de tipear. Se acepta: es preferible a un token muerto con botón habilitado.
- **Reutilizar `onExpire` para el auto-reset mezcla dos causas** (expiración de Turnstile vs. rancio por visibilidad) → los 4 consumidores hacen lo mismo en ambos casos, así que hoy no hay diferencia observable; se documenta en el JSDoc. Si alguna vez hiciera falta distinguirlas, se agrega la prop entonces (Regla de Tres).
- **El umbral de 2 min es una heurística** contra una vida útil de ~300s que Cloudflare puede cambiar → vive en una constante única exportada; ajustarla es una línea.
- **Un token puede envejecer sin que la pestaña cambie de visibilidad** (usuario mirando la pantalla 6 minutos sin enviar) → cubierto por la guarda de edad al enviar (D4.1), que no depende de eventos de visibilidad.
- **Riesgo de regresión en los E2E de Playwright** → mitigado por D5 y su test dedicado.

## Migration Plan

Cambio puramente cliente: sin migraciones, sin backend, sin variables de entorno nuevas. Despliega con el merge (Vercel). Rollback = revert del PR; el comportamiento previo (reset en el `catch`) queda intacto por debajo, así que el revert no deja estados a medias.

## Open Questions

- **OQ-1 (fuera de alcance, sólo anotada)**: el idle-logout redirige a login con la pestaña en segundo plano, lo que dispara un challenge de Turnstile que ningún usuario está mirando y que se descarta al volver. Diferir el montaje del widget hasta que la página sea visible ahorraría ese challenge, pero toca la composición de la pantalla de login y el flujo de idle-logout → **no se incluye en este change**; queda para evaluación del PO.
- **OQ-2 (fuera de alcance, sólo anotada)**: `onExpire` y `onError` están cableados idénticos en las 4 superficies (`setCaptchaToken("")`); podrían colapsarse en un default del propio widget. Es un refactor de ergonomía sin efecto en el bug → no se incluye.
- **OQ-3 (verificación manual, PENDIENTE PO)**: reproducir el flujo real de idle-logout en producción (esperar el cierre por inactividad con la pestaña en segundo plano, volver y loguear al primer intento). No es automatizable acá: está **prohibido abrir el navegador contra `/auth/login` de producción** (regla dura del proyecto).
- **OQ-4**: valor definitivo del timeout de `refresh()`. Se parte de un valor conservador del orden de 8-10s; si en producción se observan timeouts espurios, se ajusta la constante.
