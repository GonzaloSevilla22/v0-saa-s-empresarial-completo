import { Card, CardContent } from "@/components/ui/card"
import { Badge } from "@/components/ui/badge"
import { ShieldCheck, MapPin } from "lucide-react"
import type { ContactChannel, Insurance } from "@/lib/services/insuranceService"
import { AdvisorAvatar } from "@/components/seguros/AdvisorAvatar"
import { AdvisorContactChannels } from "@/components/seguros/AdvisorContactChannels"
import { AdvisorListSection } from "@/components/seguros/AdvisorListSection"

interface AdvisorProfileContentProps {
  advisor: Insurance
  onTrackContact: (channel: ContactChannel) => void
}

/**
 * Contenido completo del perfil de un asesor: identidad + matrícula,
 * headline/bio, contacto, líneas de servicio, pilares, zonas de cobertura y
 * deslinde. Extraído de `/seguros/[slug]/page.tsx` (task 5.7 REFACTOR) y
 * reutilizado por `/seguros` (índice, task 6.2): con un único asesor
 * visible y ninguna oferta, el índice presenta este mismo contenido en vez
 * de una grilla con huecos (design.md D5) — evita duplicar el perfil
 * completo en dos archivos (regla de reutilización antes que repetición).
 */
export function AdvisorProfileContent({ advisor, onTrackContact }: AdvisorProfileContentProps) {
  const serviceLines = advisor.service_lines ?? []
  const pillars = advisor.pillars ?? []
  const coverageAreas = advisor.coverage_areas ?? []

  return (
    <div className="flex flex-col gap-6">
      <Card className="border-border bg-card">
        <CardContent className="flex flex-col gap-6 p-6 sm:flex-row sm:items-start">
          <AdvisorAvatar photoUrl={advisor.photo_url} name={advisor.advisor_name ?? advisor.title} />

          <div className="flex flex-1 flex-col gap-2">
            <div className="flex flex-wrap items-center gap-2">
              <h1 className="text-2xl font-bold text-foreground tracking-tight">
                {advisor.advisor_name ?? advisor.title}
              </h1>
              {advisor.is_featured ? (
                <Badge className="bg-primary/10 text-primary border-primary/20">Destacado</Badge>
              ) : null}
            </div>

            {advisor.advisor_role ? (
              <p className="text-sm text-muted-foreground">{advisor.advisor_role}</p>
            ) : null}

            {advisor.license_number ? (
              <div className="flex flex-wrap items-center gap-2 text-xs text-muted-foreground">
                <ShieldCheck className="h-3.5 w-3.5 text-primary/70" />
                <span>Mat. N.º {advisor.license_number}</span>
                {advisor.license_authority ? (
                  <span data-testid="license-authority">— {advisor.license_authority}</span>
                ) : null}
              </div>
            ) : null}

            {advisor.headline ? (
              <p className="mt-2 text-lg font-medium italic text-foreground/90">"{advisor.headline}"</p>
            ) : null}

            {advisor.bio ? (
              <p className="whitespace-pre-line text-sm leading-relaxed text-muted-foreground">
                {advisor.bio}
              </p>
            ) : null}
          </div>
        </CardContent>
      </Card>

      <Card className="border-border bg-card">
        <CardContent className="flex flex-col gap-4 p-6">
          <h2 className="text-sm font-semibold uppercase tracking-wide text-muted-foreground">Contacto</h2>
          <AdvisorContactChannels
            whatsapp={advisor.contact_whatsapp}
            email={advisor.contact_email}
            phone={advisor.contact_phone}
            webUrl={advisor.contact_url || null}
            onTrack={onTrackContact}
          />
        </CardContent>
      </Card>

      <AdvisorListSection
        heading="Líneas de servicio"
        layout="grid"
        items={serviceLines.map((line) => ({ title: line.title, text: line.description }))}
      />

      <AdvisorListSection
        heading="Cómo trabajo"
        layout="stack"
        items={pillars.map((pillar) => ({ title: pillar.title, text: pillar.body }))}
      />

      {coverageAreas.length > 0 ? (
        <Card className="border-border bg-card">
          <CardContent className="flex flex-col gap-3 p-6">
            <h2 className="text-sm font-semibold uppercase tracking-wide text-muted-foreground">
              Zonas de cobertura
            </h2>
            <div className="flex flex-wrap gap-2">
              {coverageAreas.map((area) => (
                <Badge key={area} variant="secondary" className="gap-1">
                  <MapPin className="h-3 w-3" />
                  {area}
                </Badge>
              ))}
            </div>
          </CardContent>
        </Card>
      ) : null}

      {advisor.disclaimer ? (
        <p className="text-xs leading-relaxed text-muted-foreground/80">{advisor.disclaimer}</p>
      ) : null}
    </div>
  )
}
