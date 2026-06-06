/**
 * /planes/failure — Payment failure page
 * C-10 subscription-ui-upgrade-flow
 *
 * MercadoPago redirects here when a payment is rejected or cancelled.
 * No plan change has been made — the user is shown a friendly error
 * and offered options to retry or get support.
 */

import Link from "next/link"
import { XCircle } from "lucide-react"
import { Button } from "@/components/ui/button"

export const metadata = {
  title: "Pago no procesado — EmprendeSmart",
}

const WHATSAPP_URL = "https://wa.me/5492615000000?text=Hola%2C%20tuve%20un%20problema%20con%20mi%20pago%20en%20EmprendeSmart"

export default function PlanesFailurePage() {
  return (
    <div className="container max-w-lg mx-auto px-4 py-16 text-center space-y-6">
      <div className="flex justify-center">
        <XCircle className="h-16 w-16 text-destructive" />
      </div>

      <div className="space-y-2">
        <h1 className="text-3xl font-bold text-foreground">El pago no fue procesado</h1>
        <p className="text-muted-foreground">
          No se realizó ningún cargo y tu plan actual no fue modificado.
          Podés volver a intentarlo o contactarnos si el problema persiste.
        </p>
      </div>

      <div className="bg-destructive/10 border border-destructive/30 rounded-lg p-4 text-sm text-destructive">
        Motivos posibles: tarjeta rechazada, fondos insuficientes o sesión expirada en MercadoPago.
      </div>

      <div className="flex flex-col sm:flex-row gap-3 justify-center">
        <Button asChild>
          <Link href="/planes">Reintentar</Link>
        </Button>
        <Button asChild variant="outline">
          <a href={WHATSAPP_URL} target="_blank" rel="noopener noreferrer">
            Contactar soporte
          </a>
        </Button>
      </div>
    </div>
  )
}
