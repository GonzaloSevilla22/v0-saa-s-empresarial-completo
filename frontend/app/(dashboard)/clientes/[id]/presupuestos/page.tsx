"use client"

/**
 * /clientes/[id]/presupuestos — pestaña "Presupuestos" de la ficha del cliente
 * (presupuestos-modulo D10, OQ-P7): sus últimos 5 presupuestos y el enlace al
 * listado filtrado por ese cliente. La cabecera con el botón "Nuevo presupuesto"
 * la aporta el layout compartido de `/clientes/[id]`.
 */
import Link from "next/link"
import { useParams } from "next/navigation"
import { FileText, Plus } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Card, CardContent } from "@/components/ui/card"
import { QuoteStatusBadge } from "@/components/quotes/QuoteStatusBadge"
import { useQuotes } from "@/hooks/data/use-quotes"
import { useOrgRole } from "@/hooks/useOrgRole"
import { formatDate, formatMoney } from "@/lib/format"
import { CAN_QUOTE, hasCapability } from "@/lib/rbac-capabilities"

const RECENT_COUNT = 5

export default function ClienteQuotesPage() {
  const params = useParams<{ id: string }>()
  const clientId = params.id
  const { roles, rolesResolved } = useOrgRole()
  const canQuote = hasCapability(roles, CAN_QUOTE, rolesResolved)
  const { data, isLoading, isError } = useQuotes({ clientId, pageSize: RECENT_COUNT })

  if (isLoading) {
    return (
      <p className="px-4 py-10 text-center text-sm text-muted-foreground" role="status">
        Cargando presupuestos…
      </p>
    )
  }
  if (isError) {
    return (
      <p className="px-4 py-10 text-center text-sm text-destructive" role="alert">
        No se pudieron cargar los presupuestos de este cliente. Probá de nuevo en un momento.
      </p>
    )
  }

  const items = data?.items ?? []
  const total = data?.total ?? items.length

  if (items.length === 0) {
    return (
      <Card className="border-border bg-card">
        <CardContent
          data-testid="client-quotes-empty"
          className="flex flex-col items-center gap-3 px-4 py-14 text-center text-muted-foreground"
        >
          <FileText className="h-10 w-10 opacity-30" aria-hidden="true" />
          <p className="text-sm font-medium text-foreground">Este cliente todavía no tiene presupuestos</p>
          <p className="max-w-sm text-xs">Cuando le armes uno, vas a verlo acá con su estado.</p>
          {canQuote && (
            <Button asChild size="sm" className="gap-2">
              <Link href={`/presupuestos/nuevo?cliente=${encodeURIComponent(clientId)}`}>
                <Plus className="h-4 w-4" aria-hidden="true" />
                Nuevo presupuesto
              </Link>
            </Button>
          )}
        </CardContent>
      </Card>
    )
  }

  return (
    <div className="flex flex-col gap-3">
      <Card className="border-border bg-card min-w-0">
        <CardContent className="p-0">
          <ul aria-label="Últimos presupuestos del cliente" className="divide-y divide-border/60">
            {items.map((quote) => (
              <li
                key={quote.id}
                data-testid={`client-quote-${quote.id}`}
                className="flex flex-wrap items-center justify-between gap-x-4 gap-y-1 px-4 py-3"
              >
                <div className="flex min-w-0 flex-col">
                  <Link
                    href={`/presupuestos/${quote.id}`}
                    className="font-medium text-primary underline-offset-2 hover:underline"
                  >
                    {quote.number_label ?? "Presupuesto"}
                  </Link>
                  <span className="text-xs tabular-nums text-muted-foreground">
                    {formatDate(quote.created_at)}
                    {quote.valid_until ? ` · válido hasta ${formatDate(quote.valid_until)}` : ""}
                  </span>
                </div>
                <div className="flex items-center gap-3">
                  <span className="text-sm font-semibold tabular-nums text-foreground">
                    {formatMoney(Number(quote.total))}
                  </span>
                  <QuoteStatusBadge status={quote.status} isExpired={quote.is_expired} />
                </div>
              </li>
            ))}
          </ul>
        </CardContent>
      </Card>
      <Link
        href={`/presupuestos?cliente=${encodeURIComponent(clientId)}`}
        className="self-start text-sm text-primary underline-offset-2 hover:underline"
      >
        Ver todos los presupuestos de este cliente{total > items.length ? ` (${total})` : ""}
      </Link>
    </div>
  )
}
