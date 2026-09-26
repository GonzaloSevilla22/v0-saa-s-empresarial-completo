"use client"

/**
 * fiscal-emision-segura (G5/H3, task 5.5 — pasada visual).
 *
 * Monta `EmitirSuscripcionDialog` con props sintéticas para la pasada visual de
 * las 4 combinaciones (1366 / 375 × claro / oscuro). El diálogo real vive en
 * `/admin/pagos`, que exige sesión de admin y backend; acá no hace falta
 * ninguno de los dos, que es todo el punto del arnés (ver README).
 *
 * El toggle de tema escribe la clase `dark` en `<html>` igual que next-themes,
 * para que el spec pueda capturar los dos temas sin depender del provider.
 */

import { useEffect, useState } from "react"

import { EmitirSuscripcionDialog, type SubscriptionReceipt } from "@/components/fiscal/EmitirSuscripcionDialog"
import type { PointOfSale } from "@/hooks/data/use-points-of-sale"
import type { EmitSubscriptionPaymentInput } from "@/hooks/data/use-emit-subscription-payment"

const RECEIPT: SubscriptionReceipt = {
  id: "rcpt-harness-1",
  receipt_number: "RC-2026-000002",
  payment_id: "mp-harness-1",
  plan: "inicial",
  amount: 12000,
  customer_email: "cliente.harness@test.local",
  customer_name: "Cliente de Arnés",
}

const PVS: PointOfSale[] = [
  {
    id: "pv-harness-3",
    fiscalProfileId: "fp-harness",
    accountId: "acc-harness",
    branchId: null,
    numero: 3,
    isActive: true,
    isDefault: false,
    createdAt: "2026-06-24T00:00:00Z",
  },
]

export function EmitirSuscripcionHarness() {
  const [open, setOpen] = useState(true)
  const [ultimoPayload, setUltimoPayload] = useState<string>("")

  // Tema por querystring (?theme=dark) para que el spec no dependa del provider.
  useEffect(() => {
    const theme = new URLSearchParams(window.location.search).get("theme")
    document.documentElement.classList.toggle("dark", theme === "dark")
    document.documentElement.dataset.theme = theme === "dark" ? "dark" : "light"
  }, [])

  function handleConfirm(payload: EmitSubscriptionPaymentInput) {
    setUltimoPayload(JSON.stringify(payload))
  }

  return (
    <main className="min-h-screen bg-background p-4">
      <h1 className="mb-4 text-lg font-semibold text-foreground">
        Arnés — Emitir Factura C de suscripción
      </h1>
      <button
        type="button"
        onClick={() => setOpen(true)}
        className="rounded-md border border-border px-3 py-1.5 text-sm text-foreground"
      >
        Abrir diálogo
      </button>
      <p data-testid="ultimo-payload" className="mt-3 font-mono text-xs text-muted-foreground">
        {ultimoPayload}
      </p>

      <EmitirSuscripcionDialog
        open={open}
        onOpenChange={setOpen}
        receipt={RECEIPT}
        pointsOfSale={PVS}
        onConfirm={handleConfirm}
        isSubmitting={false}
      />
    </main>
  )
}
