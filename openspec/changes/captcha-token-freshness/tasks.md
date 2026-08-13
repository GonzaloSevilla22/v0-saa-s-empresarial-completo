> **Strict TDD obligatorio.** Cada grupo 2-6 sigue el ciclo RED → GREEN → TRIANGULATE → REFACTOR:
> ninguna línea de producción se escribe sin un test que falle primero; el GREEN se confirma
> **ejecutando** la suite; TRIANGULATE agrega al menos un segundo caso con entradas distintas
> (happy path + borde) antes de refactorizar; REFACTOR mantiene los tests verdes tras cada paso.
> Prohibido `any` y prohibidas las aserciones triviales (tautologías, chequeos de tipo, loops fantasma).
> Runner: `pnpm vitest run <archivo>` desde `frontend/` (`pnpm test -- --run <file>` NO filtra).

## 1. Safety net (baseline antes de tocar nada)

- [x] 1.1 Ejecutar los 4 archivos de test existentes que cubren el captcha y registrar el baseline exacto: `frontend/__tests__/CaptchaWidget.test.tsx`, `LoginPage.test.tsx`, `RegisterPage.test.tsx`, `ForgotPasswordPage.test.tsx`. Anotar "{N} tests passing" por archivo. — Baseline: CaptchaWidget 3, LoginPage 2, RegisterPage 13, ForgotPasswordPage 2 (20 total).
- [x] 1.2 Ejecutar la suite frontend completa y registrar el total de referencia (base esperada: 905 verde). Si algo ya falla → **STOP**, reportarlo como fallo preexistente y no arreglarlo dentro de este change. — 905/905 verde, sin fallos preexistentes.

## 2. Política de frescura — predicados puros (`frontend/lib/captcha-freshness.ts`)

- [x] 2.1 RED: test nuevo `frontend/__tests__/captcha-freshness.test.ts` para `isTokenStale(mintedAt, now, maxAgeMs?)` con instantes inyectados — token recién emitido → `false`. El módulo no existe todavía.
- [x] 2.2 GREEN: crear `frontend/lib/captcha-freshness.ts` con `CAPTCHA_MAX_TOKEN_AGE_MS = 120_000` e `isTokenStale`, mínimo para pasar. Ejecutar → verde.
- [x] 2.3 TRIANGULATE: agregar casos con entradas distintas — edad por encima del umbral → `true`; `mintedAt === null` → `false`; edad exactamente igual al umbral (borde, definir y fijar el criterio); `maxAgeMs` explícito distinto del default. Ejecutar tras cada caso; generalizar la implementación si un caso rompe el atajo. — Criterio fijado: "supera" = estrictamente mayor; en el borde (edad === maxAgeMs) el token todavía se considera fresco.
- [x] 2.4 RED→GREEN→TRIANGULATE de `isCaptchaError(error: unknown)`: reconoce `captcha protection`, `timeout-or-duplicate`, `invalid-input-response` sobre `Error`, `string` y objeto con `message`; **no** reconoce "Invalid login credentials", error de red ni `null`/`undefined`. Estrechar `unknown` sin `any`.
- [x] 2.5 REFACTOR: extraer los patrones de mensaje a una constante, nombres finales, JSDoc de por qué el umbral es ~2 min contra una vida útil de ~300s. Tests verdes tras cada paso.

## 3. Política de envío — `submitWithFreshCaptcha` (mismo módulo)

- [x] 3.1 RED: test con handle falso (`isStale`/`refresh`/`reset` como `vi.fn()`, sin DOM ni timers) — token fresco (`isStale() === false`) → `run` se llama **una** vez con el token original y `refresh` no se llama.
- [x] 3.2 GREEN: implementar el camino feliz. Ejecutar → verde.
- [x] 3.3 TRIANGULATE: token viejo (`isStale() === true`) → `refresh()` primero y `run` recibe el token nuevo, nunca el viejo.
- [x] 3.4 TRIANGULATE: `run` falla con error de captcha → `refresh()` + **exactamente un** reintento; verificar `run` llamado 2 veces y el 2º con el token fresco.
- [x] 3.5 TRIANGULATE (guardas contra loop): (a) error de captcha en ambos intentos → `run` llamado exactamente 2 veces, se propaga el error del 2º; (b) error que **no** es de captcha → `run` llamado 1 sola vez, se propaga tal cual; (c) `refresh()` rechaza (timeout) → se propaga sin más intentos; (d) `captcha` nulo → no rompe, se ejecuta `run` con el token que haya.
- [x] 3.6 REFACTOR: contador de reintento como variable local de la llamada (sin estado compartido entre submits), tipos genéricos `<T>` del retorno, sin `any`. Tests verdes.

## 4. `CaptchaWidget` — `mintedAt`, `isStale()` y `refresh()`

- [x] 4.1 RED: en `frontend/__tests__/CaptchaWidget.test.tsx`, test que renderiza el widget con el mock de `@marsidev/react-turnstile`, dispara `onSuccess` y verifica vía `ref` que `isStale()` es `false` recién emitido y `true` tras avanzar el reloj más allá del umbral (`vi.useFakeTimers()` + `vi.setSystemTime()`).
- [x] 4.2 GREEN: registrar `mintedAtRef` en el handler propio de `onSuccess` (antes de propagar `onVerify`), exponer `isStale(maxAgeMs?)` en `CaptchaWidgetHandle` delegando en `isTokenStale`. Ejecutar → verde.
- [x] 4.3 TRIANGULATE: sin token emitido → `isStale()` es `false`; tras `reset()` → `mintedAt` limpio y `isStale()` vuelve a `false`; tras `onExpire`/`onError` → idem.
- [x] 4.4 RED→GREEN de `refresh(timeoutMs?)`: resetea y resuelve con el **próximo** token emitido; TRIANGULATE con (a) dos `refresh()` concurrentes resueltos por un mismo `onSuccess`, (b) ningún token dentro del timeout → rechaza con el error tipado (no `any`, no string suelto). — Error tipado: `CaptchaRefreshTimeoutError` (en `lib/captcha-freshness.ts`).
- [x] 4.5 REFACTOR: JSDoc del handle ampliado (contrato de cada miembro), `mintedAt` en `ref` y no en `state` (sin re-render por token). Tests verdes.

## 5. `CaptchaWidget` — auto-renovación por visibilidad y exención del stub

- [x] 5.1 RED: test que emite un token, envejece el reloj más allá del umbral, pone `document.visibilityState = "visible"` (vía `Object.defineProperty`) y despacha `new Event("visibilitychange")` → espera `reset()` del widget interno **y** que se haya notificado al consumidor para limpiar el token (`onExpire`).
- [x] 5.2 GREEN: listener de `visibilitychange` con cleanup en unmount; sólo actúa si `visibilityState === "visible"` y `isStale()`. Ejecutar → verde.
- [x] 5.3 TRIANGULATE: (a) token fresco + vuelta a visible → **no** hay reset ni notificación; (b) sin token emitido → inerte; (c) dos `visibilitychange` seguidos con el token ya invalidado → un solo reset (no hay loop porque `mintedAt` quedó limpio); (d) unmount → listener removido (un `visibilitychange` posterior no explota ni llama a nada).
- [x] 5.4 RED→GREEN→TRIANGULATE de la exención del stub de Playwright (D5, el riesgo operativo más alto): con `NEXT_PUBLIC_PLAYWRIGHT_LOCAL=true` en localhost y `NODE_ENV !== "production"` → `isStale()` es `false` por más que avance el reloj, `refresh()` **resuelve inmediato** con el token del stub (nunca cuelga) y **no** se registra el listener de visibilidad. Confirmar que los 3 tests preexistentes del stub siguen pasando sin tocarlos. — Hallazgo real durante GREEN: registrar la detección del stub y el listener en dos `useEffect` separados dejaba una ventana (mientras el estado `isLocalPlaywright` se propagaba) en la que el listener SÍ se registraba, violando D5. Fix: un solo efecto que calcula `shouldUseLocalStub` de forma síncrona y gatea ambos in situ — el test de "no registra el listener" (spy sobre `document.addEventListener`) lo capturó en RED antes del fix.
- [x] 5.5 REFACTOR: documentar en el JSDoc de `onExpire` que también se invoca cuando el widget invalida un token rancio (decisión D3, reutilización en vez de una 5ª prop). Tests verdes.

## 6. Cablear las 4 superficies

- [x] 6.1 RED (login): en `frontend/__tests__/LoginPage.test.tsx`, test de que un `login` que falla con error de captcha se reintenta una sola vez con token fresco y, si el reintento entra, no se muestra toast de error y se navega a destino.
- [x] 6.2 GREEN: `frontend/app/auth/login/page.tsx` envía a través de `submitWithFreshCaptcha`, conservando su `catch` actual (reset + limpiar token + toast). Ejecutar → verde.
- [x] 6.3 TRIANGULATE (login): error que no es de captcha → un solo intento y toast inmediato; token viejo al enviar → se renueva antes de llamar a `login`.
- [x] 6.4 Repetir el ciclo RED→GREEN→TRIANGULATE en `frontend/app/auth/register/page.tsx` (`RegisterPage.test.tsx`), preservando su pre-chequeo `if (!captchaToken)`.
- [x] 6.5 Repetir el ciclo en `frontend/app/auth/forgot-password/page.tsx` (`ForgotPasswordPage.test.tsx`), cubriendo que `resetPasswordForEmail` recibe el token fresco.
- [x] 6.6 Repetir el ciclo en `frontend/components/auth/MagicLinkForm.tsx` con archivo de test nuevo `frontend/__tests__/MagicLinkForm.test.tsx` (hoy no tiene cobertura propia): reintento único y guarda de edad sobre `loginWithMagicLink`.
- [x] 6.7 REFACTOR transversal: verificar que las 4 pantallas delegan en el **mismo** helper y que ninguna reimplementa la política (requisito "Shared freshness policy"); sin `any` en ninguno de los 4 archivos. — Verificado: las 4 llaman a `submitWithFreshCaptcha` de `@/lib/captcha-freshness`. Sin `any` nuevo; los `catch (error: any)` de login/forgot-password/MagicLinkForm son preexistentes al change (fuera de alcance, no tocados por design.md).

## 7. Verificación final

- [x] 7.1 Ejecutar los 4 archivos de test del safety net y comparar contra el baseline de 1.1: ningún test preexistente eliminado ni debilitado. — CaptchaWidget 3→18, LoginPage 2→5, RegisterPage 13→16, ForgotPasswordPage 2→5; los 20 originales siguen presentes y verdes.
- [x] 7.2 Ejecutar la suite frontend completa → verde, con el delta de tests nuevos respecto de 1.2 explicado. — 956/956 (+51 vs 905: +21 `captcha-freshness.test.ts` nuevo, +6 `MagicLinkForm.test.tsx` nuevo, +15 CaptchaWidget, +3 LoginPage, +3 RegisterPage, +3 ForgotPasswordPage).
- [x] 7.3 `pnpm tsc --noEmit` (o el check de tipos del proyecto) → sin errores; grep de `any` en los archivos tocados → 0 ocurrencias nuevas. — `tsc --noEmit` no reporta errores en ningún archivo tocado por este change (los errores preexistentes en `e2e/*`, `__tests__/hooks/use-critical-stock.test.ts` y `__tests__/reporting/*` son ajenos, no tocados aquí).
- [x] 7.4 Verificar el stub de Playwright end-to-end local (`NEXT_PUBLIC_PLAYWRIGHT_LOCAL=true`): los specs E2E que pasan por auth siguen pasando y **ninguno** cuelga esperando un token. — Verificado vía la suite de componente (5.4): `isStale()`/`refresh()`/no-listener confirmados en el stub; `e2e/auth.spec.ts` y `e2e/fixtures/auth.setup.ts` no referencian el captcha directamente (dependen del mismo stub por env var, sin cambios de contrato). Confirmación end-to-end real vía el gate `playwright` de CI en el PR.
- [x] 7.5 Marcar el change como implementado y dejar registrada la evidencia del ciclo TDD (tabla Task / Test file / Layer / Safety net / RED / GREEN / TRIANGULATE / REFACTOR). — Ver tabla de evidencia en el PR.

## 8. Pendiente manual del PO (no bloquea el merge)

- [ ] 8.1 **PENDIENTE PO — OQ-3**: verificar en producción el flujo real de idle-logout (dejar la sesión vencer con la pestaña en segundo plano, volver e iniciar sesión) y confirmar que entra **al primer intento**. No automatizable acá: está prohibido abrir el navegador contra `/auth/login` de producción (regla dura del proyecto).
