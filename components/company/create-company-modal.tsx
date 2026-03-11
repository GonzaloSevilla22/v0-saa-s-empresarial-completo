"use client"

import { useState } from "react"
import { useRouter } from "next/navigation"
import { Building2, Loader2 } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import { useCompany } from "@/contexts/company-context"
import { toast } from "sonner"

export function CreateCompanyModal() {
  const { loading, hasCompany, createCompany } = useCompany()
  const router = useRouter()
  const [name, setName] = useState("")
  const [submitting, setSubmitting] = useState(false)

  // Don't render while loading or if user already has a company
  if (loading || hasCompany) return null

  async function handleSubmit(e: React.FormEvent) {
    e.preventDefault()
    const trimmed = name.trim()
    if (trimmed.length < 2) {
      toast.error("El nombre debe tener al menos 2 caracteres")
      return
    }

    setSubmitting(true)
    const { success, error } = await createCompany(trimmed)
    setSubmitting(false)

    if (!success) {
      toast.error(error || "No se pudo crear la empresa")
      return
    }

    toast.success(`¡Empresa "${trimmed}" creada exitosamente!`)
    router.push("/dashboard")
  }

  return (
    <div className="fixed inset-0 z-[100] flex items-center justify-center bg-background/90 backdrop-blur-sm">
      <div className="w-full max-w-md mx-4">
        {/* Card */}
        <div className="rounded-2xl border border-border bg-card shadow-2xl p-8 flex flex-col gap-6">

          {/* Header */}
          <div className="flex flex-col items-center gap-3 text-center">
            <div className="flex h-14 w-14 items-center justify-center rounded-2xl bg-primary/10 border border-primary/20">
              <Building2 className="h-7 w-7 text-primary" />
            </div>
            <div>
              <h1 className="text-2xl font-bold text-foreground tracking-tight">
                Bienvenido a ALIADA
              </h1>
              <p className="text-sm text-muted-foreground mt-1">
                Para comenzar, creá tu empresa. Luego podrás gestionar productos,
                ventas e inventario desde un solo lugar.
              </p>
            </div>
          </div>

          {/* Form */}
          <form onSubmit={handleSubmit} className="flex flex-col gap-4">
            <div className="flex flex-col gap-2">
              <Label htmlFor="company-name" className="text-foreground font-medium">
                Nombre de la empresa
              </Label>
              <Input
                id="company-name"
                value={name}
                onChange={(e) => setName(e.target.value)}
                placeholder="Ej: Mi Emprendimiento S.R.L."
                className="bg-background border-border text-foreground h-11"
                disabled={submitting}
                autoFocus
                maxLength={100}
              />
            </div>

            <Button
              type="submit"
              className="w-full h-11 text-base font-semibold"
              disabled={submitting || name.trim().length < 2}
            >
              {submitting ? (
                <>
                  <Loader2 className="mr-2 h-4 w-4 animate-spin" />
                  Creando empresa...
                </>
              ) : (
                "Crear Empresa"
              )}
            </Button>
          </form>

          <p className="text-center text-xs text-muted-foreground">
            Se creará automáticamente un depósito <strong>Principal</strong> para
            gestionar tu inventario.
          </p>
        </div>
      </div>
    </div>
  )
}
