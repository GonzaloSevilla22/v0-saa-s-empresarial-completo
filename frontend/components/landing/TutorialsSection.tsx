import { Clock } from "lucide-react"
import { TutorialVideo } from "@/components/shared/TutorialVideo"
import { getAvailableTutorials } from "@/lib/tutorials"

/**
 * Sección "Aprendé a usar ALIADATA" de la landing pública (`/`). Estática:
 * consume el catálogo tipado de `lib/tutorials.ts`, sin lecturas a la base
 * de datos. Sigue el patrón visual de `Features` en `LandingPageFull.tsx`.
 *
 * Mientras el catálogo no tenga ningún `youtubeVideoId` disponible (OQ1: el
 * PO todavía no subió los videos), la sección no se renderiza — se mergea
 * el andamiaje invisible en prod hasta que haya al menos un video.
 */
export function TutorialsSection() {
  const tutorials = getAvailableTutorials()

  if (tutorials.length === 0) {
    return null
  }

  return (
    <section id="tutoriales" className="bg-slate-900 py-24 sm:py-32">
      <div className="container mx-auto px-4">
        <div className="mx-auto max-w-2xl text-center mb-16">
          <span className="text-sm font-semibold text-emerald-400 uppercase tracking-widest">Tutoriales</span>
          <h2 className="mt-3 text-3xl font-bold tracking-tight text-white sm:text-4xl">Aprendé a usar ALIADATA</h2>
          <p className="mt-4 text-lg text-slate-400">
            Videos cortos para dominar cada módulo en minutos, directo del equipo de ALIADATA.
          </p>
        </div>
        <div className="grid grid-cols-1 gap-6 sm:grid-cols-2 lg:grid-cols-3">
          {tutorials.map((tutorial) => (
            <div key={tutorial.moduleKey} className="flex flex-col gap-4 rounded-2xl border border-slate-800 bg-slate-950 p-4">
              <TutorialVideo youtubeVideoId={tutorial.youtubeVideoId} title={tutorial.title} />
              <div className="px-1 pb-1">
                <h3 className="text-lg font-semibold text-white">{tutorial.title}</h3>
                <p className="mt-1 text-sm leading-relaxed text-slate-400">{tutorial.description}</p>
                <p className="mt-3 flex items-center gap-1.5 text-xs text-slate-500">
                  <Clock className="h-3.5 w-3.5" />
                  {tutorial.durationLabel}
                </p>
              </div>
            </div>
          ))}
        </div>
      </div>
    </section>
  )
}
