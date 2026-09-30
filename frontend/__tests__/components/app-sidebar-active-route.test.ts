/**
 * app-sidebar — regla del ítem / grupo activo (sidebar-menu-grupos, D4).
 *
 * Con el menú plegado, el usuario sólo sabe dónde está si el GRUPO que contiene
 * su pantalla se ve marcado. Y como hay rutas anidadas (/ventas y /ventas/pos,
 * /estadisticas y /estadisticas/productos/:id) la regla no puede ser igualdad
 * estricta (el detalle de un producto quedaría sin marcar) ni prefijo a secas
 * (/ventas/pos marcaría Ventas Y POS): gana el href coincidente MÁS LARGO.
 *
 * Son funciones puras: se testean sin montar nada.
 */
import { describe, it, expect } from "vitest"
import {
  dashboardItem,
  findActiveGroupLabel,
  getActiveHref,
  isItemActive,
  navGroups,
  type NavGroup,
} from "@/components/app-sidebar"
import { Package } from "lucide-react"

const HREFS = ["/dashboard", "/ventas", "/ventas/pos", "/estadisticas", "/reportes/formas-pago"]

describe("getActiveHref — prefijo más largo", () => {
  it("coincidencia exacta", () => {
    expect(getActiveHref("/ventas", HREFS)).toBe("/ventas")
    expect(getActiveHref("/estadisticas", HREFS)).toBe("/estadisticas")
  })

  it("una subruta activa a su ancestro cuando ningún otro href la reclama", () => {
    expect(getActiveHref("/estadisticas/productos/abc-123", HREFS)).toBe("/estadisticas")
    expect(getActiveHref("/ventas/historial", HREFS)).toBe("/ventas")
  })

  it("gana el href más largo: /ventas/pos activa POS y no Ventas", () => {
    expect(getActiveHref("/ventas/pos", HREFS)).toBe("/ventas/pos")
    expect(getActiveHref("/ventas/pos/cierre", HREFS)).toBe("/ventas/pos")
  })

  it("el orden de la lista no cambia el resultado", () => {
    const invertida = [...HREFS].reverse()
    expect(getActiveHref("/ventas/pos", invertida)).toBe("/ventas/pos")
    expect(getActiveHref("/ventas", invertida)).toBe("/ventas")
  })

  it("el prefijo se corta en el separador: /ventas-archivo NO activa /ventas", () => {
    expect(getActiveHref("/ventas-archivo", HREFS)).toBeNull()
    expect(getActiveHref("/estadisticasx", HREFS)).toBeNull()
  })

  it("sin coincidencia devuelve null", () => {
    expect(getActiveHref("/configuracion", HREFS)).toBeNull()
    expect(getActiveHref("/", HREFS)).toBeNull()
    expect(getActiveHref("/ventas", [])).toBeNull()
  })

  it("tolera la barra final", () => {
    expect(getActiveHref("/ventas/", HREFS)).toBe("/ventas")
    expect(getActiveHref("/ventas/pos/", HREFS)).toBe("/ventas/pos")
  })
})

describe("isItemActive", () => {
  it("sólo el ganador del prefijo más largo está activo", () => {
    expect(isItemActive("/ventas/pos", "/ventas/pos", HREFS)).toBe(true)
    expect(isItemActive("/ventas/pos", "/ventas", HREFS)).toBe(false)
  })

  it("un ítem no está activo en una ruta ajena", () => {
    expect(isItemActive("/dashboard", "/ventas", HREFS)).toBe(false)
    expect(isItemActive("/estadisticas/productos/x", "/estadisticas", HREFS)).toBe(true)
  })
})

describe("findActiveGroupLabel — el grupo que contiene la pantalla actual", () => {
  it.each([
    ["/ventas", "Operaciones"],
    ["/ventas/pos", "Operaciones"],
    ["/cobranzas", "Operaciones"],
    ["/proveedores", "Catálogo"],
    ["/copiloto-ia", "Inteligencia"],
    ["/estadisticas", "Estadísticas"],
    ["/estadisticas/productos/abc", "Estadísticas"],
    ["/reportes/formas-pago", "Estadísticas"],
    ["/reportes/libro-diario", "Estadísticas"],
    ["/seguros", "Ecosistema"],
    ["/exportaciones", "Mi Cuenta"],
  ])("%s → %s", (pathname, label) => {
    expect(findActiveGroupLabel(pathname, navGroups)).toBe(label)
  })

  it("el Tablero no pertenece a ningún grupo", () => {
    expect(findActiveGroupLabel(dashboardItem.href, navGroups)).toBeNull()
  })

  it("una ruta fuera del menú (Configuración, Administración) no marca ningún grupo", () => {
    expect(findActiveGroupLabel("/configuracion", navGroups)).toBeNull()
    expect(findActiveGroupLabel("/admin/metricas", navGroups)).toBeNull()
  })

  it("sólo considera los grupos que recibe: un grupo oculto no se marca", () => {
    const sinCatalogo: NavGroup[] = navGroups.filter((g) => g.label !== "Catálogo")
    expect(findActiveGroupLabel("/productos", sinCatalogo)).toBeNull()
    expect(findActiveGroupLabel("/ventas", sinCatalogo)).toBe("Operaciones")
  })

  it("con un grupo sintético que reclama una subruta más larga, gana esa subruta", () => {
    const grupos: NavGroup[] = [
      { label: "A", icon: Package, items: [{ title: "Base", href: "/x", icon: Package, pro: false, proOnly: false }] },
      { label: "B", icon: Package, items: [{ title: "Hija", href: "/x/y", icon: Package, pro: false, proOnly: false }] },
    ]
    expect(findActiveGroupLabel("/x/y/z", grupos)).toBe("B")
    expect(findActiveGroupLabel("/x/otra", grupos)).toBe("A")
  })
})
