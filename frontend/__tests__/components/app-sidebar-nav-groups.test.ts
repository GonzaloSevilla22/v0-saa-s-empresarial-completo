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
import { Truck, Users } from "lucide-react"

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
