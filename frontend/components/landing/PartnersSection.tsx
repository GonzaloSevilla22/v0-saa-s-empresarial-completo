import type { LandingPartner } from "@/lib/landing-partners"
import { LANDING_PARTNERS } from "@/lib/landing-partners"

/**
 * Sección "Nuestros aliados" de la landing pública (`/`). Estática:
 * consume el catálogo tipado de `lib/landing-partners.ts`, sin lecturas a
 * la base de datos. Sigue el patrón visual de `TutorialsSection` (section
 * `bg-slate-900`, cards `bg-slate-950`).
 *
 * Con un solo aliado (catálogo real hoy: Grupo ARG) renderiza una tarjeta
 * centrada en vez de una grilla con huecos; con 2+ aliados pasa a grilla
 * sin cambiar de componente. Catálogo vacío ⇒ no se renderiza nada (mismo
 * patrón que `TutorialsSection` cuando no hay tutoriales disponibles).
 *
 * El logo es azul oscuro sobre fondo blanco (marca de un tercero, no se
 * recolorea): se muestra dentro de un contenedor claro para que se lea
 * sobre el fondo oscuro de la landing.
 */
export function PartnersSection({
  partners = LANDING_PARTNERS,
}: {
  partners?: readonly LandingPartner[]
}) {
  if (partners.length === 0) {
    return null
  }

  const isSingle = partners.length === 1

  return (
    <section id="aliados" aria-label="Nuestros aliados" className="bg-slate-900 py-24 sm:py-32">
      <div className="container mx-auto px-4">
        <div className="mx-auto max-w-2xl text-center mb-16">
          <span className="text-sm font-semibold text-emerald-400 uppercase tracking-widest">Alianzas</span>
          <h2 className="mt-3 text-3xl font-bold tracking-tight text-white sm:text-4xl">Nuestros aliados</h2>
          <p className="mt-4 text-lg text-slate-400">
            Sumamos socios de confianza para darte más que gestión: respaldo real para tu negocio.
          </p>
        </div>
        <div
          className={
            isSingle
              ? "mx-auto max-w-xl"
              : "grid grid-cols-1 gap-6 sm:grid-cols-2 lg:grid-cols-3 max-w-5xl mx-auto"
          }
        >
          {partners.map((partner) => (
            <div
              key={partner.name}
              className="flex flex-col items-center gap-5 rounded-2xl border border-slate-800 bg-slate-950 p-8 text-center"
            >
              <div className="rounded-xl bg-white px-6 py-5">
                <img src={partner.logoSrc} alt={partner.logoAlt} className="h-16 w-auto object-contain" />
              </div>
              <div>
                <p className="font-semibold text-white">{partner.name}</p>
                <p className="mt-3 text-sm leading-relaxed text-slate-400">{partner.blurb}</p>
              </div>
            </div>
          ))}
        </div>
      </div>
    </section>
  )
}
