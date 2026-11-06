"use client"

import { useRef, useState } from "react"
import { cn } from "@/lib/utils"
import { KpiExplainDialog, type KpiExplainContext } from "@/components/dashboard/KpiExplainDialog"
import type { DashboardKpiId } from "@/lib/dashboard-kpi-explanations"

/** Prop opcional de las tarjetas KPI base: qué explicar y con qué contexto. */
export interface KpiExplanationProp {
  id: DashboardKpiId
  context: KpiExplainContext
}

interface KpiExplainTriggerProps {
  explanation: KpiExplanationProp
  /** Título de la tarjeta (nombre accesible: «<título>: <valor>. Ver de dónde sale»). */
  title: string
  /** Valor ya formateado de la tarjeta. */
  value: string
  /** Radio de la tarjeta, para que el anillo de foco la siga. */
  className?: string
  children: React.ReactNode
}

/**
 * tablero-explicable (D4): envuelve el contenido de una tarjeta KPI en un
 * botón que abre «de dónde sale este número». Definido una vez, en la capa
 * canónica, para que `KpiSummaryCard` y `KpiCard` compartan botón, nombre
 * accesible, foco visible y diálogo (no cada pantalla por su cuenta).
 */
export function KpiExplainTrigger({ explanation, title, value, className, children }: KpiExplainTriggerProps) {
  const [open, setOpen] = useState(false)
  const buttonRef = useRef<HTMLButtonElement>(null)

  return (
    <>
      <button
        ref={buttonRef}
        type="button"
        aria-haspopup="dialog"
        aria-label={`${title}: ${value}. Ver de dónde sale`}
        onClick={() => setOpen(true)}
        className={cn(
          "block w-full text-left transition-colors hover:[&>*]:border-primary/50 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring focus-visible:ring-offset-2 focus-visible:ring-offset-background",
          className,
        )}
      >
        {children}
      </button>
      <KpiExplainDialog
        kpi={explanation.id}
        context={explanation.context}
        open={open}
        onOpenChange={setOpen}
        returnFocusRef={buttonRef}
      />
    </>
  )
}
