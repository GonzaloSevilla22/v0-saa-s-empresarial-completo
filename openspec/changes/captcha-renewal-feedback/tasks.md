> **Strict TDD obligatorio.** Cada grupo de implementación sigue RED → GREEN → TRIANGULATE → REFACTOR y ejecuta los tests en cada gate. Tests deterministas: fake timers de vitest, nunca `new Date()` sin argumento. Nunca `any`. Sin superficie frontend nueva (cambia el feedback de 4 pantallas existentes).

## 1. Safety net (antes de tocar una sola línea)

- [x] 1.1 Ejecutar los 6 archivos de test de captcha existentes y registrar el baseline exacto (`pnpm vitest run frontend/__tests__/captcha-freshness.test.ts frontend/__tests__/CaptchaWidget.test.tsx frontend/__tests__/LoginPage.test.tsx frontend/__tests__/RegisterPage.test.tsx frontend/__tests__/ForgotPasswordPage.test.tsx frontend/__tests__/MagicLinkForm.test.tsx`); anotar "N/N passing" — **71/71 passing**
- [x] 1.2 Si algún test falla en el baseline: DETENER y reportarlo como fallo preexistente al orquestador — no arreglarlo dentro de este change — **sin fallos preexistentes**
- [x] 1.3 Registrar el total de la suite frontend completa (~1018) como referencia para el cierre — **baseline: 1053/1071 passing** (18 fallos preexistentes en 2 archivos ajenos a captcha, ej. `SuscripcionesAmbiguasPage.test.tsx`; no se tocan, fuera de alcance)

## 2. Reducer puro de la compuerta de captcha (`frontend/lib/captcha-freshness.ts`)

- [x] 2.1 RED — test del reducer: fase inicial `cold`; `tokenIssued` lleva `cold → ready`. Referenciar exportaciones que todavía no existen (`CAPTCHA_RENEWAL_LABEL`, `captchaGateReducer`, tipos `CaptchaGatePhase` / `CaptchaGateEvent`)
- [x] 2.2 GREEN — implementar el mínimo: tipo de fase, evento `tokenIssued`, `CAPTCHA_RENEWAL_LABEL = "Renovando verificación…"`. Sin React, sin timers en este archivo (D5)
- [x] 2.3 TRIANGULATE — cubrir todas las transiciones del D3/D4 con casos distintos: `tokenLost` desde `ready` → `renewing`; `tokenLost` desde `cold` → sigue `cold` (arranque en frío no es renovación); `submitRequested` en `renewing` → `queued`; `submitRequested` repetido en `queued` → no-op; `submitRequested` en `ready` → no encola; `submitRequested` con submit en vuelo → no-op; `tokenIssued` en `queued` → `ready` + señal "disparar submit" una sola vez; `tokenIssued` otra vez → sin segunda señal; `queueExpired` → `renewing` sin disparo; `queueAborted` (error de widget) → `renewing` sin disparo; `tokenLost` en `queued` → sigue `queued` (D4.6)
- [x] 2.4 TRIANGULATE — verificar por test que los estados inválidos son inalcanzables (`queued` sin renovación previa, `queued` con submit en vuelo)
- [x] 2.5 REFACTOR — nombres, exhaustividad del `switch` sobre el union de eventos, JSDoc en español consistente con el resto del archivo; re-ejecutar tests
- [x] 2.6 Verificar que `isTokenStale`, `isCaptchaError`, `submitWithFreshCaptcha` y las constantes existentes no cambiaron de firma ni de comportamiento (sus tests siguen verdes sin editarlos)

## 3. Hook compartido `frontend/hooks/auth/use-captcha-gate.ts`

- [x] 3.1 RED — test del hook (`renderHook` + fake timers): al montar expone fase `cold`, `disabled: true`, sin `aria-disabled` y sin `statusMessage`
- [x] 3.2 GREEN — implementar el hook mínimo: estado de token, fase vía el reducer, `captchaRef`, `captchaProps` (`onVerify`/`onExpire`/`onError`)
- [x] 3.3 TRIANGULATE — token emitido → `ready`, `disabled: false`; `onExpire` tras un token → `renewing`, `aria-disabled: true`, `statusMessage` no vacío; `onError` tras un token → `renewing`
- [x] 3.4 TRIANGULATE — `submit(run)` delega en `submitWithFreshCaptcha` (guard de edad + reintento único intactos) y expone `isLoading`; el `catch` resetea el widget, limpia el token y deja la fase en `renewing` (D2/D4.6)
- [x] 3.5 TRIANGULATE — cola: click en `renewing` no llama a `run`; al emitirse el token fresco `run` se llama exactamente una vez; dos tokens seguidos ⇒ un solo `run`; clicks repetidos ⇒ un solo `run`
- [x] 3.6 TRIANGULATE — vencimiento con fake timers: avanzar `CAPTCHA_REFRESH_TIMEOUT_MS` sin token ⇒ `run` nunca se llama, se surface el error de renovación fallida y la fase vuelve a `renewing`; un token que llega después del vencimiento no dispara nada
- [x] 3.7 TRIANGULATE — `onError` con cola pendiente ⇒ cola abortada y error surfaceado sin esperar el timeout; `onExpire` con cola pendiente ⇒ cola viva
- [x] 3.8 TRIANGULATE — anti-doble-submit: click con submit en vuelo ⇒ no encola ni dispara un segundo `run`
- [x] 3.9 TRIANGULATE — desmontar con cola pendiente ⇒ el timer se limpia y no se dispara ningún submit (sin warnings de act/estado tras unmount)
- [x] 3.10 REFACTOR — tipar el retorno con una interfaz explícita exportada (nunca `any`), estabilizar identidades con `useCallback`/`useMemo` donde evite re-renders del widget, exportar el hook desde `frontend/hooks/auth/index.ts` siguiendo la convención del directorio; re-ejecutar tests

## 4. Región accesible compartida `frontend/components/auth/CaptchaRenewalStatus.tsx`

- [x] 4.1 RED — test: con mensaje vacío no anuncia nada; con mensaje renderiza un nodo con `role="status"` y `aria-live="polite"` que contiene el texto
- [x] 4.2 GREEN — componente mínimo (~10 líneas) con clase `sr-only`, prop `message: string` tipada
- [x] 4.3 TRIANGULATE — cambiar el mensaje actualiza el contenido de la misma región (no se remonta, para que el lector de pantalla lo anuncie)
- [x] 4.4 REFACTOR — JSDoc explicando por qué existe (D6) y re-ejecutar tests

## 5. Migración de las 4 superficies

- [x] 5.1 RED — en `LoginPage.test.tsx`: tras `onExpire` con token previo, el botón muestra "Renovando verificación…" y `aria-disabled="true"`; un click en ese estado no llama a `login` y sí lo llama una vez al llegar el token fresco
- [x] 5.2 GREEN — migrar `frontend/app/auth/login/page.tsx` al hook: reemplazar `useState`/`useRef`/`handleSubmit` propios por `useCaptchaGate`, montar `CaptchaRenewalStatus`, aplicar `submitButtonProps` y el intercambio de rótulo ("Iniciar sesión" ↔ `CAPTCHA_RENEWAL_LABEL`). Preservar `data-testid="login-submit"` y el copy existente
- [x] 5.3 TRIANGULATE — repetir los tests RED equivalentes para registro (`RegisterPage.test.tsx`, rótulo "Crear cuenta") y migrar `frontend/app/auth/register/page.tsx` preservando su guard `if (!captchaToken)` y el resto de su validación — la guarda pasó a `captchaGate.phase === "cold"` (equivalente semántico: sólo bloquea si el captcha nunca se resolvió; durante una renovación el submit se encola en vez de bloquearse)
- [x] 5.4 TRIANGULATE — ídem para recuperación de contraseña (`ForgotPasswordPage.test.tsx`) y migrar `frontend/app/auth/forgot-password/page.tsx`
- [x] 5.5 TRIANGULATE — ídem para `MagicLinkForm.test.tsx` (rótulo "Enviar enlace mágico", guard `!email` y estado `isSuccess` intactos) y migrar `frontend/components/auth/MagicLinkForm.tsx`
- [x] 5.6 TRIANGULATE — test en al menos una pantalla de que el arranque en frío (sin token nunca emitido) conserva `disabled` real y el rótulo normal, sin anuncio de renovación
- [x] 5.7 REFACTOR — verificar que ninguna de las 4 pantallas conserva lógica de captcha duplicada (grep de `captchaToken`, `setCaptchaToken`, `submitWithFreshCaptcha` fuera de la capa canónica) y que `CaptchaWidget.tsx` no ganó props nuevas (D1); re-ejecutar tests

## 6. Verificación y cierre

- [ ] 6.1 Ejecutar los 6 archivos del safety net: 0 regresiones respecto del baseline de 1.1
- [ ] 6.2 Ejecutar la suite frontend completa y comparar con el total de 1.3
- [ ] 6.3 `pnpm tsc --noEmit` (o el gate de tipos del proyecto) sin errores y sin un solo `any` introducido
- [ ] 6.4 Verificar que la suite Playwright E2E de auth pasa sin cambios: con el stub local la fase nunca sale de `ready` (D7) — no se agregó ninguna rama nueva de stub
- [ ] 6.5 Verificación visual manual del estado de renovación en las 4 pantallas: desktop + mobile, tema claro + oscuro, usando tokens semánticos del design system (nada hardcodeado)
- [ ] 6.6 Registrar como PENDIENTE PO la validación del flujo idle real en producción (OQ-2 del design) — prohibido abrir el Browser pane contra `/auth/login` de producción
- [ ] 6.7 Confirmar el copy final del rótulo con el PO (OQ-1); si cambia, es una sola constante
