"use client"

import { useState } from "react"
import { useRouter } from "next/navigation"
import { createClient } from "@/lib/supabase/client"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import { Card, CardContent, CardDescription, CardFooter, CardHeader, CardTitle } from "@/components/ui/card"
import { toast } from "sonner"
import { Eye, EyeOff, ShieldCheck } from "lucide-react"
import Link from "next/link"

const passwordRequirements = [
  { label: "Mínimo 8 caracteres", test: (p: string) => p.length >= 8 },
  { label: "Al menos 1 número", test: (p: string) => /\d/.test(p) },
  { label: "Al menos 1 letra", test: (p: string) => /[a-zA-Z]/.test(p) },
  { label: "Al menos 1 mayúscula", test: (p: string) => /[A-Z]/.test(p) },
  { label: "Al menos 1 símbolo", test: (p: string) => /[!@#$%^&*(),.?":{}|<>]/.test(p) },
]

export default function ResetPasswordPage() {
  const [password, setPassword] = useState("")
  const [confirmPassword, setConfirmPassword] = useState("")
  const [showPassword, setShowPassword] = useState(false)
  const [showConfirm, setShowConfirm] = useState(false)
  const [isLoading, setIsLoading] = useState(false)
  const router = useRouter()
  const supabase = createClient()

  const isPasswordSecure = passwordRequirements.every((r) => r.test(password))
  const passwordsMatch = password === confirmPassword && confirmPassword !== ""

  async function handleSubmit(e: React.FormEvent) {
    e.preventDefault()
    if (!isPasswordSecure) {
      toast.error("La contraseña no cumple los requisitos de seguridad")
      return
    }
    if (!passwordsMatch) {
      toast.error("Las contraseñas no coinciden")
      return
    }
    setIsLoading(true)
    try {
      const { error } = await supabase.auth.updateUser({ password })
      if (error) throw error
      toast.success("Contraseña actualizada correctamente")
      router.push("/dashboard")
    } catch (error: any) {
      toast.error(error.message || "No se pudo actualizar la contraseña. El enlace puede haber expirado.")
    } finally {
      setIsLoading(false)
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
            <CardTitle className="text-xl text-card-foreground">Nueva contraseña</CardTitle>
            <CardDescription>Elegí una contraseña segura para tu cuenta</CardDescription>
          </CardHeader>

          <form onSubmit={handleSubmit}>
            <CardContent className="flex flex-col gap-4">
              {/* Nueva contraseña */}
              <div className="flex flex-col gap-2">
                <Label htmlFor="password">Nueva contraseña</Label>
                <div className="relative">
                  <Input
                    id="password"
                    type={showPassword ? "text" : "password"}
                    placeholder="Mínimo 8 caracteres"
                    value={password}
                    onChange={(e) => setPassword(e.target.value)}
                    className="bg-background border-border text-foreground pr-10"
                    autoFocus
                  />
                  <button
                    type="button"
                    onClick={() => setShowPassword(!showPassword)}
                    className="absolute right-3 top-1/2 -translate-y-1/2 text-muted-foreground hover:text-foreground"
                  >
                    {showPassword ? <EyeOff className="h-4 w-4" /> : <Eye className="h-4 w-4" />}
                  </button>
                </div>

                {/* Checklist de requisitos */}
                {password && (
                  <div className="grid grid-cols-2 gap-x-2 gap-y-1 mt-1">
                    {passwordRequirements.map((req, i) => {
                      const met = req.test(password)
                      return (
                        <div key={i} className="flex items-center gap-1.5">
                          {met ? (
                            <ShieldCheck className="h-3 w-3 text-emerald-500 shrink-0" />
                          ) : (
                            <div className="h-1.5 w-1.5 rounded-full bg-slate-700 shrink-0" />
                          )}
                          <span className={`text-[10px] ${met ? "text-emerald-500 font-medium" : "text-muted-foreground"}`}>
                            {req.label}
                          </span>
                        </div>
                      )
                    })}
                  </div>
                )}
              </div>

              {/* Confirmar contraseña */}
              <div className="flex flex-col gap-2">
                <Label htmlFor="confirmPassword">Confirmar contraseña</Label>
                <div className="relative">
                  <Input
                    id="confirmPassword"
                    type={showConfirm ? "text" : "password"}
                    placeholder="Repetí tu contraseña"
                    value={confirmPassword}
                    onChange={(e) => setConfirmPassword(e.target.value)}
                    className={`bg-background text-foreground pr-10 ${
                      confirmPassword && !passwordsMatch ? "border-red-500" : "border-border"
                    }`}
                  />
                  <button
                    type="button"
                    onClick={() => setShowConfirm(!showConfirm)}
                    className="absolute right-3 top-1/2 -translate-y-1/2 text-muted-foreground hover:text-foreground"
                  >
                    {showConfirm ? <EyeOff className="h-4 w-4" /> : <Eye className="h-4 w-4" />}
                  </button>
                </div>
                {confirmPassword && !passwordsMatch && (
                  <p className="text-[10px] text-red-500 font-medium">Las contraseñas no coinciden</p>
                )}
              </div>
            </CardContent>

            <CardFooter className="flex flex-col gap-3">
              <Button type="submit" className="w-full" disabled={isLoading || !isPasswordSecure || !passwordsMatch}>
                {isLoading ? "Actualizando..." : "Actualizar contraseña"}
              </Button>
              <Link
                href="/auth/login"
                className="text-sm text-muted-foreground hover:text-primary transition-colors"
              >
                Volver al inicio de sesión
              </Link>
            </CardFooter>
          </form>
        </Card>
      </div>
    </div>
  )
}
