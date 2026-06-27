"use client"

import { useRef, useState } from "react"
import { useRouter } from "next/navigation"
import Link from "next/link"
import { useAuth } from "@/contexts/auth-context"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import { Checkbox } from "@/components/ui/checkbox"
import { Card, CardContent, CardDescription, CardFooter, CardHeader, CardTitle } from "@/components/ui/card"
import { Eye, EyeOff, ShieldCheck, RefreshCw } from "lucide-react"
import { toast } from "sonner"
import { CaptchaWidget, type CaptchaWidgetHandle } from "@/components/auth/CaptchaWidget"
import { TERMS_VERSION, LEGAL_ROUTES } from "@/lib/legal"

export default function RegisterPage() {
  const [name, setName] = useState("")
  const [lastName, setLastName] = useState("")
  const [email, setEmail] = useState("")
  const [phone, setPhone] = useState("")
  const [locality, setLocality] = useState("")
  const [password, setPassword] = useState("")
  const [confirmPassword, setConfirmPassword] = useState("")
  const [showPassword, setShowPassword] = useState(false)
  const [showConfirmPassword, setShowConfirmPassword] = useState(false)
  const [acceptedTerms, setAcceptedTerms] = useState(false)
  const [emailOptIn, setEmailOptIn] = useState(false)
  const [captchaToken, setCaptchaToken] = useState("")
  const { register } = useAuth()
  const router = useRouter()
  const captchaRef = useRef<CaptchaWidgetHandle>(null)

  const [isLoading, setIsLoading] = useState(false)

  const passwordRequirements = [
    { label: "Mínimo 8 caracteres", test: (p: string) => p.length >= 8 },
    { label: "Al menos 1 número", test: (p: string) => /\d/.test(p) },
    { label: "Al menos 1 letra", test: (p: string) => /[a-zA-Z]/.test(p) },
    { label: "Al menos 1 mayúscula", test: (p: string) => /[A-Z]/.test(p) },
    { label: "Al menos 1 símbolo", test: (p: string) => /[!@#$%^&*(),.?":{}|<>]/.test(p) },
  ]

  const isPasswordSecure = passwordRequirements.every(req => req.test(password))
  const passwordsMatch = password === confirmPassword && confirmPassword !== ""

  const generateSecurePassword = () => {
    const upper = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
    const digits = "0123456789"
    const symbols = "!@#$%^&*()"
    const all = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!@#$%^&*()"
    const rand = (str: string) => str[crypto.getRandomValues(new Uint32Array(1))[0] % str.length]
    const randAll = () => Array.from(crypto.getRandomValues(new Uint8Array(9))).map(b => all[b % all.length]).join("")
    // Ensure at least one of each required character type, then fill the rest
    const parts = [rand(upper), rand(digits), rand(symbols), ...randAll()]
    // Shuffle using Fisher-Yates with crypto random
    const arr = parts
    for (let i = arr.length - 1; i > 0; i--) {
      const j = crypto.getRandomValues(new Uint32Array(1))[0] % (i + 1);
      [arr[i], arr[j]] = [arr[j], arr[i]]
    }
    const newPass = arr.join("")
    setPassword(newPass)
    setConfirmPassword(newPass)
  }

  async function handleSubmit(e: React.FormEvent) {
    e.preventDefault()
    if (!name.trim()) {
      toast.error("El nombre es obligatorio")
      return
    }
    if (!lastName.trim()) {
      toast.error("El apellido es obligatorio")
      return
    }
    if (!phone.trim()) {
      toast.error("El teléfono es obligatorio")
      return
    }
    if (!locality.trim()) {
      toast.error("La localidad es obligatoria")
      return
    }
    if (!isPasswordSecure) {
      toast.error("La contraseña no cumple con los requisitos de seguridad")
      return
    }
    if (!passwordsMatch) {
      toast.error("Las contraseñas no coinciden")
      return
    }
    if (!acceptedTerms) {
      toast.error("Debés aceptar los Términos y Condiciones para crear la cuenta")
      return
    }
    if (!captchaToken) {
      toast.error("Completá la verificación anti-bots para continuar")
      return
    }
    setIsLoading(true)
    try {
      await register(name.trim(), email, password, {
        phone: phone.trim(),
        locality: locality.trim(),
        lastName: lastName.trim(),
        termsVersion: TERMS_VERSION,
        emailOptIn,
        captchaToken,
      })
      // Go directly to the verification screen — no intermediate /dashboard hop.
      // The middleware would catch it anyway, but going direct avoids the extra redirect.
      router.push(`/auth/verify-email?email=${encodeURIComponent(email)}`)
    } catch (error: unknown) {
      // El token de captcha es de un solo uso: tras un signUp fallido (incluido el
      // rechazo del captcha por Supabase) reseteamos el widget para re-challenge.
      captchaRef.current?.reset()
      setCaptchaToken("")
      toast.error(error instanceof Error ? error.message : "No se pudo crear la cuenta")
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

        <Card className="border-border bg-card">
          <CardHeader className="text-center">
            <CardTitle className="text-xl text-card-foreground">Crear cuenta</CardTitle>
            <CardDescription>Registrate para empezar a gestionar tu negocio</CardDescription>
          </CardHeader>
          <form onSubmit={handleSubmit} data-testid="register-form">
            <CardContent className="flex flex-col gap-4">
              <div className="grid grid-cols-1 gap-4 sm:grid-cols-2">
                <div className="flex flex-col gap-2">
                  <Label htmlFor="name" className="text-foreground">Nombre</Label>
                  <Input
                    id="name"
                    placeholder="Tu nombre"
                    value={name}
                    onChange={(e) => setName(e.target.value)}
                    className="bg-background border-border text-foreground"
                  />
                </div>
                <div className="flex flex-col gap-2">
                  <Label htmlFor="lastName" className="text-foreground">Apellido</Label>
                  <Input
                    id="lastName"
                    placeholder="Tu apellido"
                    value={lastName}
                    onChange={(e) => setLastName(e.target.value)}
                    className="bg-background border-border text-foreground"
                  />
                </div>
              </div>
              <div className="flex flex-col gap-2">
                <Label htmlFor="email" className="text-foreground">Email</Label>
                <Input
                  id="email"
                  type="email"
                  placeholder="tu@email.com"
                  value={email}
                  onChange={(e) => setEmail(e.target.value)}
                  className="bg-background border-border text-foreground"
                />
              </div>
              <div className="flex flex-col gap-2">
                <Label htmlFor="phone" className="text-foreground">Teléfono</Label>
                <Input
                  id="phone"
                  type="tel"
                  required
                  placeholder="+54 9 261 5555555"
                  value={phone}
                  onChange={(e) => setPhone(e.target.value)}
                  className="bg-background border-border text-foreground"
                />
              </div>
              <div className="flex flex-col gap-2">
                <Label htmlFor="locality" className="text-foreground">Localidad</Label>
                <Input
                  id="locality"
                  required
                  placeholder="Ej: Godoy Cruz, Mendoza"
                  value={locality}
                  onChange={(e) => setLocality(e.target.value)}
                  className="bg-background border-border text-foreground"
                />
              </div>
              <div className="flex flex-col gap-2">
                <div className="flex items-center justify-between">
                  <Label htmlFor="password">Contraseña</Label>
                  <Button
                    type="button"
                    variant="ghost"
                    size="sm"
                    className="h-7 text-[10px] gap-1 px-2"
                    onClick={generateSecurePassword}
                  >
                    <RefreshCw className="h-3 w-3" />
                    Generar segura
                  </Button>
                </div>
                <div className="relative">
                  <Input
                    id="password"
                    type={showPassword ? "text" : "password"}
                    placeholder="Mínimo 8 caracteres"
                    value={password}
                    onChange={(e) => setPassword(e.target.value)}
                    className="bg-background border-border text-foreground pr-10"
                  />
                  <button
                    type="button"
                    onClick={() => setShowPassword(!showPassword)}
                    className="absolute right-3 top-1/2 -translate-y-1/2 text-muted-foreground hover:text-foreground"
                  >
                    {showPassword ? <EyeOff className="h-4 w-4" /> : <Eye className="h-4 w-4" />}
                  </button>
                </div>

                {/* Strength Checklist */}
                <div className="grid grid-cols-2 gap-x-2 gap-y-1 mt-1">
                  {passwordRequirements.map((req, i) => {
                    const met = req.test(password)
                    return (
                      <div key={i} className="flex items-center gap-1.5">
                        {met ? (
                          <ShieldCheck className="h-3 w-3 text-emerald-500" />
                        ) : (
                          <div className="h-1.5 w-1.5 rounded-full bg-slate-700" />
                        )}
                        <span className={`text-[10px] ${met ? "text-emerald-500 font-medium" : "text-muted-foreground"}`}>
                          {req.label}
                        </span>
                      </div>
                    )
                  })}
                </div>
              </div>

              <div className="flex flex-col gap-2">
                <Label htmlFor="confirmPassword">Confirmar contraseña</Label>
                <div className="relative">
                  <Input
                    id="confirmPassword"
                    type={showConfirmPassword ? "text" : "password"}
                    placeholder="Repetí tu contraseña"
                    value={confirmPassword}
                    onChange={(e) => setConfirmPassword(e.target.value)}
                    className={`bg-background text-foreground pr-10 ${confirmPassword && !passwordsMatch ? "border-red-500" : "border-border"
                      }`}
                  />
                  <button
                    type="button"
                    onClick={() => setShowConfirmPassword(!showConfirmPassword)}
                    className="absolute right-3 top-1/2 -translate-y-1/2 text-muted-foreground hover:text-foreground"
                  >
                    {showConfirmPassword ? <EyeOff className="h-4 w-4" /> : <Eye className="h-4 w-4" />}
                  </button>
                </div>
                {confirmPassword && !passwordsMatch && (
                  <p className="text-[10px] text-red-500 font-medium">Las contraseñas no coinciden</p>
                )}
              </div>

              {/* Consentimiento legal (obligatorio) */}
              <div className="flex items-start gap-2">
                <Checkbox
                  id="terms"
                  data-testid="terms-checkbox"
                  checked={acceptedTerms}
                  onCheckedChange={(v) => setAcceptedTerms(v === true)}
                  className="mt-0.5"
                />
                <Label htmlFor="terms" className="text-xs font-normal leading-snug text-muted-foreground">
                  Acepto los{" "}
                  <Link href={LEGAL_ROUTES.terms} className="text-primary underline-offset-4 hover:underline">
                    Términos y Condiciones
                  </Link>{" "}
                  y la{" "}
                  <Link href={LEGAL_ROUTES.privacy} className="text-primary underline-offset-4 hover:underline">
                    Política de Privacidad
                  </Link>
                </Label>
              </div>

              {/* Opt-in de notificaciones (opcional, desmarcado por defecto) */}
              <div className="flex items-start gap-2">
                <Checkbox
                  id="emailOptIn"
                  data-testid="email-optin-checkbox"
                  checked={emailOptIn}
                  onCheckedChange={(v) => setEmailOptIn(v === true)}
                  className="mt-0.5"
                />
                <Label htmlFor="emailOptIn" className="text-xs font-normal leading-snug text-muted-foreground">
                  Quiero recibir novedades y avisos de cambios de Aliadata por email (opcional)
                </Label>
              </div>

              {/* Captcha anti-bots (Cloudflare Turnstile) */}
              <CaptchaWidget
                ref={captchaRef}
                onVerify={setCaptchaToken}
                onExpire={() => setCaptchaToken("")}
                onError={() => setCaptchaToken("")}
              />
            </CardContent>
            <CardFooter className="flex flex-col gap-4">
              <Button type="submit" className="w-full" disabled={!captchaToken || isLoading}>
                {isLoading ? "Creando cuenta..." : "Crear cuenta"}
              </Button>
              <p className="text-sm text-muted-foreground">
                {"¿Ya tenés cuenta? "}
                <Link href="/auth/login" className="text-primary underline-offset-4 hover:underline">
                  Iniciá sesión
                </Link>
              </p>
            </CardFooter>
          </form>
        </Card>
      </div>
    </div>
  )
}
