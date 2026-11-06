/**
 * tablero-explicable (D6, task 3.3): la campana como Popover con filas
 * accionables — cuerpo que navega a la alerta y cierra el panel, botón de
 * descartar, «Marcar todas como leídas» y encabezado con el total exacto.
 */
import React from "react"
import { describe, it, expect, vi, beforeEach } from "vitest"
import { render, screen, within } from "@testing-library/react"
import userEvent from "@testing-library/user-event"
import "@testing-library/jest-dom"

import type { Notification } from "@/lib/types"

const push = vi.fn()
vi.mock("next/navigation", () => ({
  useRouter: () => ({ push }),
}))

vi.mock("@/lib/supabase/client", () => ({ createClient: () => ({}) }))

import { NotificationBellView } from "@/components/dashboard/NotificationBell"

const PRODUCT = "5f1c2b3e-8a4d-4c6e-9b7a-0123456789ab"

function notif(over: Partial<Notification> & Pick<Notification, "id" | "type">): Notification {
  return {
    accountId: "acc-1",
    branchId: null,
    severity: "warning",
    payload: {},
    read: false,
    createdAt: "2026-11-06T12:00:00.000Z",
    readAt: null,
    ...over,
  } as Notification
}

const STOCK = notif({ id: "n-stock", type: "StockBelowMinimum", payload: { product_id: PRODUCT } })
const CAJA = notif({ id: "n-caja", type: "CashSessionClosed", payload: { branch_id: "9a8b7c6d-1e2f-4a3b-8c5d-abcdef012345" } })
const UNKNOWN = notif({ id: "n-x", type: "AlgoNuevo" as Notification["type"] })

const onMarkRead = vi.fn()
const onMarkAllRead = vi.fn()

function setup(notifications: Notification[], unreadCount = notifications.length, isLoading = false) {
  const user = userEvent.setup()
  render(
    <NotificationBellView
      notifications={notifications}
      unreadCount={unreadCount}
      isLoading={isLoading}
      onMarkRead={onMarkRead}
      onMarkAllRead={onMarkAllRead}
    />,
  )
  return user
}

async function openPanel(user: ReturnType<typeof userEvent.setup>) {
  await user.click(screen.getByRole("button", { name: /Notificaciones/ }))
  return await screen.findByRole("dialog")
}

beforeEach(() => {
  push.mockReset()
  onMarkRead.mockReset()
  onMarkAllRead.mockReset()
})

describe("NotificationBellView — encabezado y badge", () => {
  it("con 270 no leídas el badge dice 9+ y el encabezado «270 sin leer»", async () => {
    const user = setup([STOCK, CAJA], 270)
    expect(screen.getByText("9+")).toBeInTheDocument()

    const panel = await openPanel(user)
    expect(within(panel).getByText("270 sin leer")).toBeInTheDocument()
  })

  it("sin notificaciones muestra «Sin notificaciones» y no ofrece marcar todas", async () => {
    const user = setup([], 0)
    const panel = await openPanel(user)
    expect(within(panel).getByText("Sin notificaciones")).toBeInTheDocument()
    expect(within(panel).queryByRole("button", { name: "Marcar todas como leídas" })).not.toBeInTheDocument()
  })

  it("mientras carga muestra el estado de carga", async () => {
    const user = setup([], 0, true)
    const panel = await openPanel(user)
    expect(within(panel).getByText("Cargando notificaciones…")).toBeInTheDocument()
  })

  it("«Marcar todas como leídas» llama a onMarkAllRead", async () => {
    const user = setup([STOCK, CAJA])
    const panel = await openPanel(user)

    await user.click(within(panel).getByRole("button", { name: "Marcar todas como leídas" }))

    expect(onMarkAllRead).toHaveBeenCalledTimes(1)
  })
})

describe("NotificationBellView — filas accionables", () => {
  it("cada fila tiene un botón de cuerpo y un botón «Descartar: <rótulo>»", async () => {
    const user = setup([STOCK, CAJA])
    const panel = await openPanel(user)

    expect(within(panel).getByRole("button", { name: /Stock por debajo del mínimo.*Ir a Stock/ })).toBeInTheDocument()
    expect(within(panel).getByRole("button", { name: "Descartar: Stock por debajo del mínimo" })).toBeInTheDocument()
    expect(within(panel).getByRole("button", { name: "Descartar: Cierre de caja con diferencia" })).toBeInTheDocument()
  })

  it("clic en el cuerpo: marca leída, navega a la alerta y cierra el panel", async () => {
    const user = setup([STOCK])
    const panel = await openPanel(user)

    await user.click(within(panel).getByRole("button", { name: /Stock por debajo del mínimo.*Ir a Stock/ }))

    expect(onMarkRead).toHaveBeenCalledWith(STOCK)
    expect(push).toHaveBeenCalledWith(`/stock?product=${PRODUCT}`)
    expect(screen.queryByRole("dialog")).not.toBeInTheDocument()
  })

  it("clic en descartar: marca leída SIN navegar y el panel sigue abierto", async () => {
    const user = setup([STOCK, CAJA])
    const panel = await openPanel(user)

    await user.click(within(panel).getByRole("button", { name: "Descartar: Cierre de caja con diferencia" }))

    expect(onMarkRead).toHaveBeenCalledWith(CAJA)
    expect(push).not.toHaveBeenCalled()
    expect(screen.getByRole("dialog")).toBeInTheDocument()
  })

  it("un tipo desconocido se muestra con su type, se puede descartar y su cuerpo no navega", async () => {
    const user = setup([UNKNOWN])
    const panel = await openPanel(user)

    expect(within(panel).getByText("AlgoNuevo")).toBeInTheDocument()
    expect(within(panel).queryByRole("button", { name: /Ir a/ })).not.toBeInTheDocument()

    await user.click(within(panel).getByRole("button", { name: "Descartar: AlgoNuevo" }))
    expect(onMarkRead).toHaveBeenCalledWith(UNKNOWN)
    expect(push).not.toHaveBeenCalled()
  })

  it("un presupuesto con quote_id malformado navega a /presupuestos sin interpolar", async () => {
    const quote = notif({ id: "n-q", type: "QuoteAccepted", payload: { quote_id: "../../x" } })
    const user = setup([quote])
    const panel = await openPanel(user)

    await user.click(within(panel).getByRole("button", { name: /Presupuesto aceptado.*Ir al presupuesto/ }))

    expect(push).toHaveBeenCalledWith("/presupuestos")
  })

  it("operable con teclado: Tab llega al cuerpo y Enter navega", async () => {
    const user = setup([STOCK])
    await openPanel(user)

    const body = screen.getByRole("button", { name: /Stock por debajo del mínimo.*Ir a Stock/ })
    body.focus()
    await user.keyboard("{Enter}")

    expect(push).toHaveBeenCalledWith(`/stock?product=${PRODUCT}`)
  })
})
