/**
 * app-sidebar — estructura de datos del menú lateral agrupado (sidebar-menu-grupos).
 *
 * Pedido del PO (2026-09-30): el menú pasa de "todo desplegado con rótulos" a
 * UN menú por categoría (plegado hasta que lo toquen), con el Tablero suelto
 * arriba —sin el rótulo "Principal"— y un grupo nuevo "Estadísticas".
 *
 * Se testea la estructura de datos directamente (`dashboardItem` / `navGroups`
 * exportados) en vez de montar el árbol: el comportamiento de plegado se cubre
 * en AppSidebarGroups.test.tsx. Lo que este archivo fija es lo que puede
 * romperse en silencio al reorganizar: que NINGUNA ruta se pierda ni se
 * duplique, que cada href siga teniendo su página, y que cada entrada conserve
 * su título, ícono y gates de plan.
 *
 * Las adyacencias que fijaban los tests previos (Proveedores tras Clientes,
 * Estadísticas antes de Rentabilidad, Libro diario tras Formas de pago) se
 * movieron al grupo nuevo en vez de borrarse.
 */
import fs from "node:fs"
import path from "node:path"
import { describe, it, expect } from "vitest"
import { dashboardItem, navGroups } from "@/components/app-sidebar"
import {
  Banknote, BarChart3, BookOpen, Boxes, Briefcase, Brain, Calculator, ChartPie,
  CircleUser, Crown, CreditCard, FileText, FolderDown, GitCompare, GraduationCap, Globe,
  HandCoins, Landmark, LayoutDashboard, LayoutGrid, MapPin, MessageSquare,
  Package, Receipt, Scan, ShieldCheck, ShoppingBag, ShoppingCart, Sparkles,
  Tags, TrendingUp, Truck, Users, Wallet, Warehouse, Zap,
} from "lucide-react"

const item = (label: string, title: string) =>
  navGroups.find((g) => g.label === label)?.items.find((i) => i.title === title)

describe("app-sidebar — Tablero suelto (sin rótulo 'Principal')", () => {
  it("dashboardItem es el Tablero: /dashboard, ícono LayoutDashboard, sin gates", () => {
    expect(dashboardItem.title).toBe("Tablero")
    expect(dashboardItem.href).toBe("/dashboard")
    expect(dashboardItem.icon).toBe(LayoutDashboard)
    expect(dashboardItem.pro).toBe(false)
    expect(dashboardItem.proOnly).toBe(false)
  })

  it("ya no existe ningún grupo 'Principal' ni el Tablero vive dentro de un grupo", () => {
    expect(navGroups.find((g) => g.label === "Principal")).toBeUndefined()
    const tableroEnGrupos = navGroups.flatMap((g) => g.items).filter((i) => i.href === "/dashboard")
    expect(tableroEnGrupos).toEqual([])
  })
})

describe("app-sidebar — los 6 grupos, en el orden pedido", () => {
  it("orden y etiquetas exactas", () => {
    expect(navGroups.map((g) => g.label)).toEqual([
      "Operaciones",
      "Catálogo",
      "Inteligencia",
      "Estadísticas",
      "Ecosistema",
      "Mi Cuenta",
    ])
  })

  it.each([
    ["Operaciones", Briefcase],
    ["Catálogo", Boxes],
    ["Inteligencia", Brain],
    ["Estadísticas", ChartPie],
    ["Ecosistema", Globe],
    ["Mi Cuenta", CircleUser],
  ])("el grupo %s tiene su propio ícono", (label, icon) => {
    const group = navGroups.find((g) => g.label === label)
    expect(group?.icon).toBe(icon)
  })

  it("cada grupo tiene un ícono distinto (el riel colapsado los distingue sólo por ícono)", () => {
    const icons = navGroups.map((g) => g.icon)
    expect(new Set(icons).size).toBe(icons.length)
  })
})

describe("app-sidebar — módulos por grupo (título + href exactos)", () => {
  const ESPERADO: Array<[string, Array<[string, string]>]> = [
    [
      "Operaciones",
      [
        ["Ventas", "/ventas"],
        ["POS — Venta Rápida", "/ventas/pos"],
        // presupuestos-modulo (D10, task 5.9): entre el POS y Compras.
        ["Presupuestos", "/presupuestos"],
        ["Compras", "/compras"],
        ["Gastos", "/gastos"],
        ["Caja", "/caja"],
        ["Banco", "/banco"],
        ["Cobranzas", "/cobranzas"],
      ],
    ],
    [
      "Catálogo",
      [
        ["Productos", "/productos"],
        ["Stock", "/stock"],
        ["Clientes", "/clientes"],
        ["Proveedores", "/proveedores"],
        ["Sucursales", "/sucursales"],
      ],
    ],
    [
      "Inteligencia",
      [
        ["Copiloto IA", "/copiloto-ia"],
        ["Consejos IA", "/insights"],
        ["Feria IA", "/ferias/ia"],
        ["Simulador", "/simulador"],
      ],
    ],
    [
      "Estadísticas",
      [
        ["Estadísticas", "/estadisticas"],
        ["Rentabilidad", "/rentabilidad"],
        ["Comparativo", "/reportes/comparativo"],
        ["Por Sucursal", "/reportes/sucursal"],
        ["Centros de costo", "/reportes/centros-costo"],
        ["Formas de pago", "/reportes/formas-pago"],
        ["Libro diario", "/reportes/libro-diario"],
      ],
    ],
    [
      "Ecosistema",
      [
        ["Comunidad", "/comunidad"],
        ["Cursos", "/cursos"],
        ["Seguros", "/seguros"],
      ],
    ],
    [
      "Mi Cuenta",
      [
        ["Planes", "/planes"],
        ["Facturación", "/facturacion"],
        ["Exportaciones", "/exportaciones"],
      ],
    ],
  ]

  it.each(ESPERADO)("%s contiene exactamente sus módulos y en ese orden", (label, esperado) => {
    const group = navGroups.find((g) => g.label === label)
    expect(group?.items.map((i) => [i.title, i.href])).toEqual(esperado)
  })
})

// El riesgo real de reorganizar un menú: perder una ruta en silencio. Esta es la
// lista literal de los hrefs del menú anterior (Principal + 5 grupos): todos
// tienen que seguir alcanzables, exactamente una vez.
const HREFS_DEL_MENU_VIEJO = [
  "/dashboard",
  "/ventas", "/ventas/pos", "/presupuestos", "/compras", "/gastos", "/caja", "/banco", "/cobranzas",
  "/productos", "/stock", "/clientes", "/proveedores", "/sucursales",
  "/copiloto-ia", "/insights", "/estadisticas", "/rentabilidad",
  "/reportes/comparativo", "/reportes/sucursal", "/reportes/centros-costo",
  "/reportes/formas-pago", "/reportes/libro-diario", "/ferias/ia", "/simulador",
  "/comunidad", "/cursos", "/seguros",
  "/planes", "/facturacion", "/exportaciones",
]

describe("app-sidebar — las rutas no se rompen", () => {
  const hrefsNuevos = [dashboardItem.href, ...navGroups.flatMap((g) => g.items.map((i) => i.href))]

  it("el menú nuevo expone las 31 rutas (las 30 de siempre más /presupuestos), sin perder ni inventar ninguna", () => {
    expect(hrefsNuevos).toHaveLength(31)
    expect([...hrefsNuevos].sort()).toEqual([...HREFS_DEL_MENU_VIEJO].sort())
  })

  it("ninguna ruta aparece duplicada", () => {
    expect(new Set(hrefsNuevos).size).toBe(hrefsNuevos.length)
  })

  it.each(HREFS_DEL_MENU_VIEJO)("%s tiene su page.tsx en app/(dashboard)", (href) => {
    const pagina = path.resolve(__dirname, "../../app/(dashboard)", href.slice(1), "page.tsx")
    expect(fs.existsSync(pagina)).toBe(true)
  })
})

describe("app-sidebar — cada módulo conserva su ícono y sus gates de plan", () => {
  const MAPA: Array<[string, string, unknown, boolean, boolean]> = [
    // [grupo, título, ícono, pro, proOnly]
    ["Operaciones", "Ventas", ShoppingCart, false, false],
    ["Operaciones", "POS — Venta Rápida", Scan, false, false],
    ["Operaciones", "Presupuestos", FileText, false, false],
    ["Operaciones", "Compras", ShoppingBag, false, false],
    ["Operaciones", "Gastos", Receipt, false, false],
    ["Operaciones", "Caja", Banknote, false, false],
    ["Operaciones", "Banco", Landmark, false, false],
    ["Operaciones", "Cobranzas", HandCoins, false, false],
    ["Catálogo", "Productos", Package, false, false],
    ["Catálogo", "Stock", Warehouse, false, false],
    ["Catálogo", "Clientes", Users, false, false],
    ["Catálogo", "Proveedores", Truck, false, false],
    ["Catálogo", "Sucursales", MapPin, false, true],
    ["Inteligencia", "Copiloto IA", Zap, true, false],
    ["Inteligencia", "Consejos IA", Sparkles, false, false],
    ["Inteligencia", "Feria IA", LayoutGrid, false, false],
    ["Inteligencia", "Simulador", Calculator, false, false],
    ["Estadísticas", "Estadísticas", BarChart3, false, false],
    ["Estadísticas", "Rentabilidad", TrendingUp, true, false],
    ["Estadísticas", "Comparativo", GitCompare, true, false],
    ["Estadísticas", "Por Sucursal", MapPin, false, true],
    ["Estadísticas", "Centros de costo", Tags, false, false],
    ["Estadísticas", "Formas de pago", Wallet, false, false],
    ["Estadísticas", "Libro diario", BookOpen, false, false],
    ["Ecosistema", "Comunidad", MessageSquare, false, false],
    ["Ecosistema", "Cursos", GraduationCap, false, false],
    ["Ecosistema", "Seguros", ShieldCheck, false, false],
    ["Mi Cuenta", "Planes", Crown, false, false],
    ["Mi Cuenta", "Facturación", CreditCard, false, false],
    ["Mi Cuenta", "Exportaciones", FolderDown, false, false],
  ]

  it("el mapa cubre exactamente los 30 módulos de los grupos (el Tablero se testea aparte)", () => {
    const enElMapa = MAPA.map(([grupo, titulo]) => `${grupo} › ${titulo}`)
    const enElMenu = navGroups.flatMap((g) => g.items.map((i) => `${g.label} › ${i.title}`))
    expect(enElMenu).toHaveLength(30)
    expect([...enElMapa].sort()).toEqual([...enElMenu].sort())
  })

  it.each(MAPA)("%s › %s", (grupo, titulo, icono, pro, proOnly) => {
    const entrada = item(grupo, titulo)
    expect(entrada).toBeDefined()
    expect(entrada?.icon).toBe(icono)
    expect(entrada?.pro).toBe(pro)
    expect(entrada?.proOnly).toBe(proOnly)
  })
})

// Adyacencias que fijaban los tests previos, movidas a los grupos nuevos.
describe("app-sidebar — adyacencias que se conservan", () => {
  it("Proveedores va inmediatamente después de Clientes (un proveedor es un maestro, simetría con Clientes)", () => {
    const items = navGroups.find((g) => g.label === "Catálogo")?.items ?? []
    const clientes = items.findIndex((i) => i.title === "Clientes")
    const proveedores = items.findIndex((i) => i.title === "Proveedores")
    expect(clientes).toBeGreaterThanOrEqual(0)
    expect(proveedores).toBe(clientes + 1)
  })

  it("Estadísticas va inmediatamente antes de Rentabilidad (qué se vende, luego qué deja margen)", () => {
    const items = navGroups.find((g) => g.label === "Estadísticas")?.items ?? []
    const estadisticas = items.findIndex((i) => i.title === "Estadísticas")
    const rentabilidad = items.findIndex((i) => i.title === "Rentabilidad")
    expect(estadisticas).toBeGreaterThanOrEqual(0)
    expect(rentabilidad).toBe(estadisticas + 1)
  })

  it("Libro diario va inmediatamente después de Formas de pago", () => {
    const items = navGroups.find((g) => g.label === "Estadísticas")?.items ?? []
    const formas = items.findIndex((i) => i.title === "Formas de pago")
    const libro = items.findIndex((i) => i.title === "Libro diario")
    expect(formas).toBeGreaterThanOrEqual(0)
    expect(libro).toBe(formas + 1)
  })

  it("Presupuestos va entre el POS y Compras (se cotiza antes de vender)", () => {
    const items = navGroups.find((g) => g.label === "Operaciones")?.items ?? []
    const pos = items.findIndex((i) => i.title === "POS — Venta Rápida")
    const presupuestos = items.findIndex((i) => i.title === "Presupuestos")
    const compras = items.findIndex((i) => i.title === "Compras")
    expect(pos).toBeGreaterThanOrEqual(0)
    expect(presupuestos).toBe(pos + 1)
    expect(compras).toBe(presupuestos + 1)
  })

  it("Caja, Banco y Cobranzas conviven en Operaciones (la cobranza es una tarea diaria)", () => {
    const titulos = (navGroups.find((g) => g.label === "Operaciones")?.items ?? []).map((i) => i.title)
    expect(titulos).toEqual(expect.arrayContaining(["Caja", "Banco", "Cobranzas"]))
  })
})
