## Context

`captcha-token-freshness` (archivado 2026-08-13) dejó el ciclo de frescura resuelto en la capa canónica:

- `frontend/lib/captcha-freshness.ts` — `isTokenStale`, `isCaptchaError`, `submitWithFreshCaptcha` (guard de edad + reintento único), `CAPTCHA_MAX_TOKEN_AGE_MS` (120 s) y `CAPTCHA_REFRESH_TIMEOUT_MS` (10 s).
- `frontend/components/auth/CaptchaWidget.tsx` — handle `{ reset, isStale, refresh }`, `mintedAt` en un ref, auto-renovación al volver la pestaña a visible (notifica vía `onExpire`, D3) y stub local de Playwright exento (D5).

Las 4 pantallas (`app/auth/login`, `app/auth/register`, `app/auth/forgot-password`, `components/auth/MagicLinkForm`) repiten hoy el mismo cableado a mano: `useState("")` para el token, `onVerify/onExpire/onError`, `disabled={isLoading || !captchaToken}` y un `catch` que hace `captchaRef.current?.reset(); setCaptchaToken("")`.

El gap reportado por el PO: cuando el token se limpia por renovación, el botón pasa a `disabled` **sin ningún cambio visible**. El usuario clickea y no ocurre nada. No es un bug de lógica sino de comunicación, y de que el click se pierde en vez de esperar.

Restricciones vigentes: alcance congelado por el PO (dominio auth, governance CRÍTICO); prohibido tocar `auth-context`, middleware, idle-logout y configuración server-side de Turnstile; el stub de Playwright debe seguir viendo el comportamiento actual (D5); TDD estricto; nunca `any`.

## Goals / Non-Goals

**Goals:**

- Que el usuario siempre sepa por qué el botón no responde durante una renovación de captcha.
- Que un click hecho durante la renovación no se pierda: se envía solo, una vez, apenas hay token fresco.
- Una sola implementación consumida por las 4 superficies (regla de reutilización antes que repetición).
- Cero regresión funcional en la política de frescura ya validada en producción, y cero impacto sobre la suite E2E con stub.

**Non-Goals:**

- Cambiar la política de frescura, el umbral de edad, el timeout o el reintento único.
- Tocar `auth-context`, middleware, idle-logout o la configuración de Turnstile.
- Agregar pantallas, rutas o entradas de menú (el change no tiene superficie frontend nueva; cambia el feedback de pantallas existentes).
- Automatizar la verificación del flujo idle real de producción (queda como gate manual del PO).

## Decisions

### D1 — El estado de renovación se **deriva**, sin props nuevas en `CaptchaWidget`

**Decisión:** hay renovación en curso cuando el formulario **tuvo** un token y ahora no lo tiene. `CaptchaWidget` no expone nada nuevo: cada camino que invalida un token (auto-renovación por visibilidad D3, expiración propia de Turnstile, error del widget, o `reset()` del `catch` tras un rechazo) ya notifica al consumidor por `onExpire`/`onError`, y en los cuatro casos el widget **ya relanzó el challenge**, así que un token nuevo está en camino.

**Alternativas descartadas:**

- *Prop `onRenewalStart`*: agrega una quinta prop al widget y obliga a cada pantalla a un estado extra, para transmitir información que el consumidor ya puede deducir de los callbacks que cablea hoy. Más superficie, cero información nueva. Es además la misma razón por la que `captcha-token-freshness` reutilizó `onExpire` en vez de agregar una prop de frescura.
- *Estado dentro del handle (`isRenewing()`)*: un método imperativo no re-renderiza; el botón necesita re-render para cambiar de rótulo.

**Consecuencia clave:** el arranque en frío (montaje, todavía sin primer token) **no** es renovación. Ahí el botón conserva el `disabled` real de hoy y su rótulo normal — que es lo que la suite E2E y los tests actuales esperan.

### D2 — Durante la renovación el botón usa `aria-disabled`, no `disabled`

Un `<button disabled>` no emite eventos de click, así que sería imposible encolar la intención. Durante la renovación el botón queda:

- `aria-disabled="true"` (los lectores de pantalla lo anuncian deshabilitado),
- con estilo apagado (mismo tratamiento visual que el estado deshabilitado, vía las clases del design system),
- con rótulo `CAPTCHA_RENEWAL_LABEL` = "Renovando verificación…",
- pero **clickeable**, y su click encola en vez de enviar.

Esto cumple "deshabilitado pero explicado" del alcance aprobado sin cerrar la puerta a la cola. Es además el patrón recomendado por WAI para controles que deben explicar por qué no responden.

Los otros estados NO cambian: con submit en vuelo (`isLoading`) el botón sigue con `disabled` real (no hay nada que encolar, y es el guard anti-doble-submit más simple); en arranque en frío sin token, `disabled` real.

### D3 — La cola vive en una máquina de estados **pura**, en la capa canónica

`frontend/lib/captcha-freshness.ts` gana el rótulo compartido y un reducer puro sin React ni timers propios, del estilo:

```ts
type CaptchaGatePhase = "cold" | "ready" | "renewing" | "queued"
```

- `cold`: nunca hubo token → botón `disabled`, rótulo normal.
- `ready`: hay token → comportamiento actual.
- `renewing`: hubo token y se perdió → `aria-disabled`, rótulo de renovación.
- `queued`: `renewing` + el usuario clickeó → mismo rótulo; al llegar el token se dispara el submit.

Las transiciones (`tokenIssued`, `tokenLost`, `submitRequested`, `queueExpired`, `queueAborted`, `submitStarted`, `submitSettled`) se testean como funciones puras con vitest, sin `renderHook` ni fake timers. Sólo el hook que la envuelve maneja `setTimeout`.

**Alternativa descartada:** poner los booleanos sueltos (`isRenewing`, `hasQueuedSubmit`) directo en el hook. Se probó mentalmente y se descartó: los estados inválidos (`queued` sin `renewing`, `queued` durante `isLoading`) quedan representables y hay que defenderlos con `if` dispersos. Con una fase única son inalcanzables por construcción.

### D4 — Semántica de la cola (una sola intención, expira, no dispara doble submit)

1. **A lo sumo una intención.** Un segundo click en fase `queued` es un no-op: la intención ya registrada sigue en pie. No hay contador ni multiplicidad.
2. **Se dispara exactamente una vez.** Al llegar el primer token fresco (`onVerify`), la cola se limpia **antes** de invocar el submit, así que un segundo `onVerify` (p. ej. el widget re-emite) no puede disparar un segundo envío.
3. **Vencimiento.** La cola expira a `CAPTCHA_REFRESH_TIMEOUT_MS` (10 s, la constante que ya existe — no se agrega ninguna). Al vencer, la fase vuelve a `renewing`, se descarta la intención y se avisa al usuario ("No pudimos renovar la verificación. Probá de nuevo."). El usuario nunca queda esperando indefinidamente.
4. **Error del widget descarta la cola.** Un `onError` mientras hay cola la aborta y surface del error: el widget falló, no hay token en camino y esperar 10 s sería mentirle al usuario. Un `onExpire` mientras hay cola, en cambio, **mantiene** la cola: significa "sigo renovando", que es exactamente lo que la cola espera.
5. **Anti-doble-submit.** Con un submit en vuelo (`isLoading`) no se encola nada: el botón tiene `disabled` real (D2) y, además, la transición `submitRequested` desde una fase con submit en vuelo es un no-op en el reducer. Doble red.
6. **El submit encolado atraviesa `submitWithFreshCaptcha`.** No se llama a Supabase por un camino paralelo: la cola sólo decide *cuándo* se dispara el mismo submit de siempre, con el guard de edad y el reintento único intactos.
7. **Desmontaje.** El hook limpia el timer de la cola en su cleanup; una pantalla desmontada no dispara submits.

### D5 — El pegamento vive en un hook de auth; el helper canónico queda framework-free

- `frontend/lib/captcha-freshness.ts`: rótulo + reducer puro. **No** se le agrega React: el archivo lo importa `CaptchaWidget` y se testea como lógica pura.
- `frontend/hooks/auth/use-captcha-gate.ts` (nuevo, siguiendo la convención kebab-case de `frontend/hooks/auth/`): estado del token, fase, timer de la cola, `ref` al widget y `submit(run)` que delega en `submitWithFreshCaptcha`. Devuelve lo que las 4 pantallas necesitan: `captchaRef`, `captchaProps` (`onVerify`/`onExpire`/`onError` listos para esparcir), `token`, `phase`, `isRenewing`, `submitButtonProps` (`disabled` / `aria-disabled` / `onClick`) y `statusMessage`.
- Cada pantalla conserva **su** rótulo ("Iniciar sesión", "Crear cuenta", "Enviar enlace mágico", "Enviar instrucciones") y sólo lo intercambia por `CAPTCHA_RENEWAL_LABEL` cuando `isRenewing`. El hook no decide copy por pantalla.

### D6 — Anuncio accesible por una región compartida

El cambio de texto dentro de un botón no enfocado no se anuncia. Se agrega `frontend/components/auth/CaptchaRenewalStatus.tsx` (~10 líneas): `<span role="status" aria-live="polite" className="sr-only">{message}</span>`, renderizado por las 4 pantallas con el `statusMessage` del hook. Vive en un componente y no inline porque son 4 usos idénticos y el contrato de accesibilidad debe quedar en un solo lugar (regla de reutilización). `aria-live="polite"` y no `assertive`: es información de contexto, no una alerta que deba interrumpir.

### D7 — El stub local de Playwright queda exento por construcción

Con el stub activo, `onVerify` dispara con el token del stub al montar y **nada** lo invalida: `isStale()` es siempre `false`, `refresh()` resuelve al instante y no hay listener de visibilidad. La fase salta `cold → ready` y no vuelve a salir de `ready`. Sin `renewing` no hay rótulo nuevo, ni `aria-disabled`, ni cola. La suite E2E ve el mismo botón de hoy. No se agrega ninguna rama `if (isLocalPlaywright)` nueva: la exención se hereda de D5 del change anterior.

### D8 — Determinismo de los tests

El reducer se testea puro (sin timers). El hook y las pantallas se testean con fake timers de vitest para el vencimiento de la cola; ninguna aserción usa `new Date()` sin argumento ni depende del reloj real, en línea con `isTokenStale(mintedAt, now)`, que ya recibe `now` explícito.

## Risks / Trade-offs

- **`aria-disabled` en vez de `disabled` puede confundir a un usuario de teclado** (el botón sigue siendo enfocable y "clickeable" mientras se anuncia deshabilitado) → mitigación: el rótulo dice exactamente qué está pasando y la región `aria-live` lo anuncia; el click no se ignora, se encola, así que la acción del usuario se cumple igual. El estado dura los segundos que tarda Turnstile.
- **Una cola que se dispara sola puede sorprender** (el usuario clickea, se va a otra pestaña y el login ocurre igual) → mitigación: es exactamente la intención que expresó al clickear, el disparo es único y expira a los 10 s.
- **Riesgo de doble submit si el reducer se cablea mal** → mitigación: la cola se limpia antes de invocar el submit (D4.2), `submitRequested` es no-op con submit en vuelo (D4.5), y hay un test dedicado de "dos tokens seguidos ⇒ un solo submit".
- **Regresión sobre un camino ya validado en producción** (`captcha-token-freshness` cerró un incidente real) → mitigación: safety net obligatorio — los 6 archivos de test de captcha corren y quedan en verde **antes** de tocar nada, y `submitWithFreshCaptcha` no cambia de firma ni de comportamiento.
- **4 pantallas migrando a un hook común pueden divergir en el copy** → mitigación: el rótulo de renovación es una constante exportada; el copy propio de cada pantalla queda intacto.
- **Verificación del idle real (días de inactividad) no automatizable** → gate manual del PO en producción; prohibido abrir el Browser pane contra `/auth/login` de producción (cuelga el proceso).

## Migration Plan

Sin migraciones de datos ni cambios de contrato. Despliegue por PR único a `main` (CI: vitest + Playwright + Vercel). Rollback = revertir el PR: la capa canónica anterior queda intacta y las pantallas vuelven a su cableado previo sin ningún estado persistido que limpiar.

## Open Questions

- **OQ-1 (PO, no bloqueante)**: ¿el rótulo definitivo es "Renovando verificación…" o prefiere otro copy? Se implementa con esa constante y cambiarla es una línea.
- **OQ-2 (PO, gate manual)**: validación del flujo idle real (login tras días de inactividad) en producción, incluyendo que el segundo click ya no se pierda.
