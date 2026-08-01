/**
 * billing-pro-trial (D9, task 7.4/7.5): la campana debe renderizar una
 * etiqueta legible para el tipo nuevo `PlanLimitExceeded`, no el identificador
 * crudo del tipo.
 */
import React from "react"
import { describe, it, expect, vi } from "vitest"
import { render, screen } from "@testing-library/react"
import userEvent from "@testing-library/user-event"
import "@testing-library/jest-dom"

import type { Notification } from "@/lib/types"

vi.mock("@/lib/supabase/client", () => ({
  createClient: () => ({}),
}))

const PLAN_LIMIT_NOTIFICATION: Notification = {
  id: "notif-1",
  accountId: "acc-1",
  branchId: null,
  type: "PlanLimitExceeded",
  severity: "warning",
  payload: { resource: "products", current: 2372, limit: 100, plan: "gratis" },
  read: false,
  createdAt: "2026-07-31T12:00:00Z",
  readAt: null,
} as unknown as Notification

function mockUseNotifications(notifications: Notification[]) {
  vi.doMock("@/hooks/data/use-notifications", () => ({
    useNotifications: () => ({
      notifications,
      unreadCount: notifications.filter((n) => !n.read).length,
      isLoading: false,
    }),
    markNotificationRead: vi.fn(),
  }))
}

describe("NotificationBell — PlanLimitExceeded label (task 7.4/7.5)", () => {
  it("renders a human-readable label, not the raw type identifier", async () => {
    vi.resetModules()
    mockUseNotifications([PLAN_LIMIT_NOTIFICATION])
    const { NotificationBell } = await import("@/components/dashboard/NotificationBell")

    const user = userEvent.setup()
    render(<NotificationBell />)

    // Open the dropdown.
    await user.click(screen.getByRole("button"))

    expect(await screen.findByText("Límite de plan excedido")).toBeInTheDocument()
    expect(screen.queryByText("PlanLimitExceeded")).not.toBeInTheDocument()
  })

  it("shows the unread badge count for a PlanLimitExceeded notification", async () => {
    vi.resetModules()
    mockUseNotifications([PLAN_LIMIT_NOTIFICATION])
    const { NotificationBell } = await import("@/components/dashboard/NotificationBell")

    render(<NotificationBell />)

    expect(screen.getByText("1")).toBeInTheDocument()
  })
})
