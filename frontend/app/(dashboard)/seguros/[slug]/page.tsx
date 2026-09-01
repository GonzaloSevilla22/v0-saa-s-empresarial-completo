"use client"

import { useState, useEffect } from "react"
import Link from "next/link"
import { insuranceService, type Insurance, type ContactChannel } from "@/lib/services/insuranceService"
import { Card } from "@/components/ui/card"
import { Button } from "@/components/ui/button"
import { ArrowLeft } from "lucide-react"
import { AdvisorProfileContent } from "@/components/seguros/AdvisorProfileContent"

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

      <AdvisorProfileContent advisor={advisor} onTrackContact={trackContact} />
    </div>
  )
}
