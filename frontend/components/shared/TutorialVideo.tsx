"use client"

import { useState } from "react"
import { Play } from "lucide-react"
import { AspectRatio } from "@/components/ui/aspect-ratio"

interface TutorialVideoProps {
  youtubeVideoId: string
  title?: string
}

/**
 * Player compartido de tutoriales — facade PROPIO, sin scripts externos
 * (decisión PO 2026-07-29): la CSP de prod bloqueaba el script de
 * lite-youtube que `@next/third-parties` cargaba desde cdn.jsdelivr.net,
 * y no se quiso abrir script-src. En su lugar:
 *
 * - Estado inicial: botón accesible con la miniatura de i.ytimg.com
 *   (img-src ya permite https:) y un ícono de play superpuesto.
 * - Al click: se monta el <iframe> de youtube-nocookie.com con autoplay
 *   (permitido explícitamente en frame-src) y `rel=0` para limitar las
 *   sugerencias al propio canal.
 *
 * Mantiene el patrón facade (nada del player pesado hasta el click) y el
 * contenedor 16:9. Se reutiliza en la card de la landing y en el modal
 * contextual del dashboard. Asume `youtubeVideoId` no nulo — la decisión
 * de mostrar u ocultar vive en el consumidor (ver `lib/tutorials.ts`).
 */
export function TutorialVideo({ youtubeVideoId, title }: TutorialVideoProps) {
  const [playing, setPlaying] = useState(false)
  const accessibleTitle = title ?? "Video tutorial"

  return (
    <AspectRatio ratio={16 / 9} className="overflow-hidden rounded-xl bg-slate-950">
      {playing ? (
        <iframe
          src={`https://www.youtube-nocookie.com/embed/${youtubeVideoId}?autoplay=1&rel=0`}
          title={accessibleTitle}
          allow="accelerometer; autoplay; clipboard-write; encrypted-media; gyroscope; picture-in-picture; web-share"
          allowFullScreen
          className="h-full w-full border-0"
        />
      ) : (
        <button
          type="button"
          onClick={() => setPlaying(true)}
          aria-label={`Reproducir: ${accessibleTitle}`}
          className="group relative flex h-full w-full cursor-pointer items-center justify-center"
        >
          <img
            src={`https://i.ytimg.com/vi/${youtubeVideoId}/hqdefault.jpg`}
            alt=""
            loading="lazy"
            className="absolute inset-0 h-full w-full object-cover"
          />
          <span
            aria-hidden="true"
            className="relative flex h-14 w-14 items-center justify-center rounded-full bg-slate-950/70 ring-1 ring-white/25 transition-transform duration-200 group-hover:scale-110"
          >
            <Play className="h-6 w-6 translate-x-0.5 fill-white text-white" />
          </span>
        </button>
      )}
    </AspectRatio>
  )
}
