"use client"

import React, { createContext, useContext, useState, useEffect, useCallback } from "react"
import { useQueryClient } from "@tanstack/react-query"
import { createClient } from "@/lib/supabase/client"
import { useRouter } from "next/navigation"
import type { User, Plan, UserRole, BillingStatus } from "@/lib/types"
import { getEffectivePlan } from "@/lib/plan-utils"
import { buildProfileUpdatePayload, type ProfileUpdateData } from "@/lib/profile-update"
import { clearAuthUxCookies } from "@/lib/cookies"
// auth-hardening-jwt-cookies (Parte C, D1, grupo 18): las siete operaciones que
// crean, modifican o destruyen la sesión corren en el servidor. Este contexto
// deja de hablarle al proveedor y le habla a las acciones; su API pública
// (`useAuth()`) no cambia, así que `/auth/login`, `MagicLinkForm`,
// `/auth/register` y `components/settings/AccountForm.tsx` conservan su UI.
import {
  requestEmailChangeAction,
  signInWithMagicLinkAction,
  signInWithPasswordAction,
  signOutAction,
  signUpAction,
  updatePasswordAction,
} from "@/app/auth/actions"
import { unwrapAuthResult } from "@/lib/auth/auth-result"
import { clearAccessToken, refreshAccessToken } from "@/lib/auth/access-token-store"
// auth-hardening-jwt-cookies (Parte C, D1, task 20.3): el reemplazo de
// `supabase.auth.onAuthStateChange`, que con `accessToken` configurado ni se
// instala. El bus corre sobre el único transporte entre pestañas del proyecto.
import {
  announceSignedIn,
  announceSignedOut,
  subscribeToSessionEvents,
} from "@/lib/auth/session-bus"

// G11 (H9): el tipo y el armado del payload viven en la capa canónica
// (lib/profile-update.ts) — null limpia la columna, undefined la omite.
export type { ProfileUpdateData } from "@/lib/profile-update"

export interface PreferencesUpdateData {
  currency?: string
  timezone?: string
  dateFormat?: string
  language?: string
}

interface AuthContextType {
  user: User | null
  isAuthenticated: boolean
  isAdmin: boolean
  /** Effective plan for gating (trial-aware). 'gratis' when logged out. */
  effectivePlan: Plan
  login: (email: string, password: string, captchaToken?: string) => Promise<void>
  loginWithMagicLink: (email: string, captchaToken?: string) => Promise<void>
  register: (
    name: string,
    email: string,
    password: string,
    extras?: {
      phone?: string
      locality?: string
      province?: string
      lastName?: string
      termsVersion?: string
      emailOptIn?: boolean
      captchaToken?: string
    },
  ) => Promise<void>
  logout: () => Promise<void>
  /**
   * Vuelve a resolver identidad, perfil, cuenta y plan **forzando** la renovación
   * del access token en memoria.
   *
   * Está en la API pública por H-5 (humo local del 2026-09-18): la pantalla que
   * detecta la verificación del email (`/auth/verify-email`) es el otro punto —
   * además del login y del registro — que SABE que la sesión acaba de nacer, y
   * sin forzar la renovación navegaba al dashboard con el store todavía en "no hay
   * sesión". Ver el comentario de `refreshSession` en el proveedor.
   *
   * @returns `true` si tras renovar hay sesión viva en este navegador.
   */
  refreshSession: () => Promise<boolean>
  upgradePlan: () => Promise<void>
  downgradePlan: () => Promise<void>
  /** Update editable profile fields (name, avatar, business info, etc.) */
  updateProfile: (data: ProfileUpdateData) => Promise<void>
  /** Update system preferences (currency, timezone, date format) */
  updatePreferences: (data: PreferencesUpdateData) => Promise<void>
  /** Change the authenticated user's password via Supabase Auth */
  changePassword: (newPassword: string) => Promise<void>
  /** Request an email change — Supabase sends a confirmation to the new address */
  changeEmail: (newEmail: string) => Promise<void>
  /** Sign out from ALL devices (including the current one) and redirect to login */
  closeAllSessions: () => Promise<void>
}

const AuthContext = createContext<AuthContextType | null>(null)

export function AuthProvider({ children }: { children: React.ReactNode }) {
  const [user, setUser] = useState<User | null>(null)
  const [loading, setLoading] = useState(true)
  const supabase = createClient()
  const router = useRouter()
  const queryClient = useQueryClient()

  /**
   * @returns `true` si tras renovar hay sesión viva. Quien navega por el resultado
   *   de un alta de sesión lo necesita: `/auth/verify-email` elige entre
   *   `/dashboard` y `/auth/login` con este booleano (H-5), y mandar a alguien sin
   *   sesión al dashboard es justo el síntoma que el arreglo cierra.
   *
   *   La respuesta sale de la **resolución del token**, no del perfil: si el token
   *   está activo hay sesión aunque la consulta de perfil falle. `absent` y
   *   `unknown` cuentan los dos como "no hay" — tratar "no pude averiguarlo" como
   *   sesión viva deja la app llamando a PostgREST con la anon key.
   */
  const refreshSession = useCallback(async (): Promise<boolean> => {
    let haySesion = false
    try {
      // auth-hardening-jwt-cookies (Parte C, D1, task 19.8a): la identidad sale
      // del token handler y no de `supabase.auth.getUser()`, que con `accessToken`
      // configurado LANZA (`supabase-js/index.mjs:389`).
      //
      // **`refreshAccessToken()` y no `getAccessToken()`**, o sea FORZANDO: esta
      // función se llama justo después de `signInWithPasswordAction()`, y el store
      // viene de la pantalla de login —una página anónima— donde ya cacheó "no hay
      // sesión". Sin forzar, el login terminaría bien en el servidor y la app
      // quedaría anónima hasta que el usuario recargue.
      //
      // El token que devuelve el manejador lo emitió el proveedor y lo verifica
      // quien lo recibe (PostgREST y FastAPI comprueban la firma): la garantía que
      // daba `getUser()` —"esto no es una cookie que alguien escribió"— la sigue
      // dando el servidor, que es el único que puede leer la sesión.
      const resolution = await refreshAccessToken()
      const authUser = resolution.status === "active" ? resolution.user : null
      if (!authUser) {
        setUser(null)
        return false
      }
      haySesion = true
      // ── Fetch profile + account membership in parallel ─────────────────────
      // Profile: personal data, preferences, legacy billing columns.
      // Membership: account_id, role, and the account's billing state (C-05 D5).
      const [{ data: profile }, { data: membership }] = await Promise.all([
        supabase
          .from("profiles")
          .select("*")
          .eq("id", authUser.id)
          .single(),
        // v3-rbac-multirole Parte C (ronda 3, MAJOR-1): `.single()` devolvía
        // 406/PGRST116 en cuanto el usuario tenía 2+ membresías (todo
        // invitado a una cuenta ajena, porque handle_new_user ya le dio una
        // propia) -- membership quedaba null, accountId "" y todos los hooks
        // `enabled: !!accountId` se apagaban en silencio. Mismo criterio
        // determinístico que backend/core/deps.py::get_account_id y el hook
        // de auth (20260827000001): la membresía más antigua por
        // created_at, desempatada por id. `.maybeSingle()` además nunca
        // lanza con 0 filas (el otro borde que `.single()` rompía igual).
        supabase
          .from("account_members")
          .select("account_id, role, accounts(billing_plan, billing_status, trial_plan, trial_started_at, trial_expires_at, billing_exempt)")
          .eq("user_id", authUser.id)
          .order("created_at", { ascending: true })
          .order("id", { ascending: true })
          .limit(1)
          .maybeSingle(),
      ])

      // ── Resolve billing state from account (C-05 D5, billing-pro-trial D4) ─
      // Prefer the account's billing data; fall back to profile columns for
      // legacy compatibility while both sources are maintained in parallel.
      // Supabase infers the join as an array type; cast via unknown to get
      // the single-row object shape we know the query returns (1:1 membership).
      const accountRow = (membership?.accounts as unknown) as {
        billing_plan: string
        billing_status: string
        trial_plan: string | null
        trial_started_at: string | null
        trial_expires_at: string | null
        billing_exempt: boolean | null
      } | null

      const billingPlan    = (accountRow?.billing_plan as Plan)    ?? (profile?.billing_plan as Plan) ?? "gratis"
      const billingStatus  = (accountRow?.billing_status as BillingStatus) ?? (profile?.billing_status as BillingStatus) ?? "trialing"
      const trialPlan      = (accountRow?.trial_plan as Plan | undefined) ?? (profile?.trial_plan as Plan | undefined)
      const trialExpiresAt = accountRow?.trial_expires_at ?? profile?.trial_expires_at ?? undefined
      // billing-pro-trial (D4): ausente en profiles (legacy) → false. Solo
      // accounts es la fuente — nunca se derivó de un default implícito.
      const billingExempt  = accountRow?.billing_exempt ?? false

      const accountId   = membership?.account_id ?? ""
      const accountRole = (membership?.role as "owner" | "admin" | "member") ?? "owner"

      if (profile) {
        setUser({
          id:             authUser.id,
          email:          authUser.email || "",
          // ── Tenant account (C-05) ──────────────────────────────────────────
          accountId,
          accountRole,
          // @deprecated `plan` kept for legacy compat — use effectivePlan for gating
          plan:           (profile.plan as Plan) ?? "gratis",
          billingPlan,
          billingStatus,
          trialPlan,
          trialExpiresAt,
          billingExempt,
          effectivePlan:  getEffectivePlan({ billingPlan, trialPlan, trialExpiresAt, billingExempt }),
          aiQueriesUsed:  profile.ai_queries_used ?? 0,
          aiAdviceUsed:   profile.ai_advice_used  ?? 0,
          role:           profile.role as UserRole,
          name:           profile.name || authUser.name || authUser.email?.split("@")[0] || "Emprendedor",
          lastName:       profile.last_name     ?? undefined,
          avatar:         profile.avatar_url    ?? undefined,
          businessName:   profile.business_name ?? undefined,
          phone:          profile.phone         ?? undefined,
          locality:       profile.locality      ?? undefined,
          province:       profile.province      ?? undefined,
          bio:            profile.bio           ?? undefined,
          termsVersion:        profile.terms_version              ?? undefined,
          termsAcceptedAt:     profile.terms_accepted_at          ?? undefined,
          emailNotificationsOptIn: profile.email_notifications_opt_in ?? undefined,
          currency:       profile.currency    ?? "ARS",
          timezone:       profile.timezone    ?? "America/Argentina/Buenos_Aires",
          dateFormat:     profile.date_format ?? "DD/MM/YYYY",
          language:       profile.language    ?? "es",
        })
      } else {
        setUser({
          id:            authUser.id,
          email:         authUser.email || "",
          accountId,
          accountRole,
          plan:          "gratis",
          billingPlan,
          billingStatus,
          trialPlan,
          trialExpiresAt,
          billingExempt,
          effectivePlan: getEffectivePlan({ billingPlan, trialPlan, trialExpiresAt, billingExempt }),
          aiQueriesUsed: 0,
          aiAdviceUsed:  0,
          role:          "user",
          name:          authUser.name || authUser.email?.split("@")[0] || "Emprendedor",
          currency:      "ARS",
          timezone:      "America/Argentina/Buenos_Aires",
          dateFormat:    "DD/MM/YYYY",
          language:      "es",
        })
      }
      // Plan may have changed (upgrade/downgrade/trial expiry) → drop cached
      // plan limits so usePlanLimits re-fetches against the current plan.
      queryClient.invalidateQueries({ queryKey: ["planLimits"] })
    } catch (e) {
      console.error(e)
    } finally {
      setLoading(false)
    }
    return haySesion
  }, [supabase, queryClient])

  useEffect(() => {
    refreshSession()
    // auth-hardening-jwt-cookies (Parte C, D1, tasks 19.8a y 20.3): acá vivía un
    // `supabase.auth.onAuthStateChange`. Con `accessToken` configurado
    // `_listenForAuthEvents()` NO se instala (`supabase-js/index.mjs:407`) y
    // cualquier acceso a `supabase.auth` lanza (`:389`), así que el listener no es
    // código que se pueda dejar "por si acaso": no existe.
    //
    // Lo que hacía para ESTA pestaña ya está cubierto: cada operación de sesión
    // llama `refreshSession()` o navega. Lo que sólo él daba es la propagación
    // CROSS-TAB, y eso lo restituye el bus de sesión: cerrar sesión en el celular
    // tiene que dejar a la tablet del mostrador sin sesión, no mostrando datos
    // como si siguiera viva hasta que algo devuelva 401.
    //
    // El bus NO reutiliza el mensaje `logout` del temporizador de inactividad
    // (que significa "cierre por inactividad" y lleva a `?reason=idle`): tiene
    // tipos propios, y los del temporizador no llegan acá.
    const unsubscribe = subscribeToSessionEvents((event) => {
      if (event === "session:signed-out") {
        // El token en memoria ya lo olvidó el bus; las cookies las borró la
        // pestaña que cerró (son del navegador, no de la pestaña). Lo que le queda
        // a ESTA pestaña es dejar de mostrarse autenticada e irse al login, sin
        // `reason=idle`: no fue inactividad.
        setUser(null)
        router.push("/auth/login")
        return
      }
      // Sesión iniciada o token rotado en otra pestaña: el bus ya adoptó el token
      // nuevo, así que esto sólo vuelve a resolver identidad, perfil y plan.
      void refreshSession()
    })

    return unsubscribe
  }, [refreshSession, router])

  // auth-hardening-jwt-cookies (Parte C, grupo 18): el `getSiteUrl()` que vivía
  // acá se retiró. El `emailRedirectTo` lo resuelve el servidor con
  // `lib/auth/site-url.ts` desde los encabezados de la petición — una sola
  // definición en vez de las cuatro copias que había.

  const login = useCallback(async (email: string, password: string, captchaToken?: string) => {
    if (password.length < 6) throw new Error("La contraseña debe tener al menos 6 caracteres")
    // captchaToken: el proveedor lo valida server-side cuando el captcha está
    // habilitado a nivel proyecto (Turnstile). Sin habilitar, se ignora.
    unwrapAuthResult(await signInWithPasswordAction({ email, password, captchaToken }))
    await refreshSession()
    // task 20.3: las otras pestañas de este navegador comparten la cookie de
    // sesión, pero no el token en memoria ni el estado de React: sin el aviso se
    // quedan mostrando el login hasta que se recarguen a mano.
    announceSignedIn()
    router.push("/dashboard")
  }, [router, refreshSession])

  const loginWithMagicLink = useCallback(async (email: string, captchaToken?: string) => {
    unwrapAuthResult(await signInWithMagicLinkAction({ email, captchaToken }))
  }, [])

  const register = useCallback(async (
    name: string,
    email: string,
    password: string,
    extras?: {
      phone?: string
      locality?: string
      province?: string
      lastName?: string
      termsVersion?: string
      emailOptIn?: boolean
      captchaToken?: string
    },
  ) => {
    if (password.length < 6) throw new Error("La contraseña debe tener al menos 6 caracteres")
    // El user_metadata (name/last_name/phone/locality + consentimiento) y el
    // `emailRedirectTo` los arma la acción de servidor; el trigger
    // handle_new_user los copia a profiles al crear el perfil.
    unwrapAuthResult(
      await signUpAction({
        email,
        password,
        captchaToken: extras?.captchaToken,
        profile: {
          name,
          lastName: extras?.lastName,
          phone: extras?.phone,
          locality: extras?.locality,
          province: extras?.province,
          termsVersion: extras?.termsVersion,
          emailOptIn: extras?.emailOptIn,
        },
      }),
    )
    // H-5 (humo local del 2026-09-18): la MISMA renovación forzada que hace
    // `login()`. Cuando la confirmación de email está apagada, `signUpAction` deja
    // sesión viva en la misma respuesta — y el store viene de `/auth/register`, una
    // página anónima, donde ya cacheó "no hay sesión" (regla 3 de
    // `access-token-store.ts`). Sin forzar acá, el llamador navega con el store en
    // "no hay sesión" y la primera pantalla de la cuenta nueva llama a PostgREST
    // con la anon key: "permission denied for function get_dashboard_financials"
    // más cuatro 401 en la consola del primer render.
    //
    // Se llama SIEMPRE, no sólo cuando hay sesión: el store es el único que sabe si
    // la hay, y preguntárselo es exactamente esta llamada. Con la confirmación
    // encendida vuelve "no hay sesión", que es la verdad, y el destino del registro
    // no cambia (lo elige `app/auth/register/page.tsx`: `/auth/verify-email`).
    await refreshSession()
    // Navigation is handled by the caller (register/page.tsx) so this function
    // remains a pure auth operation, reusable from any context without side-effects.
  }, [refreshSession])

  const logout = useCallback(async () => {
    // auth-hardening-jwt-cookies (D6): `scope: 'local'` explícito. El
    // `signOut()` pelado es GLOBAL por default de la librería
    // (`GoTrueClient.js:3150`), así que cerrar sesión en el celular revocaba
    // los refresh tokens de TODOS los dispositivos y tiraba abajo el POS del
    // mostrador. `closeAllSessions()` es la acción explícita para eso.
    //
    // Parte C (grupo 18): la revocación y el borrado de las cookies `sb-*`
    // ocurren en el servidor, en la misma respuesta de la acción — que es lo que
    // pide el escenario "El cierre de sesión revoca del lado del servidor".
    unwrapAuthResult(await signOutAction({ scope: 'local' }))
    // Parte C (D1, task 19.5): el access token vive en memoria del modulo y el
    // servidor no puede borrarlo. `router.push` NO recarga la pagina, asi que el
    // modulo sigue vivo: sin esto la pestana se queda con una credencial que el
    // servidor ya revoco, valida hasta su `exp`, y cualquier refetch pendiente
    // de React Query la usa.
    clearAccessToken()
    // D6: borra todas las cookies de experiencia de la sesión
    // (`auth:last-activity` además de `tenant:active`) por el mecanismo
    // compartido con `performIdleLogout()` y `closeAllSessions()`. Éstas NO son
    // httpOnly: son de experiencia y el navegador las escribe y las borra.
    clearAuthUxCookies()
    // task 20.3: cierre MANUAL, con el tipo propio del bus. Nunca el `logout` del
    // temporizador de inactividad, que haría que las otras pestañas mostraran
    // "tu sesión se cerró por inactividad" cuando no es cierto.
    announceSignedOut()
    router.push("/auth/login")
  }, [router])

  const updateProfile = useCallback(async (data: ProfileUpdateData) => {
    if (!user) throw new Error("No hay sesión activa")
    // G11 (H9): null limpia la columna, undefined la omite — el `?? undefined`
    // anterior colapsaba ambos y vaciar un campo era imposible desde la UI.
    const { error } = await supabase
      .from('profiles')
      .update(buildProfileUpdatePayload(data))
      .eq('id', user.id)
    if (error) throw error
    await refreshSession()
  }, [supabase, user, refreshSession])

  const updatePreferences = useCallback(async (data: PreferencesUpdateData) => {
    if (!user) throw new Error("No hay sesión activa")
    const { error } = await supabase.from('profiles').update({
      currency:    data.currency    ?? undefined,
      timezone:    data.timezone    ?? undefined,
      date_format: data.dateFormat  ?? undefined,
      language:    data.language    ?? undefined,
    }).eq('id', user.id)
    if (error) throw error
    await refreshSession()
  }, [supabase, user, refreshSession])

  const changePassword = useCallback(async (newPassword: string) => {
    unwrapAuthResult(await updatePasswordAction({ password: newPassword }))
  }, [])

  const changeEmail = useCallback(async (newEmail: string) => {
    unwrapAuthResult(await requestEmailChangeAction({ email: newEmail }))
    // Session remains valid. User must click the link sent to newEmail to confirm.
  }, [])

  const closeAllSessions = useCallback(async () => {
    // scope: 'global' revokes all refresh tokens including the current device.
    // Es la ÚNICA acción que conserva el alcance global (D6).
    unwrapAuthResult(await signOutAction({ scope: 'global' }))
    // Con alcance global importa mas todavia: el usuario pidio cerrar en TODOS
    // los dispositivos y este es el unico token que el servidor no alcanza.
    clearAccessToken()
    // D6: antes de este change no borraba ninguna cookie de experiencia.
    clearAuthUxCookies()
    // task 20.3: con alcance global las demás pestañas de ESTE navegador también
    // quedaron sin sesión válida; el aviso es lo que se las hace notar ya.
    announceSignedOut()
    router.push("/auth/login")
  }, [router])

  const upgradePlan = useCallback(async () => {
    if (!user) return
    const { error } = await supabase.from('profiles').update({ plan: 'pro' }).eq('id', user.id)
    if (error) throw error
    await refreshSession()
  }, [supabase, user, refreshSession])

  const downgradePlan = useCallback(async () => {
    if (!user) return
    const { error } = await supabase.from('profiles').update({ plan: 'free' }).eq('id', user.id)
    if (error) throw error
    await refreshSession()
  }, [supabase, user, refreshSession])

  // Don't render children until initial session check is complete to prevent auth flashes
  if (loading) {
    return <div className="min-h-screen flex items-center justify-center">Loading...</div>
  }

  return (
    <AuthContext.Provider
      value={{
        user,
        isAuthenticated: !!user,
        isAdmin: user?.role === "admin",
        effectivePlan: user?.effectivePlan ?? "gratis",
        login,
        loginWithMagicLink,
        register,
        logout,
        refreshSession,
        upgradePlan,
        downgradePlan,
        updateProfile,
        updatePreferences,
        changePassword,
        changeEmail,
        closeAllSessions,
      }}
    >
      {children}
    </AuthContext.Provider>
  )
}

export function useAuth() {
  const context = useContext(AuthContext)
  if (!context) {
    throw new Error("useAuth must be used within an AuthProvider")
  }
  return context
}
