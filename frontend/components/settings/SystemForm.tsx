"use client"

import { useState } from "react"
import { useAuth } from "@/contexts/auth-context"
import { Button } from "@/components/ui/button"
import { Label } from "@/components/ui/label"
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card"
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select"
import { Loader2, Save, Settings2 } from "lucide-react"
import { toast } from "sonner"

// ── Static option lists ────────────────────────────────────────────────────────

const CURRENCIES = [
  { value: "ARS", label: "ARS — Peso Argentino ($)" },
  { value: "USD", label: "USD — Dólar Estadounidense ($)" },
  { value: "EUR", label: "EUR — Euro (€)" },
  { value: "BRL", label: "BRL — Real Brasileño (R$)" },
  { value: "CLP", label: "CLP — Peso Chileno ($)" },
]

const TIMEZONES = [
  { value: "America/Argentina/Buenos_Aires", label: "Argentina — Buenos Aires (UTC-3)" },
  { value: "America/Bogota",                 label: "Colombia — Bogotá (UTC-5)" },
  { value: "America/Lima",                   label: "Perú — Lima (UTC-5)" },
  { value: "America/Santiago",               label: "Chile — Santiago (UTC-4/-3)" },
  { value: "America/Montevideo",             label: "Uruguay — Montevideo (UTC-3)" },
  { value: "America/Asuncion",               label: "Paraguay — Asunción (UTC-4/-3)" },
  { value: "America/La_Paz",                 label: "Bolivia — La Paz (UTC-4)" },
  { value: "America/Guayaquil",              label: "Ecuador — Guayaquil (UTC-5)" },
  { value: "America/Caracas",                label: "Venezuela — Caracas (UTC-4)" },
  { value: "America/Mexico_City",            label: "México — Ciudad de México (UTC-6/-5)" },
  { value: "America/New_York",               label: "EE.UU. — Nueva York (UTC-5/-4)" },
  { value: "Europe/Madrid",                  label: "España — Madrid (UTC+1/+2)" },
]

const DATE_FORMATS = [
  { value: "DD/MM/YYYY", label: "DD/MM/AAAA — ej: 25/05/2026" },
  { value: "MM/DD/YYYY", label: "MM/DD/AAAA — ej: 05/25/2026" },
  { value: "YYYY-MM-DD", label: "AAAA-MM-DD — ej: 2026-05-25 (ISO)" },
]

const LANGUAGES = [
  { value: "es", label: "Español" },
  // Future: { value: "en", label: "English" }, { value: "pt", label: "Português" }
]

// ── Component ─────────────────────────────────────────────────────────────────

export function SystemForm() {
  const { user, updatePreferences } = useAuth()

  const [currency,    setCurrency]    = useState(user?.currency    ?? "ARS")
  const [timezone,    setTimezone]    = useState(user?.timezone    ?? "America/Argentina/Buenos_Aires")
  const [dateFormat,  setDateFormat]  = useState(user?.dateFormat  ?? "DD/MM/YYYY")
  const [language,    setLanguage]    = useState(user?.language    ?? "es")
  const [saving,      setSaving]      = useState(false)

  async function handleSubmit(e: React.FormEvent) {
    e.preventDefault()
    setSaving(true)
    try {
      await updatePreferences({ currency, timezone, dateFormat, language })
      toast.success("Preferencias actualizadas")
    } catch (err: any) {
      toast.error(err.message || "Error al guardar las preferencias")
    } finally {
      setSaving(false)
    }
  }

  if (!user) return null

  return (
    <Card className="border-border bg-card">
      <CardHeader className="pb-4">
        <CardTitle className="text-base text-card-foreground flex items-center gap-2">
          <Settings2 className="h-4 w-4" />
          Preferencias del sistema
        </CardTitle>
        <CardDescription>
          Configurá la moneda, zona horaria y formato de fecha que usa la plataforma.
        </CardDescription>
      </CardHeader>

      <CardContent>
        <form onSubmit={handleSubmit} className="flex flex-col gap-5">

          {/* ── Moneda ───────────────────────────────────────────────────────── */}
          <div className="flex flex-col gap-2">
            <Label htmlFor="currency" className="text-foreground">Moneda principal</Label>
            <Select value={currency} onValueChange={setCurrency}>
              <SelectTrigger id="currency" className="bg-background border-border text-foreground">
                <SelectValue placeholder="Seleccioná una moneda" />
              </SelectTrigger>
              <SelectContent>
                {CURRENCIES.map(c => (
                  <SelectItem key={c.value} value={c.value}>{c.label}</SelectItem>
                ))}
              </SelectContent>
            </Select>
            <p className="text-xs text-muted-foreground">
              Se usará como moneda por defecto en ventas, compras y gastos.
            </p>
          </div>

          {/* ── Zona horaria ─────────────────────────────────────────────────── */}
          <div className="flex flex-col gap-2">
            <Label htmlFor="timezone" className="text-foreground">Zona horaria</Label>
            <Select value={timezone} onValueChange={setTimezone}>
              <SelectTrigger id="timezone" className="bg-background border-border text-foreground">
                <SelectValue placeholder="Seleccioná tu zona horaria" />
              </SelectTrigger>
              <SelectContent>
                {TIMEZONES.map(tz => (
                  <SelectItem key={tz.value} value={tz.value}>{tz.label}</SelectItem>
                ))}
              </SelectContent>
            </Select>
          </div>

          {/* ── Formato de fecha ─────────────────────────────────────────────── */}
          <div className="flex flex-col gap-2">
            <Label className="text-foreground">Formato de fecha</Label>
            <div className="flex flex-col gap-2">
              {DATE_FORMATS.map(fmt => (
                <label
                  key={fmt.value}
                  className={`flex items-center gap-3 rounded-md border px-4 py-3 cursor-pointer transition-colors ${
                    dateFormat === fmt.value
                      ? "border-primary bg-primary/5"
                      : "border-border hover:border-muted-foreground"
                  }`}
                >
                  <input
                    type="radio"
                    name="dateFormat"
                    value={fmt.value}
                    checked={dateFormat === fmt.value}
                    onChange={() => setDateFormat(fmt.value)}
                    className="accent-primary"
                  />
                  <span className="text-sm text-foreground">{fmt.label}</span>
                </label>
              ))}
            </div>
          </div>

          {/* ── Idioma ───────────────────────────────────────────────────────── */}
          <div className="flex flex-col gap-2">
            <Label htmlFor="language" className="text-foreground">Idioma</Label>
            <Select value={language} onValueChange={setLanguage} disabled>
              <SelectTrigger id="language" className="bg-background border-border text-foreground opacity-60">
                <SelectValue />
              </SelectTrigger>
              <SelectContent>
                {LANGUAGES.map(l => (
                  <SelectItem key={l.value} value={l.value}>{l.label}</SelectItem>
                ))}
              </SelectContent>
            </Select>
            <p className="text-xs text-muted-foreground">
              Más idiomas disponibles próximamente.
            </p>
          </div>

          {/* ── Guardar ──────────────────────────────────────────────────────── */}
          <div className="flex justify-end pt-1">
            <Button type="submit" disabled={saving} className="gap-2">
              {saving
                ? <><Loader2 className="h-4 w-4 animate-spin" /> Guardando…</>
                : <><Save className="h-4 w-4" /> Guardar preferencias</>
              }
            </Button>
          </div>
        </form>
      </CardContent>
    </Card>
  )
}
