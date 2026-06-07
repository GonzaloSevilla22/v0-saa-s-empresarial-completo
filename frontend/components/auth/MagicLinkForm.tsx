"use client"

import { useState } from "react"
import { useAuth } from "@/contexts/auth-context"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import { AlertCircle, CheckCircle2, Loader2, Mail } from "lucide-react"
import { Alert, AlertDescription, AlertTitle } from "@/components/ui/alert"

interface MagicLinkFormProps {
  onBack: () => void
}

export function MagicLinkForm({ onBack }: MagicLinkFormProps) {
  const [email, setEmail] = useState("")
  const [isLoading, setIsLoading] = useState(false)
  const [isSuccess, setIsSuccess] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const { loginWithMagicLink } = useAuth()

  async function handleSubmit(e: React.FormEvent) {
    e.preventDefault()
    if (!email) return

    setIsLoading(true)
    setError(null)
    
    try {
      await loginWithMagicLink(email)
      setIsSuccess(true)
    } catch (err: any) {
      setError(err.message || "Ocurrió un error al enviar el enlace.")
    } finally {
      setIsLoading(false)
    }
  }

  if (isSuccess) {
    return (
      <div className="flex flex-col gap-6 py-4">
        <Alert className="bg-primary/10 border-primary/20">
          <CheckCircle2 className="h-5 w-5 text-primary" />
          <AlertTitle className="text-primary font-semibold">¡Enlace enviado!</AlertTitle>
          <AlertDescription className="text-primary/80">
            Revisá tu bandeja de entrada. Te enviamos un enlace para que puedas iniciar sesión de forma segura.
          </AlertDescription>
        </Alert>
        <Button variant="outline" onClick={onBack} className="w-full">
          Volver al inicio
        </Button>
      </div>
    )
  }

  return (
    <form onSubmit={handleSubmit} className="flex flex-col gap-4">
      <div className="flex flex-col gap-2">
        <Label htmlFor="magic-email" className="text-foreground">Email</Label>
        <div className="relative">
          <Input
            id="magic-email"
            type="email"
            placeholder="tu@email.com"
            value={email}
            onChange={(e) => setEmail(e.target.value)}
            className="bg-background border-border text-foreground pl-10"
            required
            disabled={isLoading}
          />
          <Mail className="absolute left-3 top-1/2 -translate-y-1/2 h-4 w-4 text-muted-foreground" />
        </div>
      </div>

      {error && (
        <Alert variant="destructive">
          <AlertCircle className="h-4 w-4" />
          <AlertDescription>{error}</AlertDescription>
        </Alert>
      )}

      <div className="flex flex-col gap-3 pt-2">
        <Button type="submit" className="w-full" disabled={isLoading || !email}>
          {isLoading ? (
            <>
              <Loader2 className="mr-2 h-4 w-4 animate-spin" />
              Enviando...
            </>
          ) : (
            "Enviar enlace mágico"
          )}
        </Button>
        <Button type="button" variant="ghost" onClick={onBack} className="w-full text-muted-foreground" disabled={isLoading}>
          Cancelar
        </Button>
      </div>
      
      <p className="text-xs text-center text-muted-foreground mt-2">
        Te enviaremos un correo con un enlace de acceso directo. Sin contraseñas.
      </p>
    </form>
  )
}
