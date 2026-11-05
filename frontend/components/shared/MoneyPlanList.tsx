"use client"

/**
 * MoneyPlanList — la lista "qué pasa con el dinero" que comparten el diálogo de BORRADO y el de EDICIÓN
 * (edicion-operaciones-con-dinero, tanda C, D17): un solo componente, sin lógica de negocio. Los textos los redacta
 * `lib/money-plan.ts` (la edición) y `lib/delete-compensation.ts` (el borrado); acá sólo se dibujan, con el libro como
 * rótulo cuando el ítem lo trae. Un ítem es un texto suelto o `{ book, text }`.
 */

import type { MoneyPlanBook, MoneyPlanItem } from "@/lib/money-plan"
import { cn } from "@/lib/utils"

const BOOK_LABEL: Record<MoneyPlanBook, string> = {
  account: "Cuenta corriente",
  cash: "Caja",
  bank: "Banco",
  fiscal: "Comprobante",
}

interface MoneyPlanListProps {
  title: string
  items: Array<string | MoneyPlanItem>
  className?: string
}

export function MoneyPlanList({ title, items, className }: MoneyPlanListProps) {
  if (items.length === 0) return null
  return (
    <div className={cn("rounded-md border border-border bg-accent/30 p-3", className)}>
      <p className="mb-1.5 font-medium text-foreground">{title}</p>
      <ul className="list-disc space-y-1 pl-4">
        {items.map((item) => {
          const text = typeof item === "string" ? item : item.text
          const label = typeof item === "string" ? null : BOOK_LABEL[item.book]
          return (
            <li key={`${label ?? ""}${text}`}>
              {label && <span className="font-medium text-foreground">{label}: </span>}
              {text}
            </li>
          )
        })}
      </ul>
    </div>
  )
}
