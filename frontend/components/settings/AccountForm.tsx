"use client"

import { useState } from "react"
import { useAuth } from "@/contexts/auth-context"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card"
import { Separator } from "@/components/ui/separator"
import { Eye, EyeOff, Loader2, LogOut, Mail, ShieldCheck } from "lucide-react"
import { toast } from "sonner"

// ── Password strength rules (same as register) ────────────────────────────────
const PASSWORD_REQS = [
  { label: "Mínimo 8 caracteres",  test: (p: string) => p.length >= 8 },
  { label: "Al menos 1 número",    test: (p: string) => /\d/.test(p) },
  { label: "Al menos 1 letra",     test: (p: string) => /[a-zA-Z]/.test(p) },
  { label: "Al menos 1 mayúscula", test: (p: string) => /[A-Z]/.test(p) },
  { label: "Al menos 1 símbolo",   test: (p: string) => /[!@#$%^&*(),.?":{}|<>]/.test(p) },
]

export function AccountForm() {
  const { user, changeEmail, changePassword, closeAllSessions } = useAuth()

  // ── Email change state ─────────────────────────────────────────────────────
  const [newEmail,       setNewEmail]       = useState("")
  const [savingEmail,    setSavingEmail]    = useState(false)

  // ── Password change state ─────────────────────────────────────────────────
  const [newPassword,    setNewPassword]    = useState("")
  const [confirmPass,    setConfirmPass]    = useState("")
  const [showNew,        setShowNew]        = useState(false)
  const [showConfirm,    setShowConfirm]    = useState(false)
  const [savingPass,     setSavingPass]     = useState(false)

  // ── Session close state ───────────────────────────────────────────────────
  const [closingSessions, setClosingSessions] = useState(false)

  const isPasswordSecure = PASSWORD_REQS.every(r => r.test(newPassword))
  const passwordsMatch   = newPassword === confirmPass && confirmPass !== ""

  // ── Handlers ──────────────────────────────────────────────────────────────

  async function handleEmailChange(e: React.FormEvent) {
    e.preventDefault()
    if (!newEmail.trim() || newEmail === user?.email) {
      toast.error("Ingresá un email diferente al actual")
      return
    }
    setSavingEmail(true)
    try {
      await changeEmail(newEmail.trim())
      toast.success(
        "Se envió un enlace de confirmación a " + newEmail +
        ". Tu email actual sigue activo hasta que confirmes el cambio."
      )
      setNewEmail("")
    } catch (err: any) {
      toast.error(err.message || "Error al solicitar el cambio de email")
    } finally {
      setSavingEmail(false)
    }
  }

  async function handlePasswordChange(e: React.FormEvent) {
    e.preventDefault()
    if (!isPasswordSecure) {
      toast.error("La contraseña no cumple los requisitos de seguridad")
      return
    }
    if (!passwordsMatch) {
      toast.error("Las contraseñas no coinciden")
      return
    }
    setSavingPass(true)
    try {
      await changePassword(newPassword)
      toast.success("Contraseña actualizada correctamente")
      setNewPassword("")
      setConfirmPass("")
    } catch (err: any) {
      toast.error(err.message || "Error al actualizar la contraseña")
    } finally {
      setSavingPass(false)
    }
  }

  async function handleCloseAllSessions() {
    if (!confirm("Esto cerrará sesión en todos tus dispositivos, incluyendo este. ¿Querés continuar?")) return
    setClosingSessions(true)
    try {
      await closeAllSessions()
      // closeAllSessions() redirects to /auth/login — no further action needed
    } catch (err: any) {
      toast.error(err.message || "Error al cerrar las sesiones")
      setClosingSessions(false)
    }
  }

  if (!user) return null

  return (
    <div className="flex flex-col gap-4">

      {/* ── Cambiar email ──────────────────────────────────────────────────── */}
      <Card className="border-border bg-card">
        <CardHeader className="pb-4">
          <CardTitle className="text-base text-card-foreground flex items-center gap-2">
            <Mail className="h-4 w-4" />
            Cambiar email
          </CardTitle>
          <CardDescription>
            Email actual: <span className="font-medium text-foreground">{user.email}</span>
            <br />
            Recibirás un enlace de confirmación en el nuevo email antes de que el cambio sea efectivo.
          </CardDescription>
        </CardHeader>
        <CardContent>
          <form onSubmit={handleEmailChange} className="flex flex-col gap-4">
            <div className="flex flex-col gap-2">
              <Label htmlFor="newEmail" className="text-foreground">Nuevo email</Label>
              <Input
                id="newEmail"
                type="email"
                value={newEmail}
                onChange={e => setNewEmail(e.target.value)}
                placeholder="nuevo@email.com"
                className="bg-background border-border text-foreground"
                required
              />
            </div>
            <div className="flex justify-end">
              <Button type="submit" variant="outline" disabled={savingEmail} className="border-border gap-2">
                {savingEmail
                  ? <><Loader2 className="h-4 w-4 animate-spin" /> Enviando…</>
                  : "Solicitar cambio de email"
                }
              </Button>
            </div>
          </form>
        </CardContent>
      </Card>

      {/* ── Cambiar contraseña ─────────────────────────────────────────────── */}
      <Card className="border-border bg-card">
        <CardHeader className="pb-4">
          <CardTitle className="text-base text-card-foreground flex items-center gap-2">
            <ShieldCheck className="h-4 w-4" />
            Cambiar contraseña
          </CardTitle>
          <CardDescription>
            Elegí una contraseña segura. Requiere sesión activa.
          </CardDescription>
        </CardHeader>
        <CardContent>
          <form onSubmit={handlePasswordChange} className="flex flex-col gap-4">
            {/* Nueva contraseña */}
            <div className="flex flex-col gap-2">
              <Label htmlFor="newPassword" className="text-foreground">Nueva contraseña</Label>
              <div className="relative">
                <Input
                  id="newPassword"
                  type={showNew ? "text" : "password"}
                  value={newPassword}
                  onChange={e => setNewPassword(e.target.value)}
                  placeholder="Mínimo 8 caracteres"
                  className="bg-background border-border text-foreground pr-10"
                />
                <button
                  type="button"
                  onClick={() => setShowNew(v => !v)}
                  className="absolute right-3 top-1/2 -translate-y-1/2 text-muted-foreground hover:text-foreground"
                >
                  {showNew ? <EyeOff className="h-4 w-4" /> : <Eye className="h-4 w-4" />}
                </button>
              </div>
              {/* Strength checklist */}
              {newPassword && (
                <div className="grid grid-cols-2 gap-x-2 gap-y-1 mt-1">
                  {PASSWORD_REQS.map((req, i) => {
                    const met = req.test(newPassword)
                    return (
                      <div key={i} className="flex items-center gap-1.5">
                        {met
                          ? <ShieldCheck className="h-3 w-3 text-emerald-500 shrink-0" />
                          : <div className="h-1.5 w-1.5 rounded-full bg-slate-700 shrink-0" />
                        }
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
              <Label htmlFor="confirmPass" className="text-foreground">Confirmar contraseña</Label>
              <div className="relative">
                <Input
                  id="confirmPass"
                  type={showConfirm ? "text" : "password"}
                  value={confirmPass}
                  onChange={e => setConfirmPass(e.target.value)}
                  placeholder="Repetí la contraseña"
                  className={`bg-background text-foreground pr-10 ${
                    confirmPass && !passwordsMatch ? "border-destructive" : "border-border"
                  }`}
                />
                <button
                  type="button"
                  onClick={() => setShowConfirm(v => !v)}
                  className="absolute right-3 top-1/2 -translate-y-1/2 text-muted-foreground hover:text-foreground"
                >
                  {showConfirm ? <EyeOff className="h-4 w-4" /> : <Eye className="h-4 w-4" />}
                </button>
              </div>
              {confirmPass && !passwordsMatch && (
                <p className="text-[10px] text-destructive font-medium">Las contraseñas no coinciden</p>
              )}
            </div>

            <div className="flex justify-end">
              <Button
                type="submit"
                variant="outline"
                disabled={savingPass || !isPasswordSecure || !passwordsMatch}
                className="border-border gap-2"
              >
                {savingPass
                  ? <><Loader2 className="h-4 w-4 animate-spin" /> Actualizando…</>
                  : "Actualizar contraseña"
                }
              </Button>
            </div>
          </form>
        </CardContent>
      </Card>

      {/* ── Cerrar todas las sesiones ──────────────────────────────────────── */}
      <Card className="border-destructive/30 bg-card">
        <CardHeader className="pb-4">
          <CardTitle className="text-base text-card-foreground flex items-center gap-2">
            <LogOut className="h-4 w-4 text-destructive" />
            Cerrar todas las sesiones
          </CardTitle>
          <CardDescription>
            Cerrará sesión en todos tus dispositivos, incluyendo este.
            Tendrás que volver a iniciar sesión.
          </CardDescription>
        </CardHeader>
        <CardContent>
          <Button
            type="button"
            variant="outline"
            disabled={closingSessions}
            onClick={handleCloseAllSessions}
            className="border-destructive/50 text-destructive hover:bg-destructive/10 hover:border-destructive gap-2"
          >
            {closingSessions
              ? <><Loader2 className="h-4 w-4 animate-spin" /> Cerrando sesiones…</>
              : <><LogOut className="h-4 w-4" /> Cerrar todas las sesiones</>
            }
          </Button>
        </CardContent>
      </Card>
    </div>
  )
}
