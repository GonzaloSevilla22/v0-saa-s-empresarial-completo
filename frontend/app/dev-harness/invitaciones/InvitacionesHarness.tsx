"use client"

/**
 * invitaciones-hardening (task 9.3) — pasada visual del estado de entrega en `/organizacion/invitar`.
 *
 * Monta el `PendingInvitations` REAL (el mismo de la pantalla) sin sesión ni backend. El listado se siembra en la
 * caché de react-query con la MISMA clave que usa `useInvitations` sin cuenta (`queryKeys.invitations.list(null)`:
 * la consulta queda deshabilitada y sirve lo sembrado), con las cuatro entregas posibles más una nunca enviada y
 * una vencida. `window.fetch` hacia el backend se intercepta (en CI el backend real respondería 401 y el transporte
 * navegaría al login): un reenvío devuelve un token sintético.
 *
 *   ?theme=light|dark   escribe la clase `dark` en `<html>` igual que next-themes.
 */

import { useEffect, useState } from "react"
import { useQueryClient } from "@tanstack/react-query"
import { PendingInvitations } from "@/components/invitations/PendingInvitations"
import { queryKeys } from "@/lib/query-keys"
import type { InvitationRow } from "@/hooks/data/use-invitations"

const BASE: Omit<InvitationRow, "id" | "email" | "last_delivery_status" | "last_delivery_at"> = {
  roles: ["seller"],
  role_labels: ["Vendedor"],
  state: "pending",
  created_at: "2026-11-05T12:00:00+00:00",
  expires_at: "2026-11-12T12:00:00+00:00",
  invited_by: "u1",
  invited_by_name: "Dueño",
  last_sent_at: "2026-11-05T12:00:05+00:00",
  send_count: 1,
}

const ROWS: InvitationRow[] = [
  { ...BASE, id: "i1", email: "enviada@ejemplo.com", last_delivery_status: "sent", last_delivery_at: "2026-11-05T12:00:09+00:00" },
  { ...BASE, id: "i2", email: "en-cola@ejemplo.com", last_delivery_status: "queued", last_delivery_at: "2026-11-05T12:00:05+00:00" },
  { ...BASE, id: "i3", email: "fallida@ejemplo.com", last_delivery_status: "failed", last_delivery_at: "2026-11-05T12:00:06+00:00" },
  { ...BASE, id: "i4", email: "sin-confirmacion-con-un-correo-bastante-largo-para-probar-el-corte@ejemplo.com", roles: ["admin", "cashier"], role_labels: ["Administrador", "Cajero"], last_delivery_status: "unconfirmed", last_delivery_at: "2026-11-05T12:00:05+00:00" },
  { ...BASE, id: "i5", email: "nunca-enviada@ejemplo.com", send_count: 0, last_sent_at: null, last_delivery_status: null, last_delivery_at: null },
  { ...BASE, id: "i6", email: "vencida@ejemplo.com", state: "expired", expires_at: "2026-11-01T12:00:00+00:00", last_delivery_status: "failed", last_delivery_at: "2026-10-25T12:00:06+00:00" },
]

/** Backend simulado: el reenvío responde con un token sintético; el resto, vacío. */
function installFetchIntercept() {
  const original = window.fetch.bind(window)
  window.fetch = async (input: RequestInfo | URL, init?: RequestInit) => {
    const url = typeof input === "string" ? input : input instanceof URL ? input.toString() : input.url
    const backend = process.env.NEXT_PUBLIC_BACKEND_URL ?? "http://localhost:8000"
    if (!(url.startsWith(backend) || url.startsWith("/api/"))) return original(input, init)
    const path = url.slice(backend.length).split("?")[0]
    const json = (body: unknown) =>
      new Response(JSON.stringify(body), { status: 200, headers: { "Content-Type": "application/json" } })
    if (path.endsWith("/resend")) {
      return json({ id: "i3", email: "fallida@ejemplo.com", roles: ["seller"], expires_at: "2026-11-13T12:00:00+00:00", token: "f".repeat(64), email_queued: true })
    }
    return json([])
  }
  return () => {
    window.fetch = original
  }
}

export function InvitacionesHarness() {
  const queryClient = useQueryClient()
  const [ready, setReady] = useState(false)

  useEffect(() => {
    const uninstall = installFetchIntercept()
    const params = new URLSearchParams(window.location.search)
    document.documentElement.classList.toggle("dark", params.get("theme") === "dark")
    queryClient.setQueryData(queryKeys.invitations.list(null), ROWS)
    setReady(true)
    return uninstall
  }, [queryClient])

  return (
    <main className="mx-auto flex min-h-screen max-w-3xl flex-col gap-4 p-4 sm:p-6">
      <h1 className="text-xl font-semibold text-foreground">Arnés — invitaciones con estado de entrega</h1>
      {ready && <PendingInvitations />}
    </main>
  )
}
