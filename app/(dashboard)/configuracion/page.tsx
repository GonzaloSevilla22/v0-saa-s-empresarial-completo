"use client"

import { useAuth } from "@/contexts/auth-context"
import { useData } from "@/contexts/data-context"
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card"
import { Button } from "@/components/ui/button"
import { Badge } from "@/components/ui/badge"
import { Separator } from "@/components/ui/separator"
import { Crown, Check, X, User, Package, Users, Sparkles } from "lucide-react"
import { MAX_PRODUCTS_FREE, MAX_CLIENTS_FREE, MAX_INSIGHTS_FREE } from "@/lib/constants"

const features = [
  { name: "Productos", free: `Hasta ${MAX_PRODUCTS_FREE}`, pro: "Ilimitados" },
  { name: "Clientes", free: `Hasta ${MAX_CLIENTS_FREE}`, pro: "Ilimitados" },
  { name: "Consejos AI", free: `${MAX_INSIGHTS_FREE} por sesión`, pro: "Ilimitados" },
  { name: "Simulador AI", free: "Limitado", pro: "Completo" },
  { name: "Comunidad", free: "Solo lectura", pro: "Completo" },
  { name: "Cursos", free: "Básicos", pro: "Todos" },
  { name: "Predicción de stock", free: false, pro: true },
  { name: "Exportación de datos", free: false, pro: true },
  { name: "Soporte prioritario", free: false, pro: true },
]

export default function ConfiguracionPage() {
  const { user, upgradePlan, downgradePlan } = useAuth()
  const { products, clients } = useData()
  const isPro = user?.plan === "pro"

  return (
    <div className="flex flex-col gap-6 max-w-4xl">
      <div>
        <h1 className="text-2xl font-bold text-foreground tracking-tight">Configuración</h1>
        <p className="text-sm text-muted-foreground mt-1">Gestioná tu cuenta y plan</p>
      </div>

      <Card className="border-border bg-card">
        <CardHeader className="pb-3">
          <CardTitle className="flex items-center gap-2 text-sm text-card-foreground">
            <User className="h-4 w-4" />
            Perfil
          </CardTitle>
        </CardHeader>
        <CardContent className="flex flex-col gap-3">
          <div className="flex items-center justify-between">
            <span className="text-sm text-muted-foreground">Nombre</span>
            <span className="text-sm text-foreground font-medium">{user?.name}</span>
          </div>
          <Separator className="bg-border" />
          <div className="flex items-center justify-between">
            <span className="text-sm text-muted-foreground">Email</span>
            <span className="text-sm text-foreground font-medium">{user?.email}</span>
          </div>
          <Separator className="bg-border" />
          <div className="flex items-center justify-between">
            <span className="text-sm text-muted-foreground">Plan</span>
            <Badge className={isPro ? "bg-yellow-500/20 text-yellow-500 border-yellow-500/30" : "bg-secondary text-muted-foreground"}>
              {isPro && <Crown className="h-3 w-3 mr-1" />}
              {isPro ? "Pro" : "Gratuito"}
            </Badge>
          </div>
        </CardContent>
      </Card>

      <Card className="border-border bg-card">
        <CardHeader className="pb-3">
          <CardTitle className="text-sm text-card-foreground">Uso actual</CardTitle>
        </CardHeader>
        <CardContent className="flex flex-col gap-3">
          <UsageStat icon={Package} label="Productos" current={products.length} max={isPro ? Infinity : MAX_PRODUCTS_FREE} />
          <UsageStat icon={Users} label="Clientes" current={clients.length} max={isPro ? Infinity : MAX_CLIENTS_FREE} />
          <UsageStat icon={Sparkles} label="Consejos" current={5} max={isPro ? Infinity : MAX_INSIGHTS_FREE} />
        </CardContent>
      </Card>

      <div className="grid gap-4 grid-cols-1 md:grid-cols-2">
        <Card className={`border-border bg-card ${!isPro ? "ring-1 ring-primary/30" : ""}`}>
          <CardHeader className="pb-3">
            <div className="flex items-center justify-between">
              <CardTitle className="text-lg text-card-foreground">Gratis</CardTitle>
              {!isPro && <Badge className="bg-primary/20 text-primary">Plan actual</Badge>}
            </div>
            <p className="text-2xl font-bold text-card-foreground">$0<span className="text-sm font-normal text-muted-foreground">/mes</span></p>
          </CardHeader>
          <CardContent className="flex flex-col gap-2">
            {features.map((f) => (
              <div key={f.name} className="flex items-center gap-2 text-sm">
                {typeof f.free === "boolean" ? (
                  f.free ? <Check className="h-4 w-4 text-primary shrink-0" /> : <X className="h-4 w-4 text-muted-foreground/50 shrink-0" />
                ) : (
                  <Check className="h-4 w-4 text-primary shrink-0" />
                )}
                <span className="text-muted-foreground">{f.name}</span>
                {typeof f.free === "string" && <span className="ml-auto text-xs text-muted-foreground/70">{f.free}</span>}
              </div>
            ))}
            {isPro && (
              <Button onClick={downgradePlan} variant="outline" size="sm" className="mt-3 border-border text-muted-foreground">
                Cambiar a Gratis
              </Button>
            )}
          </CardContent>
        </Card>

        <Card className={`border-yellow-500/30 bg-card ${isPro ? "ring-1 ring-yellow-500/30" : ""}`}>
          <CardHeader className="pb-3">
            <div className="flex items-center justify-between">
              <CardTitle className="flex items-center gap-1.5 text-lg text-card-foreground">
                <Crown className="h-4 w-4 text-yellow-500" />
                Pro
              </CardTitle>
              {isPro && <Badge className="bg-yellow-500/20 text-yellow-500">Plan actual</Badge>}
            </div>
            <p className="text-2xl font-bold text-card-foreground">$29<span className="text-sm font-normal text-muted-foreground">/mes</span></p>
          </CardHeader>
          <CardContent className="flex flex-col gap-2">
            {features.map((f) => (
              <div key={f.name} className="flex items-center gap-2 text-sm">
                <Check className="h-4 w-4 text-yellow-500 shrink-0" />
                <span className="text-card-foreground">{f.name}</span>
                {typeof f.pro === "string" && <span className="ml-auto text-xs text-yellow-500/70">{f.pro}</span>}
              </div>
            ))}
            {!isPro && (
              <Button onClick={upgradePlan} size="sm" className="mt-3 bg-yellow-500 text-yellow-950 hover:bg-yellow-400">
                <Crown className="h-3.5 w-3.5 mr-1" />
                Actualizar a Pro
              </Button>
            )}
          </CardContent>
        </Card>
      </div>
    </div>
  )
}

function UsageStat({ icon: Icon, label, current, max }: { icon: typeof Package; label: string; current: number; max: number }) {
  const isUnlimited = max === Infinity
  const percentage = isUnlimited ? 30 : (current / max) * 100
  const isWarning = !isUnlimited && percentage >= 80

  return (
    <div className="flex flex-col gap-1.5">
      <div className="flex items-center justify-between">
        <div className="flex items-center gap-2 text-sm text-muted-foreground">
          <Icon className="h-3.5 w-3.5" />
          {label}
        </div>
        <span className="text-sm text-foreground font-medium">
          {current}{isUnlimited ? "" : ` / ${max}`}
        </span>
      </div>
      <div className="h-1.5 w-full rounded-full bg-secondary">
        <div
          className={`h-full rounded-full transition-all ${isWarning ? "bg-yellow-500" : "bg-primary"}`}
          style={{ width: `${Math.min(100, percentage)}%` }}
        />
      </div>
    </div>
  )
}
