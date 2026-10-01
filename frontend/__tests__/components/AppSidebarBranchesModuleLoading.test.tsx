/**
 * AppSidebar — "Sucursales" y "Por Sucursal" mientras cargan los límites del plan
 * (tablero-menu-pulido P6).
 *
 * Los dos módulos son `proOnly`: dependen de `hasBranchesModule`. El sidebar lo
 * leía SÓLO de `usePlanLimits().limits` (una consulta de red a `plan_limits`),
 * con `?? false` mientras llegaba: los ítems aparecían con demora aunque el
 * plan efectivo de la cuenta ya estaba resuelto (el AuthProvider no monta el
 * layout hasta resolver la sesión). Ahora, mientras `limits` no llegó, se usa
 * el valor ESTÁTICO del plan efectivo (PLAN_LIMITS, el mismo que el hook ya usa
 * como fallback si la consulta falla); cuando llega el valor de la base, ése
 * manda. Una cuenta sin el módulo nunca ve los ítems, ni durante la carga.
 */
import { describe, it, expect, vi, beforeEach } from "vitest"
import { render, screen } from "@testing-library/react"
import userEvent from "@testing-library/user-event"
import { readFileSync } from "node:fs"
import path from "node:path"
import type { Plan } from "@/lib/types"
import { PLAN_LIMITS } from "@/lib/constants"

const h = vi.hoisted(() => ({
  pathname: "/dashboard",
  auth: {
    user: { name: "gonzalo sevilla", role: "user" } as { name: string; role: string },
    logout: async () => {},
    isAdmin: false,
    effectivePlan: "gratis" as Plan,
  },
  // undefined = la consulta a plan_limits todavía no respondió.
  limits: undefined as { hasBranchesModule: boolean } | undefined,
}))

vi.mock("next/navigation", () => ({
  usePathname: () => h.pathname,
}))

vi.mock("@/contexts/auth-context", () => ({
  useAuth: () => h.auth,
}))

vi.mock("@/hooks/auth/use-plan-limits", () => ({
  usePlanLimits: () => ({ limits: h.limits }),
}))

vi.mock("@/components/mode-toggle", () => ({
  ModeToggle: () => <div data-testid="mode-toggle" />,
}))

import { AppSidebar } from "@/components/app-sidebar"
import { SidebarProvider } from "@/components/ui/sidebar"

const cancelarNavegacion = (e: Event) => e.preventDefault()

beforeEach(() => {
  h.pathname = "/dashboard"
  h.auth.isAdmin = false
  h.auth.user = { name: "gonzalo sevilla", role: "user" }
  h.auth.effectivePlan = "gratis"
  h.limits = undefined
  document.addEventListener("click", cancelarNavegacion)
  return () => document.removeEventListener("click", cancelarNavegacion)
})

function renderSidebar() {
  return render(
    <SidebarProvider defaultOpen>
      <AppSidebar />
    </SidebarProvider>,
  )
}

const trigger = (label: string) => screen.getByRole("button", { name: label })
const queryLink = (name: string) => screen.queryByRole("link", { name })

/** Abre las dos categorías que contienen los módulos de sucursales. */
async function abrirCatalogoYEstadisticas(user: ReturnType<typeof userEvent.setup>) {
  await user.click(trigger("Catálogo"))
  const sucursales = queryLink("Sucursales")
  await user.click(trigger("Estadísticas"))
  const porSucursal = queryLink("Por Sucursal")
  return { sucursales, porSucursal }
}

describe("AppSidebar — módulos de sucursales mientras `plan_limits` carga (P6)", () => {
  it("plan Pro con límites todavía sin cargar: los dos ítems ya están, sin esperar la consulta", async () => {
    h.auth.effectivePlan = "pro"
    h.limits = undefined
    renderSidebar()

    const { sucursales, porSucursal } = await abrirCatalogoYEstadisticas(userEvent.setup())

    expect(sucursales).toHaveAttribute("href", "/sucursales")
    expect(porSucursal).toHaveAttribute("href", "/reportes/sucursal")
  })

  it.each<Plan>(["gratis", "inicial", "avanzado"])(
    "plan %s con límites sin cargar: los ítems NO aparecen, ni por un instante",
    async (plan) => {
      h.auth.effectivePlan = plan
      h.limits = undefined
      renderSidebar()

      const { sucursales, porSucursal } = await abrirCatalogoYEstadisticas(userEvent.setup())

      expect(sucursales).toBeNull()
      expect(porSucursal).toBeNull()
    },
  )

  it("cuando llega el valor de la base, ése manda: Pro sin el módulo en la base los oculta", async () => {
    h.auth.effectivePlan = "pro"
    h.limits = { hasBranchesModule: false }
    renderSidebar()

    const { sucursales, porSucursal } = await abrirCatalogoYEstadisticas(userEvent.setup())

    expect(sucursales).toBeNull()
    expect(porSucursal).toBeNull()
  })

  it("y al revés: un plan con el módulo habilitado en la base los muestra aunque el estático diga que no", async () => {
    h.auth.effectivePlan = "avanzado"
    h.limits = { hasBranchesModule: true }
    renderSidebar()

    const { sucursales, porSucursal } = await abrirCatalogoYEstadisticas(userEvent.setup())

    expect(sucursales).toHaveAttribute("href", "/sucursales")
    expect(porSucursal).toHaveAttribute("href", "/reportes/sucursal")
  })

  it("al llegar los límites (re-render) el menú pasa del valor estático al de la base sin parpadeo para quien no tiene el módulo", async () => {
    h.auth.effectivePlan = "avanzado"
    h.limits = undefined
    const { rerender } = renderSidebar()
    const user = userEvent.setup()
    await user.click(trigger("Catálogo"))
    expect(queryLink("Sucursales")).toBeNull()

    h.limits = { hasBranchesModule: false }
    rerender(
      <SidebarProvider defaultOpen>
        <AppSidebar />
      </SidebarProvider>,
    )
    expect(queryLink("Sucursales")).toBeNull()
  })
})

// El valor estático sólo es seguro mientras coincida con el seed de `plan_limits`
// ("If you change a limit, update BOTH this object AND the migration seed",
// lib/constants.ts). Guard de paridad sobre la columna que decide estos ítems.
describe("PLAN_LIMITS.hasBranchesModule coincide con el seed de plan_limits", () => {
  const migration = readFileSync(
    path.resolve(__dirname, "../../../supabase/migrations/20260605000001_billing_schema.sql"),
    "utf8",
  )
  // Sólo las tuplas del INSERT: antes, la PRIMERA aparición de "('gratis'," es
  // el CHECK de billing_plan (`IN ('gratis', 'inicial', ...)`), no la fila del
  // seed — la búsqueda sobre el archivo entero leía ahí y el plan gratis pasaba
  // en vacío (tablero-menu-pulido, ronda 2 de revisión).
  const insertAt = migration.indexOf("INSERT INTO public.plan_limits")
  const valuesAt = migration.indexOf("VALUES", insertAt)
  if (insertAt < 0 || valuesAt < 0) {
    throw new Error("no encontré el INSERT ... VALUES de plan_limits en el seed")
  }
  const seed = migration.slice(valuesAt)
  // Fila del seed: ('pro', 69900, 10, ..., true, true, 'advanced') — la columna
  // has_branches_module es la 16ª del INSERT (índice 15).
  const HAS_BRANCHES_MODULE_INDEX = 15
  // Columnas del INSERT de plan_limits (plan + 17 valores). Una tupla con otra
  // cantidad no es una fila del seed: falla en vez de leer `false`.
  const SEED_ROW_CELLS = 18

  function seedHasBranchesModule(plan: Plan): boolean {
    const row = new RegExp(`\\('${plan}',([^)]*)\\)`).exec(seed)
    if (!row) throw new Error(`no encontré la fila de '${plan}' en el seed de plan_limits`)
    const cells = `'${plan}',${row[1]}`.split(",").map((c) => c.trim())
    if (cells.length !== SEED_ROW_CELLS) {
      throw new Error(
        `la tupla de '${plan}' tiene ${cells.length} celdas, no ${SEED_ROW_CELLS}: no es la fila del INSERT (${row[0]})`,
      )
    }
    return cells[HAS_BRANCHES_MODULE_INDEX] === "true"
  }

  it.each<Plan>(["gratis", "inicial", "avanzado", "pro"])("plan %s", (plan) => {
    expect(PLAN_LIMITS[plan].hasBranchesModule).toBe(seedHasBranchesModule(plan))
  })

  it("el seed lee de verdad la columna: sólo Pro tiene el módulo", () => {
    expect(
      (["gratis", "inicial", "avanzado", "pro"] as Plan[]).filter(seedHasBranchesModule),
    ).toEqual(["pro"])
  })
})
