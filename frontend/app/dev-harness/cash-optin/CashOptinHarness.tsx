"use client"

/**
 * caja-optin-carga — pasada visual del bloque «Registrar en caja».
 *
 * Monta el `CashOptinBlock` REAL en sus tres estados, cada uno junto al botón de
 * confirmar que lo acompaña en los formularios, para las 4 combinaciones
 * (desktop / 375 px × claro / oscuro) sin sesión ni backend:
 *
 *   1. cargando — «Verificando la caja…» con el botón deshabilitado (el defecto:
 *      confirmar acá registraba la operación en efectivo SIN movimiento de caja);
 *   2. elegible — la casilla pre-marcada, botón habilitado;
 *   3. sin caja abierta — el motivo, botón habilitado (no se bloquea para siempre).
 *
 * El toggle de tema escribe la clase `dark` en `<html>` igual que next-themes,
 * para que el spec capture los dos temas sin depender del provider.
 */

import { useEffect, useState } from "react"
import { Button } from "@/components/ui/button"
import { CashOptinBlock } from "@/components/cash/CashOptinBlock"
import type { CashOptinState } from "@/hooks/use-cash-optin"
import type { CashSession } from "@/lib/types"

const BASE: CashOptinState = {
  isCashSelected: true,
  isDateToday: true,
  effectiveBranchId: "branch-harness",
  cashboxId: "cashbox-harness",
  session: null,
  eligible: false,
  isLoading: false,
  reason: "No hay caja abierta en esta sucursal — el efectivo no se registrará en el arqueo.",
}

const SESSION = { id: "a1b2c3d4-0000-0000-0000-000000000000" } as CashSession

const STATES: Array<{ id: string; title: string; cash: CashOptinState }> = [
  { id: "cargando", title: "Cargando la sesión de caja", cash: { ...BASE, isLoading: true } },
  { id: "elegible", title: "Sesión abierta", cash: { ...BASE, eligible: true, session: SESSION } },
  { id: "sin-caja", title: "Sin caja abierta", cash: BASE },
]

export function CashOptinHarness() {
  const [registerInCash, setRegisterInCash] = useState(true)

  // Tema por querystring (?theme=dark) para que el spec no dependa del provider.
  useEffect(() => {
    const theme = new URLSearchParams(window.location.search).get("theme")
    document.documentElement.classList.toggle("dark", theme === "dark")
    document.documentElement.dataset.theme = theme === "dark" ? "dark" : "light"
  }, [])

  return (
    <main className="min-h-screen bg-background p-4">
      <h1 className="mb-4 text-lg font-semibold text-foreground">Arnés — Opt-in de caja</h1>
      <div className="mx-auto flex max-w-md flex-col gap-6">
        {STATES.map(({ id, title, cash }) => (
          <section
            key={id}
            data-testid={`estado-${id}`}
            aria-label={title}
            className="flex flex-col gap-3 rounded-lg border border-border bg-card p-4"
          >
            <h2 className="text-sm font-medium text-foreground">{title}</h2>
            <CashOptinBlock
              cash={cash}
              registerInCash={registerInCash}
              onRegisterInCashChange={setRegisterInCash}
            />
            <Button type="button" className="w-full" disabled={cash.isLoading}>
              Confirmar compra
            </Button>
          </section>
        ))}
      </div>
    </main>
  )
}
