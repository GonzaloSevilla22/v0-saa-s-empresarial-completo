"use client"

import React, { createContext, useContext, useState, useEffect, useCallback } from "react"
import { createClient } from "@/lib/supabase/client"
import { useRouter } from "next/navigation"
import type { User, Plan, UserRole } from "@/lib/types"

export interface ProfileUpdateData {
  name?: string
  lastName?: string
  businessName?: string
  phone?: string
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
  login: (email: string, password: string) => Promise<void>
  loginWithMagicLink: (email: string) => Promise<void>
  register: (name: string, email: string, password: string) => Promise<void>
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

  const refreshSession = useCallback(async () => {
    try {
      const { data: { session }, error } = await supabase.auth.getSession()
      if (error || !session) {
        setUser(null)
        return
      }

      // Fetch profile data for plan and role
      const { data: profile } = await supabase
        .from('profiles')
        .select('*')
        .eq('id', session.user.id)
        .single()

      if (profile) {
        setUser({
          id:           session.user.id,
          email:        session.user.email || "",
          plan:         (profile.plan as Plan) ?? 'free',
          role:         profile.role as UserRole,
          // Personal profile
          name:         profile.name || session.user.user_metadata?.name || session.user.email?.split("@")[0] || "Emprendedor",
          lastName:     profile.last_name     ?? undefined,
          avatar:       profile.avatar_url    ?? undefined,
          businessName: profile.business_name ?? undefined,
          phone:        profile.phone         ?? undefined,
          bio:          profile.bio           ?? undefined,
          // System preferences (use DB value or sensible defaults)
          currency:     profile.currency    ?? 'ARS',
          timezone:     profile.timezone    ?? 'America/Argentina/Buenos_Aires',
          dateFormat:   profile.date_format ?? 'DD/MM/YYYY',
          language:     profile.language    ?? 'es',
        })
      } else {
        setUser({
          id:         session.user.id,
          email:      session.user.email || "",
          plan:       'free',
          role:       'user',
          name:       session.user.user_metadata?.name || session.user.email?.split("@")[0] || "Emprendedor",
          currency:   'ARS',
          timezone:   'America/Argentina/Buenos_Aires',
          dateFormat: 'DD/MM/YYYY',
          language:   'es',
        })
      }
    } catch (e) {
      console.error(e)
    } finally {
      setLoading(false)
    }
  }, [supabase])

  useEffect(() => {
    refreshSession()

    const { data: { subscription } } = supabase.auth.onAuthStateChange((_event, session) => {
      refreshSession()
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

  const login = useCallback(async (email: string, password: string) => {
    console.log("[Auth] Iniciando flujo de login tradicional para:", email)
    if (password.length < 6) throw new Error("La contraseña debe tener al menos 6 caracteres")
    const { error } = await supabase.auth.signInWithPassword({
      email,
      password,
    })
    if (error) {
      console.error("[Auth] Error en login:", error.message)
      throw error
    }
    await refreshSession()
    router.push("/dashboard")
  }, [supabase, router, refreshSession])

  const loginWithMagicLink = useCallback(async (email: string) => {
    const siteUrl = getSiteUrl()
    console.log("[Auth] Iniciando flujo Magic Link. URL callback configurada a:", `${siteUrl}/auth/callback`)

    const { error } = await supabase.auth.signInWithOtp({
      email,
      options: {
        emailRedirectTo: `${siteUrl}/auth/callback`,
      }
    })
    if (error) {
      console.error("[Auth] Error enviando email de Magic Link:", error.message)
      throw error
    }
    console.log("[Auth] Email de magic link enviado correctamente a:", email)
  }, [supabase])

  const register = useCallback(async (name: string, email: string, password: string) => {
    if (password.length < 6) throw new Error("La contraseña debe tener al menos 6 caracteres")
    const siteUrl = getSiteUrl()
    console.log("[Auth] Iniciando registro. URL callback configurada a:", `${siteUrl}/auth/callback`)

    const { error } = await supabase.auth.signUp({
      email,
      password,
      options: {
        data: { name },
        // After email confirmation the link lands here and the session is created.
        emailRedirectTo: `${siteUrl}/auth/callback`,
      },
    })
    if (error) {
      console.error("[Auth] Error en registro:", error.message)
      throw error
    }
    console.log("[Auth] Registro iniciado. Email de confirmación enviado a:", email)
    // Navigation is handled by the caller (register/page.tsx) so this function
    // remains a pure auth operation, reusable from any context without side-effects.
  }, [supabase])

  const logout = useCallback(async () => {
    const { error } = await supabase.auth.signOut()
    if (error) throw error
    router.push("/")
  }, [supabase, router])

  const updateProfile = useCallback(async (data: ProfileUpdateData) => {
    if (!user) throw new Error("No hay sesión activa")
    const { error } = await supabase.from('profiles').update({
      name:          data.name         ?? undefined,
      last_name:     data.lastName     ?? undefined,
      business_name: data.businessName ?? undefined,
      phone:         data.phone        ?? undefined,
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
