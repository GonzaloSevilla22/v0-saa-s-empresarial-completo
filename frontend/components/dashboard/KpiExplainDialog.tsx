"use client"

import Link from "next/link"
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog"
import {
  KPI_EXPLANATIONS,
  describeKpiContext,
  type DashboardKpiId,
} from "@/lib/dashboard-kpi-explanations"

/** Contexto vigente del Tablero que el diálogo necesita para ser exacto. */
export interface KpiExplainContext {
  /** Cualquier fecha dentro del mes del selector de período. */
  periodDate: Date
  /** Nombre de la sucursal activa; `null` = todas. */
  branchName: string | null
}

interface KpiExplainDialogProps {
  kpi: DashboardKpiId
  context: KpiExplainContext
  open: boolean
  onOpenChange: (open: boolean) => void
  /** Elemento que abrió el diálogo: Radix sólo devuelve el foco a un
   *  `DialogTrigger`, y acá el diálogo es controlado y vive junto a la
   *  tarjeta, así que el foco se devuelve explícitamente a este nodo. */
  returnFocusRef?: React.RefObject<HTMLElement | null>
}

function Section({ title, children }: { title: string; children: React.ReactNode }) {
  return (
    <section className="flex flex-col gap-1">
      <h3 className="text-xs font-semibold uppercase tracking-wider text-muted-foreground">{title}</h3>
      {children}
    </section>
  )
}

/**
 * tablero-explicable (D4): «de dónde sale este número». Diálogo superpuesto
 * (Radix: cruz arriba a la derecha, `Esc`, clic afuera, foco atrapado y
 * devuelto a la tarjeta) con los textos del catálogo único
 * `KPI_EXPLANATIONS`, contextualizado al período y la sucursal vigentes.
 */
export function KpiExplainDialog({ kpi, context, open, onOpenChange, returnFocusRef }: KpiExplainDialogProps) {
  const e = KPI_EXPLANATIONS[kpi]
  const contextLines = describeKpiContext({ ...context, kpi })

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent
        className="max-w-md"
        closeLabel="Cerrar"
        onCloseAutoFocus={(event) => {
          if (returnFocusRef?.current) {
            event.preventDefault()
            returnFocusRef.current.focus()
          }
        }}
      >
        <DialogHeader className="pr-6">
          <DialogTitle>{e.title}</DialogTitle>
          <DialogDescription>{e.what}</DialogDescription>
        </DialogHeader>

        <div className="flex flex-col gap-4 text-sm text-foreground">
          <Section title="Cómo se calcula">
            <p>{e.formula}</p>
          </Section>

          <Section title="Período y filtros">
            <ul className="flex flex-col gap-0.5">
              {contextLines.map((line) => (
                <li key={line}>{line}</li>
              ))}
            </ul>
            {e.branchNote && <p className="text-muted-foreground">{e.branchNote}</p>}
          </Section>

          <Section title="De dónde salen los datos">
            <p>{e.sources}</p>
          </Section>

          <Section title="No incluye">
            <ul className="list-disc pl-5 flex flex-col gap-0.5">
              {e.excludes.map((x) => (
                <li key={x}>{x}</li>
              ))}
            </ul>
          </Section>

          {e.notes?.map((note) => (
            <p key={note} className="rounded-md bg-muted/50 px-3 py-2 text-muted-foreground">
              {note}
            </p>
          ))}

          <Link
            href={e.link.href}
            onClick={() => onOpenChange(false)}
            className="self-start font-medium text-primary underline underline-offset-2 hover:text-primary/80 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring focus-visible:ring-offset-2 focus-visible:ring-offset-background rounded-sm"
          >
            Ver el detalle en {e.link.label}
          </Link>
        </div>
      </DialogContent>
    </Dialog>
  )
}
