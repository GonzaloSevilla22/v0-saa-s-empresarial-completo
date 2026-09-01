import { MessageCircle, Mail, Phone, Globe } from "lucide-react"
import { Button } from "@/components/ui/button"
import type { ContactChannel } from "@/lib/services/insuranceService"

interface AdvisorContactChannelsProps {
  whatsapp?: string | null
  email?: string | null
  phone?: string | null
  webUrl?: string | null
  onTrack: (channel: ContactChannel) => void
}

/**
 * Vías de contacto del perfil de asesor (design.md D7): cada control se
 * renderiza SÓLO si su dato existe — nunca un botón inerte, deshabilitado o
 * que lleve a un destino vacío. Deep links nativos, sin formulario propio:
 * WhatsApp (wa.me, ya normalizado en E.164 sin `+`) y web abren en pestaña
 * nueva con `rel="noopener noreferrer"`; mail/tel usan sus esquemas nativos
 * (útiles de verdad en mobile). Cada click dispara el tracking por vía,
 * fire-and-forget, sin bloquear la navegación real del enlace.
 */
export function AdvisorContactChannels({
  whatsapp,
  email,
  phone,
  webUrl,
  onTrack,
}: AdvisorContactChannelsProps) {
  return (
    <div className="flex flex-wrap gap-3">
      {whatsapp ? (
        <Button asChild className="bg-emerald-600 text-white hover:bg-emerald-700">
          <a
            href={`https://wa.me/${whatsapp}`}
            target="_blank"
            rel="noopener noreferrer"
            onClick={() => onTrack("whatsapp")}
          >
            <MessageCircle className="h-4 w-4" />
            WhatsApp
          </a>
        </Button>
      ) : null}

      {email ? (
        <Button asChild variant="outline">
          <a href={`mailto:${email}`} onClick={() => onTrack("email")}>
            <Mail className="h-4 w-4" />
            Email
          </a>
        </Button>
      ) : null}

      {phone ? (
        <Button asChild variant="outline">
          <a href={`tel:${phone}`} onClick={() => onTrack("phone")}>
            <Phone className="h-4 w-4" />
            Llamar
          </a>
        </Button>
      ) : null}

      {webUrl ? (
        <Button asChild variant="outline">
          <a
            href={webUrl}
            target="_blank"
            rel="noopener noreferrer"
            onClick={() => onTrack("web")}
          >
            <Globe className="h-4 w-4" />
            Sitio web
          </a>
        </Button>
      ) : null}
    </div>
  )
}
