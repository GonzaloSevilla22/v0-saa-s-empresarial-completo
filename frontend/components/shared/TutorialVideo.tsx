"use client"

import { YouTubeEmbed } from "@next/third-parties/google"
import { AspectRatio } from "@/components/ui/aspect-ratio"

interface TutorialVideoProps {
  youtubeVideoId: string
  title?: string
}

/**
 * Player compartido de tutoriales — envuelve `YouTubeEmbed` de
 * `@next/third-parties/google` (patrón facade: solo miniatura hasta el
 * click, sirve desde youtube-nocookie.com) dentro de un contenedor 16:9.
 * Siempre limita las sugerencias relacionadas al propio canal (`rel=0`).
 *
 * Se reutiliza en la card de la landing y en el modal contextual del
 * dashboard. Asume `youtubeVideoId` no nulo — la decisión de mostrar u
 * ocultar según disponibilidad vive en el consumidor (ver `lib/tutorials.ts`).
 */
export function TutorialVideo({ youtubeVideoId, title }: TutorialVideoProps) {
  return (
    <AspectRatio ratio={16 / 9} className="overflow-hidden rounded-xl bg-slate-950">
      <YouTubeEmbed videoid={youtubeVideoId} params="rel=0" playlabel={title} />
    </AspectRatio>
  )
}
