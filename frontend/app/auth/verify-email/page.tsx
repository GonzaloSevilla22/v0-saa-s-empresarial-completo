"use client"

import { Suspense, useState, useEffect, useRef, useCallback } from "react"
import { useRouter, useSearchParams } from "next/navigation"
import Link from "next/link"
// auth-hardening-jwt-cookies (Parte C, D1 + D18, tasks 18.4d y 19.4b). Esta
// pantalla no le habla al proveedor desde el navegador: el reenvío corre en una
// acción de servidor y la detección de la verificación consulta
// `GET /api/auth/status`. Las cuatro operaciones que tenía acá
// (`refreshSession`, `getSession` ×2, `onAuthStateChange`) **lanzarían** con el
// cliente configurado con `accessToken` (`supabase-js/index.mjs:389`), así que la
// pantalla que mira todo usuario nuevo se quedaría en "Esperando confirmación…"
// para siempre. El cooldown de 30 s se conserva acá, donde estaba: es de
// experiencia.
import { fetchAuthStatus } from "@/lib/auth/session-status"
import { subscribeToSessionEvents } from "@/lib/auth/session-bus"
// H-5 (humo local del 2026-09-18): de acá sale la renovación FORZADA de la sesión
// de la app. Se destructura `refreshSession` a propósito: un `const auth =
// useAuth()` y después `auth.refreshSession()` dispararía el candado
// `__tests__/lib/no-browser-auth-calls.test.ts`, que barre por `auth.<operación>`.
import { useAuth } from "@/contexts/auth-context"
import { resendVerificationEmailAction } from "@/app/auth/actions"
import { unwrapAuthResult } from "@/lib/auth/auth-result"
import { Button } from "@/components/ui/button"
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card"
import { Mail, Loader2, CheckCircle2, RefreshCw } from "lucide-react"
import { toast } from "sonner"
// fix/auth-reenvio-verificacion-captcha: el proyecto real tiene Turnstile
// ACTIVO y GoTrue no exime a `/resend` de captcha (400 captcha_failed medido
// contra prod sin `captcha_token` — el botón fallaba SIEMPRE, invisible porque
// `/resend` tiene tráfico cero). Mismo patrón que las otras 4 pantallas de auth
// (login, registro, recuperación, enlace mágico): `useCaptchaGate` +
// `<CaptchaWidget>` es el ÚNICO camino de envío (regla del proyecto).
import { CaptchaWidget } from "@/components/auth/CaptchaWidget"
import { CaptchaRenewalStatus } from "@/components/auth/CaptchaRenewalStatus"
import { CAPTCHA_RENEWAL_LABEL } from "@/lib/captcha-freshness"
import { useCaptchaGate } from "@/hooks/auth"

// ─── Constants ────────────────────────────────────────────────────────────────

const RESEND_COOLDOWN = 30  // seconds before resend is allowed
const POLL_INTERVAL   = 4000 // ms between server checks
/** Cuánto se muestra el cartel de "Email verificado" antes de navegar. */
const SUCCESS_DWELL   = 1500 // ms
/**
 * Techo de espera de la renovación de la sesión antes de resolver por el destino
 * honesto.
 *
 * `fetchFromHandler()` pide el token **sin** `AbortSignal.timeout` ni watchdog
 * (`lib/auth/access-token-store.ts`), así que una petición colgada no resuelve
 * nunca. Sin este techo la navegación tampoco ocurre nunca y el estado verificado
 * —que no renderiza ningún link ni botón— deja al usuario sin salida, con el
 * spinner girando. Generoso a propósito: una renovación lenta que llega igual tiene
 * que ganarle al techo, porque su destino (`/dashboard`) es el bueno.
 */
const REFRESH_WATCHDOG = 8000 // ms

/** Los dos únicos destinos de esta pantalla una vez verificado el email. */
type Destination = "/dashboard" | "/auth/login"

// ─── Inner content (uses useSearchParams — must be inside Suspense) ───────────

function VerifyEmailContent() {
  const router      = useRouter()
  const params      = useSearchParams()
  const emailParam  = params.get("email") ?? ""
  const { refreshSession } = useAuth()
  const captchaGate = useCaptchaGate()

  // ── UI state ─────────────────────────────────────────────────────────────
  const [email,      setEmail]      = useState(emailParam)
  const [cooldown,   setCooldown]   = useState(RESEND_COOLDOWN)
  const [resending,  setResending]  = useState(false)
  const [checking,   setChecking]   = useState(false)
  const [verified,   setVerified]   = useState(false)
  /**
   * Adónde va esta pantalla una vez renovada la sesión. `null` mientras la
   * renovación está en vuelo: recién su resultado lo decide, y prometer un
   * dashboard al que no se va a llegar es una mentira que el usuario cobra.
   */
  const [destination, setDestination] = useState<Destination | null>(null)

  // ── Internal refs (don't cause re-renders) ────────────────────────────────
  const redirectingRef = useRef(false)
  const pollingRef     = useRef<ReturnType<typeof setInterval> | null>(null)
  /**
   * Si esta instancia sigue montada. El camino de éxito corre fuera de React (un
   * `async` suelto), y con H-5 su ventana pasó de los 1,5 s fijos del `setTimeout`
   * viejo a `max(1,5 s, lo que tarde la renovación)`: sin techo propio. Navegar o
   * tocar estado después de que el usuario se fue (botón atrás, enlace externo) es
   * secuestrarle la navegación.
   */
  const aliveRef  = useRef(true)
  /** Temporizadores del camino de éxito, para limpiarlos al desmontar. */
  const timersRef = useRef<ReturnType<typeof setTimeout>[]>([])

  // ── Helpers ───────────────────────────────────────────────────────────────

  // Se reafirma `true` en el montaje, no sólo en la inicialización del ref: en
  // StrictMode (dev) el efecto se limpia y se vuelve a ejecutar sobre la MISMA
  // instancia, y un `aliveRef` que sólo se apaga dejaría la pantalla sin navegar
  // nunca en desarrollo.
  useEffect(() => {
    aliveRef.current = true
    return () => {
      aliveRef.current = false
      timersRef.current.forEach(clearTimeout)
      timersRef.current = []
    }
  }, [])

  /** `setTimeout` cuyo id queda registrado para el desmontaje. */
  const scheduleTimer = useCallback((ms: number, onElapsed: () => void) => {
    timersRef.current.push(setTimeout(onElapsed, ms))
  }, [])

  // El `getSiteUrl()` que vivía acá se retiró con el reenvío: el
  // `emailRedirectTo` lo resuelve el servidor (`lib/auth/site-url.ts`).

  const stopPolling = useCallback(() => {
    if (pollingRef.current) {
      clearInterval(pollingRef.current)
      pollingRef.current = null
    }
  }, [])

  /**
   * Renueva la sesión de la app y decide adónde llevar.
   *
   * `refreshSession()` fuerza `refreshAccessToken()` y además vuelve a resolver
   * perfil, cuenta y plan: el dashboard se monta con el contexto ya poblado.
   *
   * **Una renovación que no se pudo confirmar no es una sesión viva.** Por contrato
   * `refreshSession()` no rechaza (captura todo adentro), pero si alguna vez lo
   * hiciera, dejar que el rechazo se propague deja la pantalla en "Email
   * verificado" **para siempre**, sin navegar nunca: el peor modo de falla posible
   * en la primerísima pantalla de una cuenta nueva. El destino del rechazo es el
   * mismo que el de "no hay sesión", por el mismo criterio con que
   * `refreshSession()` ya cuenta `unknown` como "no hay": mandar al dashboard a
   * alguien cuya sesión no se pudo confirmar es exactamente el síntoma H-5 que este
   * arreglo cierra.
   *
   * **Qué produce realmente el destino `/auth/login`** (las tres causas alcanzables;
   * la explicación "el enlace se abrió en otro dispositivo" que tenía este archivo
   * era falsa, y está corregida acá: sin cookie de sesión en este navegador,
   * `GET /api/auth/status` corta en `hasSessionCookie()` antes de preguntarle al
   * proveedor, así que nunca llega a informar `email_confirmed_at` y esta función no
   * se llama — ese caso se manifiesta como "Esperando confirmación…", que es otro
   * hueco, preexistente y ajeno a este arreglo):
   *
   *  1. `unknown` del manejador de token: hipo de red, 5xx, cuerpo ilegible.
   *  2. Sesión revocada o cortada por inactividad entre el sondeo y la renovación
   *     (`isIdleSession` en `GET /api/auth/token`, que además la revoca).
   *  3. El techo de espera de `REFRESH_WATCHDOG` (petición colgada).
   */
  const resolveDestination = useCallback(async (): Promise<Destination> => {
    try {
      return (await refreshSession()) ? "/dashboard" : "/auth/login"
    } catch (error) {
      console.error("[verify-email] no se pudo renovar la sesión:", error)
      return "/auth/login"
    }
  }, [refreshSession])

  // Called once verification is confirmed — show success then redirect
  //
  // H-5 (humo local del 2026-09-18). Acá había un `setTimeout(() =>
  // router.push("/dashboard"), 1500)` pelado, y ése era el defecto: esta pantalla es
  // —junto al login y al registro— uno de los puntos que SABEN que la sesión acaba
  // de nacer, y el store del access token cachea a propósito el estado "no hay
  // sesión" (regla 3 de `lib/auth/access-token-store.ts`). Sin forzar la renovación,
  // el primer render del dashboard de la cuenta nueva sale con la anon key:
  // "permission denied for function get_dashboard_financials" más cuatro 401.
  //
  // La renovación corre EN PARALELO con el cartel de éxito (no lo alarga), pero la
  // navegación espera a las dos cosas: si se navegara con la renovación en vuelo, el
  // arreglo no arreglaría nada.
  const handleVerified = useCallback(() => {
    if (redirectingRef.current) return
    redirectingRef.current = true
    stopPolling()
    setVerified(true)

    void (async () => {
      // El techo de espera: sin él, una renovación que no settlea nunca (petición
      // colgada, sin `AbortSignal` en el store) deja esta pantalla sin salida.
      const porTecho = new Promise<Destination>((resolve) => {
        scheduleTimer(REFRESH_WATCHDOG, () => resolve("/auth/login"))
      })
      const renovada = Promise.race([resolveDestination(), porTecho]).then((target) => {
        if (aliveRef.current) setDestination(target)
        return target
      })
      const [target] = await Promise.all([
        renovada,
        new Promise<void>((resolve) => scheduleTimer(SUCCESS_DWELL, resolve)),
      ])
      if (!aliveRef.current) return
      // Sin sesión viva en ESTE navegador el dashboard no puede leer nada: el destino
      // honesto es el login. La verificación igual ocurrió, y el cartel lo sigue
      // diciendo.
      router.push(target)
    })()
  }, [router, stopPolling, resolveDestination, scheduleTimer])

  // Core check: preguntarle al servidor por el estado REAL del email.
  //
  // `GET /api/auth/status` lee la cookie `HttpOnly` y consulta al proveedor, así
  // que ve el `email_confirmed_at` recién cambiado incluso cuando el enlace se
  // abrió en otro navegador — el caso que ni `getSession()` ni un refresh de esta
  // pestaña podían detectar. Nunca lanza: un fallo de red deja la pantalla
  // esperando, que es lo que el usuario está haciendo de todos modos.
  const checkVerification = useCallback(async () => {
    if (redirectingRef.current) return

    const status = await fetchAuthStatus()

    // El email puede no venir en la URL (p. ej. se llegó acá por el redirect del
    // middleware, no desde el registro). El servidor es el único que lo sabe.
    if (status.email) setEmail((current) => current || status.email!)

    if (status.email_confirmed_at) handleVerified()
  }, [handleVerified])

  // ── Effect 1: immediate check on mount (already verified?) ───────────────
  useEffect(() => {
    checkVerification()
  }, [checkVerification])

  // ── Effect 2: periodic polling ────────────────────────────────────────────
  //
  // Con el sondeo contra el servidor este es el mecanismo **principal** de
  // detección, no un respaldo: el `onAuthStateChange` que cumplía ese papel
  // desaparece con D1 (con `accessToken` configurado ni se instala,
  // `supabase-js/index.mjs:407`). La propagación entre pestañas la retoma el bus
  // de sesión, suscrito en el efecto 4.
  useEffect(() => {
    pollingRef.current = setInterval(checkVerification, POLL_INTERVAL)
    return stopPolling
  }, [checkVerification, stopPolling])

  // ── Effect 3: Page Visibility API — force re-check when tab regains focus ─
  useEffect(() => {
    const onVisible = () => {
      if (document.visibilityState === "visible") checkVerification()
    }
    document.addEventListener("visibilitychange", onVisible)
    return () => document.removeEventListener("visibilitychange", onVisible)
  }, [checkVerification])

  // ── Effect 4: bus de eventos de sesión (task 20.3) ────────────────────────
  //
  // Acá vivía la segunda de las dos suscripciones a `onAuthStateChange` del
  // proyecto (`:113` antes de este change). Su reemplazo es el bus: si el enlace
  // del email se abre en OTRA pestaña de este mismo navegador y esa pestaña
  // termina con sesión, el evento llega acá y la verificación se detecta **ya**,
  // sin esperar el próximo tic de 4 s. El sondeo sigue siendo el mecanismo
  // principal (D18); esto es lo que lo hace inmediato en el caso frecuente.
  //
  // Los mensajes del temporizador de inactividad (`activity`, `logout`) viajan por
  // el mismo transporte y NO llegan a este handler: el bus sólo reparte sus tipos
  // propios.
  useEffect(() => subscribeToSessionEvents(() => { void checkVerification() }), [checkVerification])

  // ── Effect 5: countdown timer ─────────────────────────────────────────────
  // Each render of this effect decrements cooldown by 1 after 1 second.
  // Setting cooldown to RESEND_COOLDOWN restarts it (used after resend).
  useEffect(() => {
    if (cooldown <= 0) return
    const t = setTimeout(() => setCooldown((c) => c - 1), 1000)
    return () => clearTimeout(t)
  }, [cooldown])

  // ── Resend handler ────────────────────────────────────────────────────────
  //
  // fix/auth-reenvio-verificacion-captcha: `captchaGate.submit` es el ÚNICO
  // camino de envío (regla del proyecto) — resuelve token viejo/renovación
  // igual que forgot-password/login, y el guard de `submitButtonProps.disabled`
  // (fase `cold` o submit en vuelo) evita disparar sin un token utilizable, en
  // la misma línea que el guard de cooldown/resending de acá abajo.
  async function handleResend() {
    if (!email || cooldown > 0 || resending || captchaGate.submitButtonProps.disabled) return

    setResending(true)
    try {
      await captchaGate.submit(async (token) => {
        unwrapAuthResult(await resendVerificationEmailAction({ email, captchaToken: token }))
      })
      // MAJOR 1 de la revisión adversarial: esta es la primera pantalla de
      // auth cuyo botón sobrevive a su propio éxito (las otras 4 desmontan el
      // form o navegan). Sin consumir el token ya usado, un 2º click dentro
      // de la ventana de frescura (~120s, muy por encima del cooldown de 30s)
      // reenviaría el MISMO token que Cloudflare ya gastó, y GoTrue
      // respondería `timeout-or-duplicate` — una petición condenada que
      // además gasta cupo del limiter de `/resend`.
      captchaGate.consumeToken()
      toast.success("Email reenviado. Revisá tu bandeja o spam.")
      setCooldown(RESEND_COOLDOWN) // restart countdown
    } catch (err: unknown) {
      const msg = err instanceof Error ? err.message : "Error al reenviar el email"
      toast.error(msg)
    } finally {
      setResending(false)
    }
  }

  // ── Manual check handler ──────────────────────────────────────────────────
  async function handleManualCheck() {
    if (checking || redirectingRef.current) return
    setChecking(true)
    await checkVerification()
    setChecking(false)
    // If we reach here without redirecting, email is still unverified
    if (!redirectingRef.current) {
      toast.info("Tu email aún no fue verificado. Revisá tu bandeja.")
    }
  }

  // ── Verified state ────────────────────────────────────────────────────────
  if (verified) {
    return (
      <div className="flex min-h-svh items-center justify-center bg-background p-4">
        <Card className="w-full max-w-md border-border bg-card text-center">
          <CardContent className="flex flex-col items-center gap-4 pt-8 pb-8">
            <div className="flex h-16 w-16 items-center justify-center rounded-full bg-emerald-500/10">
              <CheckCircle2 className="h-8 w-8 text-emerald-500" />
            </div>
            <div className="flex flex-col gap-1">
              <h2 className="text-xl font-bold text-foreground">Email verificado</h2>
              <p className="text-sm text-muted-foreground">
                {destination === "/auth/login"
                  // El email quedó verificado igual: lo que falta es una sesión viva
                  // en este navegador. Las tres causas alcanzables están enumeradas
                  // en `resolveDestination`.
                  ? "Iniciá sesión para entrar a tu cuenta…"
                  : "Redirigiendo al dashboard…"}
              </p>
            </div>
            <Loader2 className="h-4 w-4 animate-spin text-muted-foreground" />
          </CardContent>
        </Card>
      </div>
    )
  }

  // ── Waiting state ─────────────────────────────────────────────────────────
  return (
    <div className="flex min-h-svh items-center justify-center bg-background p-4">
      <div className="w-full max-w-md">

        {/* Logo */}
        <div className="flex flex-col items-center gap-3 mb-6">
          <div className="flex h-16 w-16 items-center justify-center rounded-xl overflow-hidden">
            <img src="/aliadata-logo.png" alt="Logo" className="h-full w-full object-contain" />
          </div>
          <h1 className="text-2xl font-bold tracking-tight text-foreground">ALIADATA</h1>
          <p className="text-sm text-muted-foreground">Emprender es Inteligente</p>
        </div>

        <Card className="border-border bg-card">
          <CardHeader className="text-center pb-2">
            {/* Animated mail icon */}
            <div className="flex justify-center mb-4">
              <div className="flex h-14 w-14 items-center justify-center rounded-full bg-primary/10">
                <Mail className="h-7 w-7 text-primary" />
              </div>
            </div>

            <CardTitle className="text-xl text-card-foreground">
              Verificá tu email
            </CardTitle>
            <CardDescription className="mt-1">
              Te enviamos un enlace de verificación.
              {email && (
                <span className="block mt-1 font-medium text-foreground">
                  {email}
                </span>
              )}
            </CardDescription>
          </CardHeader>

          <CardContent className="flex flex-col gap-5">
            {/* Polling indicator */}
            <div className="flex items-center justify-center gap-2 rounded-lg border border-border bg-accent/30 py-3 px-4">
              <Loader2 className="h-4 w-4 animate-spin text-muted-foreground shrink-0" />
              <span className="text-sm text-muted-foreground">
                Esperando confirmación…
              </span>
            </div>

            <p className="text-xs text-muted-foreground text-center leading-relaxed">
              Revisá tu bandeja de entrada y también la carpeta de{" "}
              <span className="font-medium">spam</span>. El enlace expira en 24 horas.
            </p>

            <div className="border-t border-border" />

            {/* Captcha — gatea el botón de reenvío (fix/auth-reenvio-verificacion-captcha) */}
            <CaptchaWidget ref={captchaGate.captchaRef} {...captchaGate.captchaProps} />
            <CaptchaRenewalStatus message={captchaGate.statusMessage} />

            {/* Resend button */}
            <div className="flex flex-col gap-2">
              <Button
                variant="outline"
                className="w-full border-border aria-disabled:opacity-50"
                onClick={handleResend}
                disabled={cooldown > 0 || resending || captchaGate.submitButtonProps.disabled}
                aria-disabled={captchaGate.submitButtonProps["aria-disabled"]}
              >
                {resending ? (
                  <>
                    <Loader2 className="h-4 w-4 mr-2 animate-spin" />
                    Reenviando…
                  </>
                ) : cooldown > 0 ? (
                  <>
                    <RefreshCw className="h-4 w-4 mr-2" />
                    Reenviar email ({cooldown}s)
                  </>
                ) : captchaGate.isRenewing ? (
                  <>
                    <Loader2 className="h-4 w-4 mr-2 animate-spin" />
                    {CAPTCHA_RENEWAL_LABEL}
                  </>
                ) : (
                  <>
                    <RefreshCw className="h-4 w-4 mr-2" />
                    Reenviar email
                  </>
                )}
              </Button>

              {/* Manual verification trigger */}
              <Button
                variant="ghost"
                className="w-full text-muted-foreground hover:text-foreground"
                onClick={handleManualCheck}
                disabled={checking}
              >
                {checking ? (
                  <>
                    <Loader2 className="h-4 w-4 mr-2 animate-spin" />
                    Verificando…
                  </>
                ) : (
                  "Ya verifiqué mi email"
                )}
              </Button>
            </div>

            {/* Fallback links */}
            <p className="text-center text-xs text-muted-foreground">
              ¿Email incorrecto?{" "}
              <Link
                href="/auth/register"
                className="text-primary underline-offset-4 hover:underline"
              >
                Volvé al registro
              </Link>
            </p>
          </CardContent>
        </Card>
      </div>
    </div>
  )
}

// ─── Page export — Suspense required for useSearchParams in App Router ────────

export default function VerifyEmailPage() {
  return (
    <Suspense
      fallback={
        <div className="flex min-h-svh items-center justify-center bg-background">
          <Loader2 className="h-6 w-6 animate-spin text-muted-foreground" />
        </div>
      }
    >
      <VerifyEmailContent />
    </Suspense>
  )
}
