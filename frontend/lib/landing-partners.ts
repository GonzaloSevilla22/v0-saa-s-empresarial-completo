/**
 * Catálogo estático de aliados comerciales mostrados en la sección
 * "Nuestros aliados" de la landing pública (`/`). Decisión del PO
 * (2026-09-01): el rótulo es "aliados", no "clientes" — se le explicó que
 * ese rótulo implica usuarios de la plataforma y eligió "aliados".
 *
 * Con un solo aliado, `PartnersSection` renderiza una tarjeta centrada en
 * vez de una grilla con huecos; el componente soporta 2+ aliados en grilla
 * sin cambios (ver `PartnersSection.test.tsx`, catálogo de prueba). Catálogo
 * vacío ⇒ sección oculta (mismo patrón que `lib/tutorials.ts`).
 *
 * Sin CTA saliente: el módulo de Seguros es para usuarios logueados, y esta
 * sección vive en la landing pública (no logueada).
 */

export interface LandingPartner {
  /** Nombre visible de la alianza. */
  name: string
  /** Ruta pública del logo (servida desde `public/`). */
  logoSrc: string
  /** Texto alternativo del logo — descriptivo, no repite el nombre a secas. */
  logoAlt: string
  /** Descripción breve de la alianza (1–2 líneas). */
  blurb: string
}

export const LANDING_PARTNERS: readonly LandingPartner[] = [
  {
    name: "Grupo ARG · Brokers de Seguros",
    logoSrc: "/partners/grupo-arg.png",
    logoAlt: "Grupo ARG — Brokers de Seguros",
    blurb:
      "Respaldo en seguros para los negocios que usan Aliadata: asesoramiento de un productor matriculado, de autos y hogar a empresas, flotas y ART.",
  },
] as const
