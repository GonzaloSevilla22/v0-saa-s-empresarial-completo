import Link from "next/link"
import { Card, CardContent } from "@/components/ui/card"
import { Badge } from "@/components/ui/badge"
import { Button } from "@/components/ui/button"
import { ShieldCheck, ArrowRight } from "lucide-react"
import type { Insurance } from "@/lib/services/insuranceService"
import { AdvisorAvatar } from "@/components/seguros/AdvisorAvatar"

interface AdvisorCardProps {
  advisor: Insurance
}

/**
 * Card resumen de un asesor en la grilla de `/seguros` (2+ asesores
 * visibles, design.md D5). A diferencia de `AdvisorProfileContent`, no
 * repite el perfil completo — sólo identidad, matrícula y un enlace a
 * `/seguros/[slug]` para el detalle.
 */
export function AdvisorCard({ advisor }: AdvisorCardProps) {
  return (
    <Card className="border-border bg-card flex flex-col h-full shadow-sm hover:border-primary/30 transition-all">
      <CardContent className="flex flex-1 flex-col gap-4 p-5">
        <div className="flex items-start gap-3">
          <AdvisorAvatar
            photoUrl={advisor.photo_url}
            name={advisor.advisor_name ?? advisor.title}
            className="h-14 w-14 text-base"
          />
          <div className="flex flex-col gap-0.5">
            <p className="text-sm font-semibold text-card-foreground leading-tight">
              {advisor.advisor_name ?? advisor.title}
            </p>
            {advisor.advisor_role ? (
              <p className="text-xs text-muted-foreground">{advisor.advisor_role}</p>
            ) : null}
            {advisor.license_number ? (
              <p className="flex items-center gap-1 text-[10px] text-muted-foreground">
                <ShieldCheck className="h-3 w-3 text-primary/70" />
                Mat. N.º {advisor.license_number}
              </p>
            ) : null}
          </div>
        </div>

        {advisor.headline ? (
          <p className="text-xs text-muted-foreground leading-relaxed line-clamp-3 flex-1">
            {advisor.headline}
          </p>
        ) : (
          <div className="flex-1" />
        )}

        <Badge variant="secondary" className="w-fit text-[10px]">
          Asesor de seguros
        </Badge>

        <Button asChild size="sm" variant="outline" className="w-full border-primary/30 text-primary hover:bg-primary/10 hover:text-primary mt-auto">
          <Link href={`/seguros/${advisor.slug}`}>
            Ver perfil
            <ArrowRight className="h-3.5 w-3.5 ml-2" />
          </Link>
        </Button>
      </CardContent>
    </Card>
  )
}
