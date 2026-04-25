"use client"

import { Suspense, useState, useEffect, useRef, useCallback } from "react"
import { useRouter, useSearchParams } from "next/navigation"
import Link from "next/link"
import { createClient } from "@/lib/supabase/client"
import { Button } from "@/components/ui/button"
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card"
import { Mail, Loader2, CheckCircle2, RefreshCw } from "lucide-react"
import { toast } from "sonner"

// ─── Constants ────────────────────────────────────────────────────────────────

const RESEND_COOLDOWN = 30  // seconds before resend is allowed
const POLL_INTERVAL   = 4000 // ms between server checks

// ─── Inner content (uses useSearchParams — must be inside Suspense) ───────────

function VerifyEmailContent() {
  const router      = useRouter()
  const params      = useSearchParams()
  const emailParam  = params.get("email") ?? ""

  const supabase = createClient()

  // ── UI state ─────────────────────────────────────────────────────────────
  const [email,      setEmail]      = useState(emailParam)
  const [cooldown,   setCooldown]   = useState(RESEND_COOLDOWN)
  const [resending,  setResending]  = useState(false)
  const [checking,   setChecking]   = useState(false)
  const [verified,   setVerified]   = useState(false)

  // ── Internal refs (don't cause re-renders) ────────────────────────────────
  const redirectingRef = useRef(false)
  const pollingRef     = useRef<ReturnType<typeof setInterval> | null>(null)

  // ── Helpers ───────────────────────────────────────────────────────────────

  const getSiteUrl = () =>
    typeof window !== "undefined"
      ? window.location.origin
      : (process.env.NEXT_PUBLIC_SITE_URL ?? "http://localhost:3000")

  const stopPolling = useCallback(() => {
    if (pollingRef.current) {
      clearInterval(pollingRef.current)
      pollingRef.current = null
    }
  }, [])

  // Called once verification is confirmed — show success then redirect
  const handleVerified = useCallback(() => {
    if (redirectingRef.current) return
    redirectingRef.current = true
    stopPolling()
    setVerified(true)
    setTimeout(() => router.push("/dashboard"), 1500)
  }, [router, stopPolling])

  // Core check: ask Supabase for a fresh token and inspect email_confirmed_at
  const checkVerification = useCallback(async () => {
    if (redirectingRef.current) return

    try {
      // refreshSession() hits the Supabase server and returns the latest user data.
      // Unlike getSession() which uses cached local state, this reflects real-time
      // email_confirmed_at changes made by the verification link click.
      const { data, error } = await supabase.auth.refreshSession()
      if (!error && data.session?.user?.email_confirmed_at) {
        handleVerified()
        return
      }
    } catch {
      // refreshSession() throws when there is no refresh token (Supabase returned
      // session = null on signup). Fall through to getSession() fallback.
    }

    try {
      // Fallback: check the locally-cached session (works for same-tab scenarios)
      const { data: { session } } = await supabase.auth.getSession()
      if (session?.user?.email_confirmed_at) {
        handleVerified()
      }
    } catch {
      // Silent — polling will retry
    }
  }, [supabase, handleVerified])

  // ── Effect 1: resolve email from session if not in URL ───────────────────
  useEffect(() => {
    if (email) return
    supabase.auth.getSession().then(({ data: { session } }) => {
      if (session?.user?.email) setEmail(session.user.email)
    })
  }, [email, supabase])

  // ── Effect 2: immediate check on mount (already verified?) ───────────────
  useEffect(() => {
    checkVerification()
  }, [checkVerification])

  // ── Effect 3: periodic polling ────────────────────────────────────────────
  useEffect(() => {
    pollingRef.current = setInterval(checkVerification, POLL_INTERVAL)
    return stopPolling
  }, [checkVerification, stopPolling])

  // ── Effect 4: onAuthStateChange — primary real-time detection ────────────
  // Fires when the verification link is clicked in the same browser.
  // The /auth/callback route creates a new session → SIGNED_IN event propagates
  // across tabs via localStorage, triggering this listener in the waiting tab.
  useEffect(() => {
    const { data: { subscription } } = supabase.auth.onAuthStateChange(
      (_event, session) => {
        if (session?.user?.email_confirmed_at) {
          handleVerified()
        }
      },
    )
    return () => subscription.unsubscribe()
  }, [supabase, handleVerified])

  // ── Effect 5: Page Visibility API — force re-check when tab regains focus ─
  useEffect(() => {
    const onVisible = () => {
      if (document.visibilityState === "visible") checkVerification()
    }
    document.addEventListener("visibilitychange", onVisible)
    return () => document.removeEventListener("visibilitychange", onVisible)
  }, [checkVerification])

  // ── Effect 6: countdown timer ─────────────────────────────────────────────
  // Each render of this effect decrements cooldown by 1 after 1 second.
  // Setting cooldown to RESEND_COOLDOWN restarts it (used after resend).
  useEffect(() => {
    if (cooldown <= 0) return
    const t = setTimeout(() => setCooldown((c) => c - 1), 1000)
    return () => clearTimeout(t)
  }, [cooldown])

  // ── Resend handler ────────────────────────────────────────────────────────
  async function handleResend() {
    if (!email || cooldown > 0 || resending) return

    setResending(true)
    try {
      const { error } = await supabase.auth.resend({
        type: "signup",
        email,
        options: { emailRedirectTo: `${getSiteUrl()}/auth/callback` },
      })
      if (error) throw error
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
                Redirigiendo al dashboard…
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
            <img src="/aliada-logo.png" alt="Logo" className="h-full w-full object-contain" />
          </div>
          <h1 className="text-2xl font-bold tracking-tight text-foreground">ALIADA</h1>
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

            {/* Resend button */}
            <div className="flex flex-col gap-2">
              <Button
                variant="outline"
                className="w-full border-border"
                onClick={handleResend}
                disabled={cooldown > 0 || resending}
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
