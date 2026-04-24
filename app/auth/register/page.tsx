"use client"

import { useState } from "react"
import { useRouter } from "next/navigation"
import Link from "next/link"
import { useAuth } from "@/contexts/auth-context"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import { Card, CardContent, CardDescription, CardFooter, CardHeader, CardTitle } from "@/components/ui/card"
import { Zap, Eye, EyeOff, ShieldCheck, ShieldAlert, RefreshCw } from "lucide-react"
import { toast } from "sonner"

export default function RegisterPage() {
  const [name, setName] = useState("")
  const [email, setEmail] = useState("")
  const [password, setPassword] = useState("")
  const [confirmPassword, setConfirmPassword] = useState("")
  const [showPassword, setShowPassword] = useState(false)
  const [showConfirmPassword, setShowConfirmPassword] = useState(false)
  const { register } = useAuth()
  const router = useRouter()

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
    if (!isPasswordSecure) {
      toast.error("La contraseña no cumple con los requisitos de seguridad")
      return
    }
    if (!passwordsMatch) {
      toast.error("Las contraseñas no coinciden")
      return
    }
    setIsLoading(true)
    try {
      await register(name || "Emprendedor", email, password)
      router.push("/dashboard")
    } catch (error: any) {
      toast.error(error.message)
    } finally {
      setIsLoading(false)
    }
  }

  return (
    <div className="flex min-h-svh items-center justify-center bg-background p-4">
      <div className="w-full max-w-md">
        <div className="flex flex-col items-center gap-4">
          <div className="flex h-16 w-16 items-center justify-center rounded-xl overflow-hidden">
            <img src="/aliada-logo.png" alt="Logo" className="h-full w-full object-contain" />
          </div>
          <h1 className="text-2xl font-bold tracking-tight text-foreground">ALIADA</h1>
          <p className="text-sm text-muted-foreground">Emprender es Inteligente</p>
        </div>

        <Card className="border-border bg-card">
          <CardHeader className="text-center">
            <CardTitle className="text-xl text-card-foreground">Crear cuenta</CardTitle>
            <CardDescription>Registrate para empezar a gestionar tu negocio</CardDescription>
          </CardHeader>
          <form onSubmit={handleSubmit}>
            <CardContent className="flex flex-col gap-4">
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
            </CardContent>
            <CardFooter className="flex flex-col gap-4">
              <Button type="submit" className="w-full">
                Crear cuenta
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
