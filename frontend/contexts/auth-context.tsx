"use client"

import React, { createContext, useContext, useState, useEffect, useCallback } from "react"
import { useQueryClient } from "@tanstack/react-query"
import { createClient } from "@/lib/supabase/client"
import { useRouter } from "next/navigation"
import type { User, Plan, UserRole, BillingStatus } from "@/lib/types"
import { getEffectivePlan } from "@/lib/plan-utils"

export interface ProfileUpdateData {
  name?: string
  lastName?: string
  businessName?: string
  phone?: string
  locality?: string
  bio?: string
  avatarUrl?: string
}

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

  const refreshSession = useCallback(async () => {
    try {
      // getUser() validates the JWT server-side (network call).
      // getSession() only trusts the local cookie — never use it as an auth check.
      // The middleware already calls getUser() on every request, so this
      // client-side call is for hydrating the React state after confirmed auth.
      const { data: { user: authUser }, error } = await supabase.auth.getUser()
      if (error || !authUser) {
        setUser(null)
        return
      }
      // ── Fetch profile + account membership in parallel ─────────────────────
      // Profile: personal data, preferences, legacy billing columns.
      // Membership: account_id, role, and the account's billing state (C-05 D5).
      const [{ data: profile }, { data: membership }] = await Promise.all([
        supabase
          .from("profiles")
          .select("*")
          .eq("id", authUser.id)
          .single(),
        supabase
          .from("account_members")
          .select("account_id, role, accounts(billing_plan, billing_status, trial_plan, trial_started_at, trial_expires_at)")
          .eq("user_id", authUser.id)
          .single(),
      ])

      // ── Resolve billing state from account (C-05 D5) ───────────────────────
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
      } | null

      const billingPlan    = (accountRow?.billing_plan as Plan)    ?? (profile?.billing_plan as Plan) ?? "gratis"
      const billingStatus  = (accountRow?.billing_status as BillingStatus) ?? (profile?.billing_status as BillingStatus) ?? "trialing"
      const trialPlan      = (accountRow?.trial_plan as Plan | undefined) ?? (profile?.trial_plan as Plan | undefined)
      const trialExpiresAt = accountRow?.trial_expires_at ?? profile?.trial_expires_at ?? undefined

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
          effectivePlan:  getEffectivePlan({ billingPlan, billingStatus, trialPlan, trialExpiresAt }),
          aiQueriesUsed:  profile.ai_queries_used ?? 0,
          aiAdviceUsed:   profile.ai_advice_used  ?? 0,
          role:           profile.role as UserRole,
          name:           profile.name || authUser.user_metadata?.name || authUser.email?.split("@")[0] || "Emprendedor",
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
          effectivePlan: getEffectivePlan({ billingPlan, billingStatus, trialPlan, trialExpiresAt }),
          aiQueriesUsed: 0,
          aiAdviceUsed:  0,
          role:          "user",
          name:          authUser.user_metadata?.name || authUser.email?.split("@")[0] || "Emprendedor",
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
  }, [supabase, queryClient])

  useEffect(() => {
    refreshSession()

    const { data: { subscription } } = supabase.auth.onAuthStateChange((event) => {
      // TOKEN_REFRESHED fires every ~hour — middleware already rotates the cookie,
      // no need to re-query the DB. Only react to events that change user state.
      if (event === "SIGNED_IN" || event === "USER_UPDATED") {
        refreshSession()
      } else if (event === "SIGNED_OUT") {
        setUser(null)
      }
    })

    return () => {
      subscription.unsubscribe()
    }
  }, [refreshSession, supabase.auth])

  // Función helper para obtener la URL dinámica robusta
  const getSiteUrl = () => {
    if (typeof window !== 'undefined') {
      return window.location.origin
    }
    let url = process.env.NEXT_PUBLIC_SITE_URL ?? process.env.NEXT_PUBLIC_VERCEL_URL ?? 'http://localhost:3000'
    url = url.includes('http') ? url : `https://${url}`
    return url.replace(/\/$/, '')
  }

  const login = useCallback(async (email: string, password: string, captchaToken?: string) => {
    if (password.length < 6) throw new Error("La contraseña debe tener al menos 6 caracteres")
    // captchaToken: Supabase Auth lo valida server-side cuando el captcha está
    // habilitado a nivel proyecto (Turnstile). Sin habilitar, se ignora.
    const { error } = await supabase.auth.signInWithPassword({
      email,
      password,
      options: { captchaToken },
    })
    if (error) throw error
    await refreshSession()
    router.push("/dashboard")
  }, [supabase, router, refreshSession])

  const loginWithMagicLink = useCallback(async (email: string, captchaToken?: string) => {
    const siteUrl = getSiteUrl()
    const { error } = await supabase.auth.signInWithOtp({
      email,
      options: { emailRedirectTo: `${siteUrl}/auth/callback`, captchaToken },
    })
    if (error) throw error
  }, [supabase])

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
    const siteUrl = getSiteUrl()
    console.log("[Auth] Iniciando registro. URL callback configurada a:", `${siteUrl}/auth/callback`)

    // name/last_name/phone/locality + consentimiento viajan en el user_metadata
    // del signUp; el trigger handle_new_user los copia a profiles al crear el perfil.
    // captchaToken lo valida Supabase server-side cuando el captcha está habilitado.
    const { error } = await supabase.auth.signUp({
      email,
      password,
      options: {
        data: {
          name,
          last_name: extras?.lastName || null,
          phone: extras?.phone || null,
          locality: extras?.locality || null,
          province: extras?.province || null,
          terms_version: extras?.termsVersion || null,
          // Default false: nadie queda suscripto por accidente (espeja el default de la columna).
          email_notifications_opt_in: extras?.emailOptIn ?? false,
        },
        emailRedirectTo: `${siteUrl}/auth/callback`,
        captchaToken: extras?.captchaToken,
      },
    })
    if (error) throw error
    // Navigation is handled by the caller (register/page.tsx) so this function
    // remains a pure auth operation, reusable from any context without side-effects.
  }, [supabase])

  const logout = useCallback(async () => {
    const { error } = await supabase.auth.signOut()
    if (error) throw error
    // Clear tenant cookie on logout so a different user doesn't inherit the workspace
    document.cookie = "tenant:active=; path=/; max-age=0"
    router.push("/auth/login")
  }, [supabase, router])

  const updateProfile = useCallback(async (data: ProfileUpdateData) => {
    if (!user) throw new Error("No hay sesión activa")
    const { error } = await supabase.from('profiles').update({
      name:          data.name         ?? undefined,
      last_name:     data.lastName     ?? undefined,
      business_name: data.businessName ?? undefined,
      phone:         data.phone        ?? undefined,
      locality:      data.locality     ?? undefined,
      bio:           data.bio          ?? undefined,
      avatar_url:    data.avatarUrl    ?? undefined,
    }).eq('id', user.id)
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
    const { error } = await supabase.auth.updateUser({ password: newPassword })
    if (error) throw error
  }, [supabase])

  const changeEmail = useCallback(async (newEmail: string) => {
    const siteUrl = getSiteUrl()
    const { error } = await supabase.auth.updateUser(
      { email: newEmail },
      { emailRedirectTo: `${siteUrl}/auth/callback` }
    )
    if (error) throw error
    // Session remains valid. User must click the link sent to newEmail to confirm.
  }, [supabase])

  const closeAllSessions = useCallback(async () => {
    // scope: 'global' revokes all refresh tokens including the current device.
    // The user will be redirected to login by the auth state change listener.
    const { error } = await supabase.auth.signOut({ scope: 'global' })
    if (error) throw error
    router.push("/auth/login")
  }, [supabase, router])

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
