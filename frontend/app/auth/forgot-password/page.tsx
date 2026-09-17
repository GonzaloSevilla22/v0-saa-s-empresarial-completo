"use client"

import { useState } from "react"
import Link from "next/link"
// auth-hardening-jwt-cookies (Parte C, D1, task 18.4c): el pedido de
// recuperación corre en el servidor. Esta pantalla ya no construye cliente de
// Supabase ni resuelve la URL del sitio: el `redirectTo` lo fija la acción.
import { requestPasswordResetAction } from "@/app/auth/actions"
import { unwrapAuthResult } from "@/lib/auth/auth-result"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import { Card, CardContent, CardDescription, CardFooter, CardHeader, CardTitle } from "@/components/ui/card"
import { toast } from "sonner"
import { ArrowLeft, Mail, CheckCircle } from "lucide-react"
import { CaptchaWidget } from "@/components/auth/CaptchaWidget"
import { CaptchaRenewalStatus } from "@/components/auth/CaptchaRenewalStatus"
import { CAPTCHA_RENEWAL_LABEL } from "@/lib/captcha-freshness"
import { useCaptchaGate } from "@/hooks/auth"

export default function ForgotPasswordPage() {
  const [email, setEmail] = useState("")
  const [sent, setSent] = useState(false)
  const captchaGate = useCaptchaGate()

  async function handleSubmit(e: React.FormEvent) {
    e.preventDefault()
    if (!email) {
      toast.error("Ingresá tu email")
      return
    }
    try {
      // `captchaGate.submit` sigue siendo el ÚNICO camino de envío (regla del
      // proyecto): el token se renueva si está viejo antes de que la acción
      // salga. El proveedor valida el token server-side cuando el captcha está
      // habilitado a nivel proyecto.
      await captchaGate.submit(async (token) => {
        unwrapAuthResult(await requestPasswordResetAction({ email, captchaToken: token }))
      })
      setSent(true)
    } catch (error: any) {
      toast.error(error.message || "No se pudo enviar el email. Intentá de nuevo.")
    }
  }

  return (
    <div className="flex min-h-svh items-center justify-center bg-background p-4">
      <div className="w-full max-w-md">
        <div className="flex flex-col items-center gap-4">
          <div className="flex h-16 w-16 items-center justify-center rounded-xl overflow-hidden">
            <img src="/aliadata-logo.png" alt="Logo" className="h-full w-full object-contain" />
          </div>
          <h1 className="text-2xl font-bold tracking-tight text-foreground">ALIADATA</h1>
          <p className="text-sm text-muted-foreground">Emprender es Inteligente</p>
        </div>

        <Card className="border-border bg-card mt-4">
          <CardHeader className="text-center">
            <CardTitle className="text-xl text-card-foreground">Recuperar contraseña</CardTitle>
            <CardDescription>
              {sent
                ? "Revisá tu bandeja de entrada"
                : "Ingresá tu email y te enviamos un enlace para restablecer tu contraseña"}
            </CardDescription>
          </CardHeader>

          <CardContent>
            {sent ? (
              <div className="flex flex-col items-center gap-4 py-4 text-center">
                <CheckCircle className="h-12 w-12 text-emerald-500" />
                <p className="text-sm text-muted-foreground">
                  Si <span className="font-medium text-foreground">{email}</span> está registrado,
                  vas a recibir un email con el enlace de recuperación en los próximos minutos.
                </p>
                <p className="text-xs text-muted-foreground">
                  No olvides revisar la carpeta de spam.
                </p>
              </div>
            ) : (
              <form onSubmit={handleSubmit} className="flex flex-col gap-4">
                <div className="flex flex-col gap-2">
                  <Label htmlFor="email" className="text-foreground">Email</Label>
                  <Input
                    id="email"
                    type="email"
                    placeholder="tu@email.com"
                    value={email}
                    onChange={(e) => setEmail(e.target.value)}
                    className="bg-background border-border text-foreground"
                    required
                    autoFocus
                  />
                </div>
                <CaptchaWidget ref={captchaGate.captchaRef} {...captchaGate.captchaProps} />
                <CaptchaRenewalStatus message={captchaGate.statusMessage} />
                <Button type="submit" className="w-full aria-disabled:opacity-50" {...captchaGate.submitButtonProps}>
                  {captchaGate.isLoading ? (
                    "Enviando..."
                  ) : captchaGate.isRenewing ? (
                    CAPTCHA_RENEWAL_LABEL
                  ) : (
                    <>
                      <Mail className="h-4 w-4 mr-2" />
                      Enviar enlace de recuperación
                    </>
                  )}
                </Button>
              </form>
            )}
          </CardContent>

          <CardFooter className="flex justify-center pt-0">
            <Link
              href="/auth/login"
              className="flex items-center gap-1.5 text-sm text-muted-foreground hover:text-primary transition-colors"
            >
              <ArrowLeft className="h-3.5 w-3.5" />
              Volver al inicio de sesión
            </Link>
          </CardFooter>
        </Card>
      </div>
    </div>
  )
}
