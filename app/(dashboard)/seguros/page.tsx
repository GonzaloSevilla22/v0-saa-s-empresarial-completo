"use client"

import { useState, useEffect } from "react"
import { insuranceService, Insurance } from "@/lib/services/insuranceService"
import { Card, CardContent, CardHeader, CardTitle, CardDescription } from "@/components/ui/card"
import { Button } from "@/components/ui/button"
import { Shield, ExternalLink, Info } from "lucide-react"
import { Badge } from "@/components/ui/badge"

export default function SegurosPage() {
  const [insurances, setInsurances] = useState<Insurance[]>([])
  const [loading, setLoading] = useState(true)

  useEffect(() => {
    async function loadInsurances() {
      try {
        const data = await insuranceService.getVisibleInsurances()
        setInsurances(data)
      } catch (error) {
        console.error("Error loading insurances:", error)
      } finally {
        setLoading(false)
      }
    }
    loadInsurances()
  }, [])

  return (
    <div className="flex flex-col gap-6">
      <div>
        <h1 className="text-2xl font-bold text-foreground tracking-tight">Seguros para emprendedores</h1>
        <p className="text-sm text-muted-foreground mt-1">
          Protegé tu negocio con opciones de seguros pensadas para emprendedores.
        </p>
      </div>

      {loading ? (
        <div className="grid gap-4 grid-cols-1 md:grid-cols-2 lg:grid-cols-3">
          {[1, 2, 3].map((i) => (
            <Card key={i} className="animate-pulse border-border bg-card h-[250px]" />
          ))}
        </div>
      ) : insurances.length > 0 ? (
        <div className="grid gap-4 grid-cols-1 md:grid-cols-2 lg:grid-cols-3">
          {insurances.map((seguro) => (
            <Card key={seguro.id} className="border-border bg-card relative overflow-hidden group hover:border-primary/30 transition-all flex flex-col h-full shadow-sm">
              <div className="h-1.5 bg-primary/20 group-hover:bg-primary/40 transition-colors" />
              <CardHeader className="pb-2">
                <div className="flex items-start justify-between gap-2">
                  <CardTitle className="text-base text-card-foreground leading-tight">{seguro.title}</CardTitle>
                  <Shield className="h-5 w-5 text-primary shrink-0 opacity-70" />
                </div>
                <Badge variant="secondary" className="w-fit mt-1 text-[10px] bg-primary/5 text-primary border-primary/10">
                  {seguro.price}
                </Badge>
              </CardHeader>
              <CardContent className="flex flex-col gap-4 flex-1">
                <p className="text-sm text-muted-foreground leading-relaxed line-clamp-3">
                  {seguro.description}
                </p>
                <div className="space-y-2 flex-1">
                  <div className="flex items-center gap-2 text-xs text-muted-foreground">
                    <Info className="h-3.5 w-3.5 text-primary/60" />
                    <span className="font-medium text-foreground/80">Cobertura:</span>
                  </div>
                  <p className="text-xs text-muted-foreground line-clamp-2 pl-5">
                    {seguro.coverage}
                  </p>
                </div>
                <Button asChild size="sm" variant="outline" className="w-full border-primary/30 text-primary hover:bg-primary/10 hover:text-primary transition-all mt-auto shadow-sm">
                  <a href={seguro.contact_url} target="_blank" rel="noopener noreferrer">
                    Más información
                    <ExternalLink className="h-3.5 w-3.5 ml-2" />
                  </a>
                </Button>
              </CardContent>
            </Card>
          ))}
        </div>
      ) : (
        <Card className="border-dashed border-2 bg-muted/30 py-12">
          <CardContent className="flex flex-col items-center text-center gap-4">
            <div className="p-4 rounded-full bg-primary/10">
              <Shield className="h-8 w-8 text-primary/60" />
            </div>
            <div className="space-y-1">
              <h3 className="font-semibold text-lg">Próximamente seguros para emprendedores.</h3>
              <p className="text-sm text-muted-foreground max-w-sm mx-auto">
                Estamos trabajando junto a aseguradoras para ofrecer opciones de seguros pensadas para tu negocio.
              </p>
            </div>
          </CardContent>
        </Card>
      )}
    </div>
  )
}
