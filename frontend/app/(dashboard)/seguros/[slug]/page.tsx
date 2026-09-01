"use client"

import { useState, useEffect } from "react"
import Link from "next/link"
import { insuranceService, type Insurance, type ContactChannel } from "@/lib/services/insuranceService"
import { Card, CardContent } from "@/components/ui/card"
import { Badge } from "@/components/ui/badge"
import { Button } from "@/components/ui/button"
import { ArrowLeft, ShieldCheck, MapPin } from "lucide-react"
import { AdvisorAvatar } from "@/components/seguros/AdvisorAvatar"
import { AdvisorContactChannels } from "@/components/seguros/AdvisorContactChannels"
import { AdvisorListSection } from "@/components/seguros/AdvisorListSection"

interface AdvisorProfilePageProps {
  params: Promise<{ slug: string }>
}

/**
 * Perfil público de un Productor Asesor de Seguros — /seguros/[slug]
 * (seguros-perfil-asesor). Client Component + `insuranceService`.
 *
 * `params` se resuelve dentro del mismo `useEffect` que dispara el fetch
 * (con `await`, no con el hook `use()`): las otras páginas de detalle del
 * repo con ruta dinámica sí usan `use(params)`
 * (frontend/app/(dashboard)/cursos/[id]/page.tsx), pero ese hook suspende
 * el árbol sin un `<Suspense>` explícito envolviéndolo — funciona en el
 * router real de Next (que sí provee ese boundary), pero un
 * `render()` de test sin ese boundary deja el body vacío en silencio. Un
 * `await` plano dentro de `useEffect` es equivalente en la práctica y no
 * depende de esa infraestructura implícita.
 */
export default function AdvisorProfilePage({ params }: AdvisorProfilePageProps) {
  const [advisor, setAdvisor] = useState<Insurance | null>(null)
  const [loading, setLoading] = useState(true)

  useEffect(() => {
    let active = true
    async function load() {
      try {
        const { slug } = await params
        const data = await insuranceService.getAdvisorBySlug(slug)
        if (active) setAdvisor(data)
      } catch (error) {
        console.error("Error cargando perfil de asesor:", error)
        if (active) setAdvisor(null)
      } finally {
        if (active) setLoading(false)
      }
    }
    load()
    return () => {
      active = false
    }
  }, [params])

  function trackContact(channel: ContactChannel) {
    if (!advisor) return
    void insuranceService.incrementContactClick(advisor.id, channel)
  }

  if (loading) {
    return (
      <div className="flex flex-col gap-6">
        <Card className="h-64 animate-pulse border-border bg-card" />
      </div>
    )
  }

  if (!advisor) {
    return (
      <div className="flex flex-col items-center justify-center gap-4 py-20">
        <p className="text-muted-foreground">Asesor no encontrado.</p>
        <Button asChild variant="outline" className="border-border text-foreground">
          <Link href="/seguros">Volver a Seguros</Link>
        </Button>
      </div>
    )
  }

  const serviceLines = advisor.service_lines ?? []
  const pillars = advisor.pillars ?? []
  const coverageAreas = advisor.coverage_areas ?? []

  return (
    <div className="flex flex-col gap-6 pb-12">
      <div>
        <Button asChild variant="ghost" size="sm" className="text-muted-foreground hover:text-foreground -ml-2">
          <Link href="/seguros">
            <ArrowLeft className="h-4 w-4" />
            Volver a Seguros
          </Link>
        </Button>
      </div>

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
            onTrack={trackContact}
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
