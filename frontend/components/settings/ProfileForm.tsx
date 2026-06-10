"use client"

import { useState } from "react"
import { useAuth } from "@/contexts/auth-context"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import { Textarea } from "@/components/ui/textarea"
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card"
import { Separator } from "@/components/ui/separator"
import { Loader2, Save } from "lucide-react"
import { toast } from "sonner"
import { AvatarUpload } from "./AvatarUpload"

export function ProfileForm() {
  const { user, updateProfile } = useAuth()

  const [name,         setName]         = useState(user?.name         ?? "")
  const [lastName,     setLastName]     = useState(user?.lastName     ?? "")
  const [businessName, setBusinessName] = useState(user?.businessName ?? "")
  const [phone,        setPhone]        = useState(user?.phone        ?? "")
  const [locality,     setLocality]     = useState(user?.locality     ?? "")
  const [bio,          setBio]          = useState(user?.bio          ?? "")
  const [avatarUrl,    setAvatarUrl]    = useState<string | null>(user?.avatar ?? null)
  const [saving,       setSaving]       = useState(false)

  const bioLeft = 300 - bio.length

  async function handleSubmit(e: React.FormEvent) {
    e.preventDefault()

    if (!name.trim()) {
      toast.error("El nombre es requerido")
      return
    }
    if (bio.length > 300) {
      toast.error("La biografía no puede superar 300 caracteres")
      return
    }

    setSaving(true)
    try {
      await updateProfile({
        name:         name.trim(),
        lastName:     lastName.trim()     || undefined,
        businessName: businessName.trim() || undefined,
        phone:        phone.trim()        || undefined,
        locality:     locality.trim()     || undefined,
        bio:          bio.trim()          || undefined,
        avatarUrl:    avatarUrl           ?? undefined,
      })
      toast.success("Perfil actualizado correctamente")
    } catch (err: any) {
      toast.error(err.message || "Error al guardar el perfil")
    } finally {
      setSaving(false)
    }
  }

  if (!user) return null

  return (
    <Card className="border-border bg-card">
      <CardHeader className="pb-4">
        <CardTitle className="text-base text-card-foreground">Información personal</CardTitle>
        <CardDescription>Tu nombre y datos de contacto visibles en la plataforma.</CardDescription>
      </CardHeader>

      <CardContent>
        <form onSubmit={handleSubmit} className="flex flex-col gap-6">

          {/* ── Avatar ─────────────────────────────────────────────────────── */}
          <div className="flex justify-center">
            <AvatarUpload
              userId={user.id}
              currentUrl={avatarUrl ?? undefined}
              onUpload={url => setAvatarUrl(url)}
            />
          </div>

          <Separator className="bg-border" />

          {/* ── Nombre y apellido ───────────────────────────────────────────── */}
          <div className="grid gap-4 grid-cols-1 sm:grid-cols-2">
            <div className="flex flex-col gap-2">
              <Label htmlFor="name" className="text-foreground">
                Nombre <span className="text-destructive">*</span>
              </Label>
              <Input
                id="name"
                value={name}
                onChange={e => setName(e.target.value)}
                placeholder="Tu nombre"
                maxLength={50}
                className="bg-background border-border text-foreground"
                required
              />
            </div>
            <div className="flex flex-col gap-2">
              <Label htmlFor="lastName" className="text-foreground">Apellido</Label>
              <Input
                id="lastName"
                value={lastName}
                onChange={e => setLastName(e.target.value)}
                placeholder="Tu apellido"
                maxLength={50}
                className="bg-background border-border text-foreground"
              />
            </div>
          </div>

          {/* ── Negocio y teléfono ──────────────────────────────────────────── */}
          <div className="grid gap-4 grid-cols-1 sm:grid-cols-2">
            <div className="flex flex-col gap-2">
              <Label htmlFor="businessName" className="text-foreground">Nombre del negocio</Label>
              <Input
                id="businessName"
                value={businessName}
                onChange={e => setBusinessName(e.target.value)}
                placeholder="Ej: Tienda La Favorita"
                maxLength={100}
                className="bg-background border-border text-foreground"
              />
            </div>
            <div className="flex flex-col gap-2">
              <Label htmlFor="phone" className="text-foreground">Teléfono</Label>
              <Input
                id="phone"
                type="tel"
                value={phone}
                onChange={e => setPhone(e.target.value)}
                placeholder="+54 9 11 1234-5678"
                maxLength={30}
                className="bg-background border-border text-foreground"
              />
            </div>
          </div>

          {/* ── Localidad ───────────────────────────────────────────────────── */}
          <div className="grid gap-4 grid-cols-1 sm:grid-cols-2">
            <div className="flex flex-col gap-2">
              <Label htmlFor="locality" className="text-foreground">Localidad</Label>
              <Input
                id="locality"
                value={locality}
                onChange={e => setLocality(e.target.value)}
                placeholder="Ej: Godoy Cruz, Mendoza"
                maxLength={80}
                className="bg-background border-border text-foreground"
              />
            </div>
          </div>

          {/* ── Biografía ───────────────────────────────────────────────────── */}
          <div className="flex flex-col gap-2">
            <div className="flex items-center justify-between">
              <Label htmlFor="bio" className="text-foreground">Biografía</Label>
              <span className={`text-xs ${bioLeft < 20 ? "text-yellow-500" : "text-muted-foreground"}`}>
                {bioLeft} caracteres restantes
              </span>
            </div>
            <Textarea
              id="bio"
              value={bio}
              onChange={e => setBio(e.target.value)}
              placeholder="Contá brevemente de qué se trata tu negocio…"
              maxLength={300}
              rows={3}
              className="bg-background border-border text-foreground resize-none"
            />
          </div>

          {/* ── Guardar ─────────────────────────────────────────────────────── */}
          <div className="flex justify-end">
            <Button type="submit" disabled={saving} className="gap-2">
              {saving
                ? <><Loader2 className="h-4 w-4 animate-spin" /> Guardando…</>
                : <><Save className="h-4 w-4" /> Guardar cambios</>
              }
            </Button>
          </div>
        </form>
      </CardContent>
    </Card>
  )
}
