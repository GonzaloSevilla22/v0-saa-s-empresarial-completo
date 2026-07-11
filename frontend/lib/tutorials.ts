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
 * `youtubeVideoId: null` significa "tutorial aún no grabado/subido": ni la
 * landing ni el dashboard deben intentar renderizar su video mientras sea
 * null (ver `hasTutorialVideo`).
 */

export type TutorialModuleKey = "ventas" | "compras" | "productos" | "stock" | "gastos"

export interface Tutorial {
  moduleKey: TutorialModuleKey
  title: string
  description: string
  durationLabel: string
  /** `null` = video aún no subido a YouTube; el tutorial no se renderiza. */
  youtubeVideoId: string | null
  /** Ruta del dashboard donde este tutorial es contextualmente relevante. */
  pathname: string
}

export const TUTORIALS: readonly Tutorial[] = [
  {
    moduleKey: "ventas",
    title: "Cómo registrar una venta",
    description: "Aprendé a cargar una venta, asignarle un cliente y ver el impacto en tu caja al instante.",
    durationLabel: "3 min",
    youtubeVideoId: null,
    pathname: "/ventas",
  },
  {
    moduleKey: "compras",
    title: "Cómo registrar una compra",
    description: "Sumá mercadería a tu stock cargando una compra a un proveedor en un par de clicks.",
    durationLabel: "3 min",
    youtubeVideoId: null,
    pathname: "/compras",
  },
  {
    moduleKey: "productos",
    title: "Cómo cargar tus productos",
    description: "Dale de alta a tu catálogo: precios, variantes y unidades de medida, paso a paso.",
    durationLabel: "4 min",
    youtubeVideoId: null,
    pathname: "/productos",
  },
  {
    moduleKey: "stock",
    title: "Cómo controlar tu stock",
    description: "Configurá el stock mínimo por sucursal y recibí alertas antes de que se te acabe un producto.",
    durationLabel: "3 min",
    youtubeVideoId: null,
    pathname: "/stock",
  },
  {
    moduleKey: "gastos",
    title: "Cómo registrar tus gastos",
    description: "Llevá el control de los gastos de tu negocio para conocer tu rentabilidad real.",
    durationLabel: "2 min",
    youtubeVideoId: null,
    pathname: "/gastos",
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
 * ofrecer el botón usando `hasTutorialVideo` sobre el resultado).
 */
export function getTutorialByPathname(pathname: string): Tutorial | undefined {
  return TUTORIALS.find((t) => t.pathname === pathname)
}
