/**
 * Catálogo estático de tutoriales de uso de ALIADATA — fuente única de verdad
 * para la sección de tutoriales de la landing (`/`) y el botón contextual
 * "Ver tutorial" del dashboard.
 *
 * El hosting del video queda abstraído detrás de este mapa: hoy los videos
 * viven en YouTube (unlisted), embebidos vía `TutorialVideo`
 * (`components/shared/TutorialVideo.tsx`). Migrar a otro hosting (p. ej.
 * Cloudflare R2) es un cambio de datos + implementación del player, sin
 * tocar las superficies que consumen este catálogo.
 *
 * Alcance (PO 2026-07-29): 10 tutoriales — Onboarding (video general de
 * inicio, sin ruta de dashboard) + 9 módulos. El orden del array ES el
 * orden de las cards en la landing: Onboarding primero.
 *
 * Los 10 `youtubeVideoId` fueron entregados por el PO el 2026-07-29
 * (videos unlisted en su canal de YouTube) — la feature está VISIBLE.
 * `youtubeVideoId: null` sigue significando "tutorial aún no grabado/
 * subido": ni la landing ni el dashboard renderizan su video mientras sea
 * null (ver `hasTutorialVideo`) — aplica a entradas futuras del catálogo.
 */

export type TutorialModuleKey =
  | "onboarding"
  | "dashboard"
  | "ventas"
  | "compras"
  | "productos"
  | "stock"
  | "gastos"
  | "clientes"
  | "insights"
  | "simulador"

export interface Tutorial {
  moduleKey: TutorialModuleKey
  title: string
  description: string
  durationLabel: string
  /** `null` = video aún no subido a YouTube; el tutorial no se renderiza. */
  youtubeVideoId: string | null
  /**
   * Ruta del dashboard donde este tutorial es contextualmente relevante.
   * `null` = tutorial general (p. ej. onboarding): aparece en la landing
   * pero no tiene botón "Ver tutorial" en ninguna ruta del dashboard.
   */
  pathname: string | null
}

export const TUTORIALS: readonly Tutorial[] = [
  {
    moduleKey: "onboarding",
    title: "Empezá por acá: primeros pasos con ALIADATA",
    description: "El recorrido inicial completo: configurá tu cuenta, conocé los módulos y dejá tu negocio listo para operar.",
    durationLabel: "5 min",
    youtubeVideoId: "C_SUggjXdkw",
    pathname: null,
  },
  {
    moduleKey: "dashboard",
    title: "Cómo leer tu tablero",
    description: "Entendé de un vistazo las métricas clave de tu negocio: ventas, compras, stock y rentabilidad en tiempo real.",
    durationLabel: "3 min",
    youtubeVideoId: "U6qli8FlMh4",
    pathname: "/dashboard",
  },
  {
    moduleKey: "ventas",
    title: "Cómo registrar una venta",
    description: "Aprendé a cargar una venta, asignarle un cliente y ver el impacto en tu caja al instante.",
    durationLabel: "3 min",
    youtubeVideoId: "ozpyvm5BXqE",
    pathname: "/ventas",
  },
  {
    moduleKey: "compras",
    title: "Cómo registrar una compra",
    description: "Sumá mercadería a tu stock cargando una compra a un proveedor en un par de clicks.",
    durationLabel: "3 min",
    youtubeVideoId: "53aV89Pikdc",
    pathname: "/compras",
  },
  {
    moduleKey: "productos",
    title: "Cómo cargar tus productos",
    description: "Dale de alta a tu catálogo: precios, variantes y unidades de medida, paso a paso.",
    durationLabel: "4 min",
    youtubeVideoId: "c33ZUWjCoHA",
    pathname: "/productos",
  },
  {
    moduleKey: "stock",
    title: "Cómo controlar tu stock",
    description: "Configurá el stock mínimo por sucursal y recibí alertas antes de que se te acabe un producto.",
    durationLabel: "3 min",
    youtubeVideoId: "QXFTEBCLMZo",
    pathname: "/stock",
  },
  {
    moduleKey: "gastos",
    title: "Cómo registrar tus gastos",
    description: "Llevá el control de los gastos de tu negocio para conocer tu rentabilidad real.",
    durationLabel: "2 min",
    youtubeVideoId: "5OV88rvz-MU",
    pathname: "/gastos",
  },
  {
    moduleKey: "clientes",
    title: "Cómo gestionar tus clientes",
    description: "Cargá tus clientes, mirá su historial de compras y llevá su cuenta corriente sin planillas.",
    durationLabel: "3 min",
    youtubeVideoId: "Ak9as52T3c8",
    pathname: "/clientes",
  },
  {
    moduleKey: "insights",
    title: "Cómo aprovechar los Consejos IA",
    description: "Descubrí los insights que la IA genera con tus datos y convertilos en decisiones concretas.",
    durationLabel: "2 min",
    youtubeVideoId: "AmKOe8w3f90",
    pathname: "/insights",
  },
  {
    moduleKey: "simulador",
    title: "Cómo usar el Simulador de Precios",
    description: "Probá precios y márgenes antes de decidir: simulá escenarios con tus costos reales.",
    durationLabel: "3 min",
    youtubeVideoId: "FL6sRkKp3xQ",
    pathname: "/simulador",
  },
] as const

/** Tutorial cuyo `youtubeVideoId` está confirmado no nulo (ver `hasTutorialVideo`). */
export type TutorialWithVideo = Tutorial & { youtubeVideoId: string }

/**
 * `true` cuando el tutorial tiene un video ya subido y disponible para
 * reproducir. Es un *type predicate*: tras un chequeo positivo, TypeScript
 * angosta `youtubeVideoId` a `string` sin necesidad de type assertions.
 */
export function hasTutorialVideo<T extends Pick<Tutorial, "youtubeVideoId">>(
  tutorial: T
): tutorial is T & { youtubeVideoId: string } {
  return tutorial.youtubeVideoId !== null
}

/** Tutoriales cuyo video ya está disponible (para listar cards en la landing). */
export function getAvailableTutorials(): TutorialWithVideo[] {
  return TUTORIALS.filter(hasTutorialVideo)
}

/**
 * Busca el tutorial contextual de una ruta del dashboard. Devuelve la
 * entrada del catálogo exista o no el video (el consumidor decide si
 * ofrecer el botón usando `hasTutorialVideo` sobre el resultado). Los
 * tutoriales generales (`pathname: null`, p. ej. onboarding) nunca se
 * devuelven por ruta.
 */
export function getTutorialByPathname(pathname: string): Tutorial | undefined {
  return TUTORIALS.find((t) => t.pathname !== null && t.pathname === pathname)
}
