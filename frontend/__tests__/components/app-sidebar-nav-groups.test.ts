/**
 * app-sidebar navGroups — entrada "Proveedores" (compras-proveedor-cuenta-corriente,
 * task 11.4). D9: cuelga del grupo Catálogo, inmediatamente debajo de "Clientes"
 * (un proveedor es un maestro, no una operación — simetría con "Clientes").
 *
 * Se testea la estructura de datos directamente (navGroups exportado) en vez de
 * montar <AppSidebar/> (requeriría SidebarProvider + mocks de useAuth/usePlanLimits
 * sin aportar cobertura adicional sobre el riesgo real: href/ícono/posición).
 */
import { describe, it, expect } from "vitest"
import { navGroups } from "@/components/app-sidebar"
import { BarChart3, Truck, Users } from "lucide-react"

describe("app-sidebar navGroups — entrada Proveedores", () => {
  const catalogo = navGroups.find((g) => g.label === "Catálogo")

  it("el grupo Catálogo existe", () => {
    expect(catalogo).toBeDefined()
  })

  it("existe una entrada 'Proveedores' con href /proveedores e ícono Truck", () => {
    const item = catalogo?.items.find((i) => i.title === "Proveedores")
    expect(item).toBeDefined()
    expect(item?.href).toBe("/proveedores")
    expect(item?.icon).toBe(Truck)
    expect(item?.pro).toBe(false)
    expect(item?.proOnly).toBe(false)
  })

  it("aparece inmediatamente después de 'Clientes'", () => {
    const items = catalogo?.items ?? []
    const clientesIdx = items.findIndex((i) => i.title === "Clientes")
    const proveedoresIdx = items.findIndex((i) => i.title === "Proveedores")
    expect(clientesIdx).toBeGreaterThanOrEqual(0)
    expect(proveedoresIdx).toBe(clientesIdx + 1)
  })

  it("Clientes conserva su ícono Users (no se pisó al insertar Proveedores)", () => {
    const item = catalogo?.items.find((i) => i.title === "Clientes")
    expect(item?.icon).toBe(Users)
  })
})

// cobranzas-panel (task 5.5, D11): la cobranza es una tarea diaria del
// negocio — cuelga de Operaciones (junto a Caja y Banco), no de Análisis.
describe("app-sidebar navGroups — entrada Cobranzas (cobranzas-panel)", () => {
  const operaciones = navGroups.find((g) => g.label === "Operaciones")

  it("el grupo Operaciones existe", () => {
    expect(operaciones).toBeDefined()
  })

  it("existe una entrada 'Cobranzas' con href /cobranzas, sin gate de plan", () => {
    const item = operaciones?.items.find((i) => i.title === "Cobranzas")
    expect(item).toBeDefined()
    expect(item?.href).toBe("/cobranzas")
    expect(item?.pro).toBe(false)
    expect(item?.proOnly).toBe(false)
  })

  it("convive con Caja y Banco dentro del mismo grupo (D11)", () => {
    const titles = (operaciones?.items ?? []).map((i) => i.title)
    expect(titles).toContain("Caja")
    expect(titles).toContain("Banco")
    expect(titles).toContain("Cobranzas")
  })
})

// estadisticas-ventas E1 (task 4.9): el módulo de estadísticas cuelga de
// Inteligencia, sin gate de plan — disponible en todos los planes; el
// historial se recorta en el servidor (D8).
describe("app-sidebar navGroups — entrada Estadísticas (estadisticas-ventas)", () => {
  const inteligencia = navGroups.find((g) => g.label === "Inteligencia")

  it("existe una entrada 'Estadísticas' con href /estadisticas e ícono BarChart3, sin gate", () => {
    const item = inteligencia?.items.find((i) => i.title === "Estadísticas")
    expect(item).toBeDefined()
    expect(item?.href).toBe("/estadisticas")
    expect(item?.icon).toBe(BarChart3)
    expect(item?.pro).toBe(false)
    expect(item?.proOnly).toBe(false)
  })

  it("aparece inmediatamente antes de 'Rentabilidad' (responde qué se vende; Rentabilidad, qué deja margen)", () => {
    const items = inteligencia?.items ?? []
    const estadisticasIdx = items.findIndex((i) => i.title === "Estadísticas")
    const rentabilidadIdx = items.findIndex((i) => i.title === "Rentabilidad")
    expect(estadisticasIdx).toBeGreaterThanOrEqual(0)
    expect(rentabilidadIdx).toBe(estadisticasIdx + 1)
  })
})
