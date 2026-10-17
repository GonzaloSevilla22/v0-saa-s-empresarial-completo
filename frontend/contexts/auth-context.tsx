"use client"

import React, { createContext, useContext, useState, useEffect, useCallback, useRef } from "react"
import { useQueryClient } from "@tanstack/react-query"
import { toast } from "sonner"
import { createClient } from "@/lib/supabase/client"
import { useRouter } from "next/navigation"
import type { User, Plan, UserRole, BillingStatus } from "@/lib/types"
import {
  accountFromMembership,
  getActiveAccount,
  parseMyAccounts,
  type AccountSummary,
  type FallbackMembershipRow,
} from "@/lib/accounts"
import { Button } from "@/components/ui/button"
import { getEffectivePlan } from "@/lib/plan-utils"
import { buildProfileUpdatePayload, type ProfileUpdateData } from "@/lib/profile-update"
import { clearAuthUxCookies } from "@/lib/cookies"
// auth-hardening-jwt-cookies (Parte C, D1, grupo 18): las siete operaciones que
// crean, modifican o destruyen la sesión corren en el servidor. Este contexto
// deja de hablarle al proveedor y le habla a las acciones; su API pública
// (`useAuth()`) no cambia, así que `/auth/login`, `MagicLinkForm`,
// `/auth/register` y `components/settings/AccountForm.tsx` conservan su UI.
import {
  refreshSessionAction,
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
  announceAccountSwitched,
  announceSignedIn,
  announceSignedOut,
  subscribeToSessionEvents,
} from "@/lib/auth/session-bus"
// multiusuario-operativo (tanda A, D5/D6): la cuenta que muestra la pantalla se declara
// en cada request al backend, y el cliente HTTP le pide a este proveedor que se
// resincronice cuando el backend dice que quedó vieja.
import {
  registerAccountResync,
  setDisplayedAccountId,
  type AccountResyncReason,
} from "@/lib/auth/active-account-store"

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
  /**
   * multiusuario-operativo (tanda A, D5): las cuentas a las que pertenece el usuario
   * (una fila por membresía), con la activa marcada. El selector del menú lateral se
   * muestra sólo con dos o más.
   */
  accounts: AccountSummary[]
  /**
   * Cambia la cuenta activa: persiste la elección (`rpc_set_active_account`), renueva el
   * token (el hook emite el claim de la cuenta nueva), descarta lo que había en caché,
   * avisa a las otras pestañas y lleva al Tablero. Rechaza si la base no la acepta (p. ej.
   * la membresía se revocó entre que se listó y se eligió).
   */
  switchAccount: (accountId: string) => Promise<void>
  /**
   * accounts-profiles-privilege-columns (2026-09-21): `upgradePlan` /
   * `downgradePlan` se RETIRARON. Escribían `profiles.plan` con
   * `.from('profiles').update(...)` desde el navegador, o sea un
   * auto-otorgamiento de plan por PostgREST — la misma familia que el hallazgo
   * de `accounts.billing_exempt`, y hasta hoy sólo fallaba porque
   * `trg_prevent_profile_escalation` lo rechazaba para quien no es admin. La
   * migración 20261053000001 le quita a `authenticated` el UPDATE de esa
   * columna, así que dejarlas habría sido dejar dos botones que revientan.
   * El cambio de plan real vive en `/planes` (MercadoPago) y la baja en
   * `POST /api/billing/cancel`. Candado:
   * `__tests__/lib/no-privilege-column-writes.test.ts`.
   */
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

/**
 * Renovación FORZADA del token ante el proveedor (multiusuario-operativo, D4).
 *
 * Releer el token handler NO alcanza: sólo renueva un access token por vencer, y el claim de la
 * cuenta activa (`app_metadata.account_id`) lo emite el hook al EMITIR. Sin esto, cambiar de cuenta
 * (o recuperarse de una cuenta revocada) dejaba el token vigente —con la cuenta vieja— hasta una
 * hora después. Devuelve `false` si el proveedor no entregó una sesión nueva; nunca lanza.
 */
async function renewSessionAtProvider(): Promise<boolean> {
  try {
    const result = await refreshSessionAction()
    return result.ok
  } catch (error) {
    console.error("[auth-context] no se pudo renovar la sesión ante el proveedor:", error)
    return false
  }
}

/**
 * Salida de EMERGENCIA cuando `rpc_my_accounts()` falla: la membresía más antigua del usuario por
 * `(created_at, id)` —el criterio previo a la tanda A—, marcada como su cuenta activa.
 *
 * No contradice D1 (la cuenta activa se resuelve en la base): el camino NORMAL sigue siendo la RPC.
 * Esto cubre dos casos que de otro modo dejarían `accountId = ""` y todas las pantallas rotas sin
 * ningún aviso: (1) la ventana de un deploy en la que Vercel ya publicó el frontend y `supabase db
 * push` todavía no aplicó la migración (`PGRST202`, unos minutos), y (2) un hipo transitorio de
 * PostgREST o de la red. Nunca lanza: si la lectura también falla o no hay membresía, devuelve
 * `[]` y el contexto queda como estaba antes de este fallback (sin cuenta).
 */
async function loadOldestMembershipFallback(
  supabase: ReturnType<typeof createClient>,
  userId: string,
  businessName: string | null | undefined,
): Promise<AccountSummary[]> {
  try {
    const { data, error } = await supabase
      .from("account_members")
      .select("account_id, role, accounts(billing_plan, billing_status, trial_plan, trial_started_at, trial_expires_at, billing_exempt)")
      .eq("user_id", userId)
      .order("created_at", { ascending: true })
      .order("id", { ascending: true })
      .limit(1)
      .maybeSingle()
    if (error) {
      console.warn("[auth-context] el FALLBACK de cuenta (account_members) tampoco pudo leer:", error)
      return []
    }
    if (!data) return []
    // Supabase infiere el embed como arreglo; es 1:1 por la membresía (mismo cast que antes de la tanda A).
    const row = data as unknown as FallbackMembershipRow
    return [accountFromMembership(row, businessName?.trim() || "Mi cuenta")]
  } catch (error) {
    console.warn("[auth-context] el FALLBACK de cuenta (account_members) lanzó:", error)
    return []
  }
}

/** Qué dejó una carga de sesión: si hay sesión, y si falta una cuenta activa. */
interface SessionLoad {
  session: boolean
  /** Hay membresías pero NINGUNA está activa (token de una cuenta ya revocada). */
  needsAccount: boolean
}

export function AuthProvider({ children }: { children: React.ReactNode }) {
  const [user, setUser] = useState<User | null>(null)
  const [accounts, setAccounts] = useState<AccountSummary[]>([])
  // multiusuario-operativo (5.4): el usuario tiene membresías pero ninguna activa, y
  // renovar el token no lo arregló -> pantalla de error con "Cerrar sesión".
  const [accountProblem, setAccountProblem] = useState<"no-active-account" | null>(null)
  const [loading, setLoading] = useState(true)
  const supabase = createClient()
  const router = useRouter()
  const queryClient = useQueryClient()
  // Nombre del negocio activo tras la última carga (para los avisos de cambio de cuenta).
  const activeNameRef = useRef<string | null>(null)

  /**
   * Una carga de identidad, perfil, cuentas y plan, **forzando** la renovación del token.
   *
   * multiusuario-operativo (tanda A, D4): la cuenta activa sale de `rpc_my_accounts()` —
   * la fila `is_active` es la que resuelve `current_account_ids()` en la base, la misma
   * que ven FastAPI y la RLS —, NUNCA de ordenar `account_members` acá (era uno de los
   * cuatro criterios de "cuenta activa" que convivían). Si hay membresías pero ninguna
   * está activa, NO se elige otra en silencio: se informa `needsAccount`.
   */
  const loadSession = useCallback(async (): Promise<SessionLoad> => {
    // Durante la renovación NO se declara cuenta (`X-Account-Id`): entre que el token
    // nuevo está en memoria y que se conoce la cuenta activa, un request con el token
    // de la cuenta B y el encabezado de la A se rechazaría con 409 contra su propio token.
    setDisplayedAccountId(null)
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
      // Sin sesión no hay cuentas: se conserva la MISMA referencia si ya estaba vacía (un arreglo
      // nuevo por carga re-renderizaría el proveedor sin que nada haya cambiado).
      setAccounts((previous) => (previous.length === 0 ? previous : []))
      return { session: false, needsAccount: false }
    }

    // ── Fetch profile + accounts in parallel ─────────────────────────────────
    // Profile: personal data, preferences, legacy billing columns.
    // Accounts (multiusuario-operativo): una fila por membresía con la activa marcada,
    // el rol propio en cada una y el estado de billing de la cuenta (C-05 D5).
    const [{ data: profile }, accountsResult] = await Promise.all([
      supabase
        .from("profiles")
        .select("*")
        .eq("id", authUser.id)
        .single(),
      // Una llamada que RECHAZA (la red) se trata igual que una que devuelve error: la carga no se rompe.
      Promise.resolve(supabase.rpc("rpc_my_accounts")).then(
        (result) => result,
        (error: unknown) => ({ data: null, error }),
      ),
    ])

    let myAccounts: AccountSummary[]
    if (accountsResult.error) {
      // Camino de EMERGENCIA (ver `loadOldestMembershipFallback`): sin esto el usuario entra con
      // `accountId = ""` y todas las pantallas rompen sin un solo aviso.
      console.warn(
        "[auth-context] rpc_my_accounts falló: se usa el FALLBACK (membresía más antigua por created_at, id; sin selector de cuenta)",
        accountsResult.error,
      )
      myAccounts = await loadOldestMembershipFallback(supabase, authUser.id, profile?.business_name)
    } else {
      myAccounts = parseMyAccounts(accountsResult.data)
    }
    const active = getActiveAccount(myAccounts)
    setAccounts(myAccounts)

    if (myAccounts.length > 0 && !active) {
      // Membresías sin cuenta activa: el token declara una cuenta de la que ya no es
      // miembro. NO se cae en silencio a otra cuenta: se pide renovar y, si persiste, error.
      setUser(null)
      activeNameRef.current = null
      return { session: true, needsAccount: true }
    }

    // ── Resolve billing state from the ACTIVE account (C-05 D5, billing-pro-trial D4) ─
    // Prefer the account's billing data; fall back to profile columns for
    // legacy compatibility while both sources are maintained in parallel.
    const billingPlan    = (active?.billingPlan as Plan)        ?? (profile?.billing_plan as Plan) ?? "gratis"
    const billingStatus  = (active?.billingStatus as BillingStatus) ?? (profile?.billing_status as BillingStatus) ?? "trialing"
    const trialPlan      = (active?.trialPlan as Plan | undefined) ?? (profile?.trial_plan as Plan | undefined)
    const trialExpiresAt = active?.trialExpiresAt ?? profile?.trial_expires_at ?? undefined
    // billing-pro-trial (D4): ausente en profiles (legacy) → false. Solo
    // accounts es la fuente — nunca se derivó de un default implícito.
    const billingExempt  = active?.billingExempt ?? false

    const accountId   = active?.accountId ?? ""
    const accountRole = (active?.memberRole as "owner" | "admin" | "member") ?? "owner"

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
    activeNameRef.current = active?.displayName ?? null
    // Recién ahora se conoce la cuenta que muestra la pantalla: se declara en cada request.
    setDisplayedAccountId(accountId)
    // Plan may have changed (upgrade/downgrade/trial expiry) → drop cached
    // plan limits so usePlanLimits re-fetches against the current plan.
    queryClient.invalidateQueries({ queryKey: ["planLimits"] })
    return { session: true, needsAccount: false }
  }, [supabase, queryClient])

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
      let load = await loadSession()
      if (load.needsAccount) {
        // Membresías sin cuenta activa: UNA renovación más —ante el proveedor, no releyendo el
        // mismo token— (el hook resuelve la cuenta que corresponde al emitir el token nuevo)
        // antes de rendirse.
        await renewSessionAtProvider()
        load = await loadSession()
      }
      haySesion = load.session
      setAccountProblem(load.needsAccount ? "no-active-account" : null)
    } catch (e) {
      console.error(e)
    } finally {
      setLoading(false)
    }
    return haySesion
  }, [loadSession])

  /**
   * Resincroniza con la cuenta activa de la base. Lo piden: otra pestaña que cambió de
   * cuenta (bus), el 409 `account_switched` y el 403 "sin cuenta activa" del cliente HTTP.
   *
   * Descarta TODO lo que había en caché (era de la cuenta anterior), re-resuelve la
   * cuenta y lleva al Tablero con un aviso. NO reanuncia el cambio: lo adoptado de otra
   * pestaña no se reenvía (lazo entre pestañas).
   */
  const resync = useCallback(
    async (reason: AccountResyncReason): Promise<void> => {
      queryClient.clear()
      await refreshSession()
      const name = activeNameRef.current
      if (!name) return // sin cuenta activa: lo muestra la pantalla de error
      router.replace("/dashboard")
      toast.info(
        reason === "switched"
          ? `Cambiaste de cuenta en otra pestaña. Ahora estás en ${name}.`
          : `Actualizamos tu cuenta activa. Ahora estás en ${name}.`,
      )
    },
    [queryClient, refreshSession, router],
  )

  useEffect(() => registerAccountResync(resync), [resync])

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
      if (event === "account:switched") {
        // Otra pestaña cambió de cuenta: el bus ya adoptó el token nuevo, que describe
        // la cuenta nueva. Esta pestaña sigue MOSTRANDO la anterior hasta resincronizarse.
        void resync("switched")
        return
      }
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
  }, [refreshSession, resync, router])

  // auth-hardening-jwt-cookies (Parte C, grupo 18): el `getSiteUrl()` que vivía
  // acá se retiró. El `emailRedirectTo` lo resuelve el servidor con
  // `lib/auth/site-url.ts` desde los encabezados de la petición — una sola
  // definición en vez de las cuatro copias que había.

  const login = useCallback(async (email: string, password: string, captchaToken?: string) => {
    if (password.length < 6) throw new Error("La contraseña debe tener al menos 6 caracteres")
    // captchaToken: el proveedor lo valida server-side cuando el captcha está
    // habilitado a nivel proyecto (Turnstile). Sin habilitar, se ignora.
    unwrapAuthResult(await signInWithPasswordAction({ email, password, captchaToken }))
    // El booleano se ignora **a propósito**, y es un residuo conocido: si la
    // renovación vuelve `unknown` (hipo de red, 5xx del manejador de token) el login
    // entra al dashboard sin token en memoria, o sea el síntoma H-5 exacto en el
    // camino más transitado. No se cierra acá por elección: las cookies de sesión ya
    // las escribió el servidor en la respuesta de la acción, así que mandar a
    // `/auth/login` a alguien que acaba de autenticarse bien —mostrándole el
    // formulario mientras tiene sesión válida— es un modo de falla peor y más visible
    // que el transitorio que evitaría. Preexistente a H-5 y fuera de su alcance.
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

  const switchAccount = useCallback(
    async (accountId: string): Promise<void> => {
      const target = accounts.find((account) => account.accountId === accountId)

      // 1) Persistir la elección. Va PRIMERO: el hook que emite el token lee esta
      //    preferencia, así que renovar el token antes emitiría la cuenta vieja.
      //    Por supabase-js y no por FastAPI, para no colgar el arranque de la app del
      //    cold start de Render (~50 s). El único error posible es una carrera: la
      //    membresía se revocó entre que se listó y se eligió.
      const { error } = await supabase.rpc("rpc_set_active_account", { p_account_id: accountId })
      if (error) {
        toast.error("No pudimos cambiar de cuenta. Actualizamos tu lista de cuentas.")
        await refreshSession()
        throw new Error("No se pudo cambiar de cuenta activa")
      }

      // 2) Renovar el token ANTE EL PROVEEDOR: el claim `account_id` lo emite el hook al
      //    emitir, y releer el token vigente (lo que hace `refreshSession` solo) no cambia la
      //    cuenta hasta que el token venza. Si no se pudo renovar, el cambio no rige: se avisa
      //    y se recarga la lista (la preferencia ya quedó guardada: un reintento la reaplica).
      if (!(await renewSessionAtProvider())) {
        toast.error("No pudimos cambiar de cuenta. Probá de nuevo.")
        await refreshSession()
        throw new Error("No se pudo renovar la sesión para cambiar de cuenta")
      }

      // 3) Descartar lo que había en caché (es de la cuenta anterior) y re-resolver la cuenta
      //    con el token nuevo.
      queryClient.clear()
      await refreshSession()

      // 4) Avisar a las otras pestañas (sin token en el mensaje) y llevar al Tablero.
      announceAccountSwitched()
      router.replace("/dashboard")
      toast.success(`Ahora estás en ${target?.displayName ?? activeNameRef.current ?? "tu cuenta"}`)
    },
    [accounts, supabase, queryClient, refreshSession, router],
  )

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

  // upgradePlan / downgradePlan retirados — ver el comentario en la interfaz
  // del contexto (accounts-profiles-privilege-columns).

  // Don't render children until initial session check is complete to prevent auth flashes
  if (loading) {
    return <div className="min-h-screen flex items-center justify-center">Loading...</div>
  }

  // multiusuario-operativo (5.4): hay membresías pero ninguna activa y renovar el token no
  // lo arregló. NO se muestra la app (no hay cuenta sobre la cual operar) ni se elige otra
  // en silencio: se ofrece reintentar o cerrar sesión.
  if (accountProblem === "no-active-account") {
    return (
      <div
        role="alert"
        className="min-h-screen flex flex-col items-center justify-center gap-4 bg-background p-6 text-center"
      >
        <h1 className="text-xl font-semibold text-foreground">No pudimos determinar tu cuenta activa</h1>
        <p className="max-w-md text-sm text-muted-foreground">
          Tu sesión ya no corresponde a ninguna de tus cuentas. Probá de nuevo; si sigue igual, cerrá
          sesión e ingresá otra vez.
        </p>
        <div className="flex flex-col gap-2 sm:flex-row">
          <Button className="min-h-11" onClick={() => void refreshSession()}>
            Reintentar
          </Button>
          <Button className="min-h-11" variant="outline" onClick={() => void logout()}>
            Cerrar sesión
          </Button>
        </div>
      </div>
    )
  }

  return (
    <AuthContext.Provider
      value={{
        user,
        accounts,
        switchAccount,
        isAuthenticated: !!user,
        isAdmin: user?.role === "admin",
        effectivePlan: user?.effectivePlan ?? "gratis",
        login,
        loginWithMagicLink,
        register,
        logout,
        refreshSession,
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
