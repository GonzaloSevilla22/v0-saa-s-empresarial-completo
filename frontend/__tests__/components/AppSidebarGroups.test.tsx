/**
 * AppSidebar — menú lateral por grupos plegables (sidebar-menu-grupos).
 *
 * Monta el `AppSidebar` REAL dentro de un `SidebarProvider` (sólo se mockean las
 * fuentes de datos: auth, límites de plan y el pathname) para fijar el
 * comportamiento que pidió el PO el 2026-09-30:
 *
 *  - cada categoría es un menú CERRADO hasta que lo tocan;
 *  - tocar una categoría la abre y cierra cualquier otra (un solo grupo abierto);
 *  - tocar un módulo navega y el grupo se cierra solo;
 *  - con el menú plegado, el grupo de la pantalla actual se ve marcado;
 *  - con el riel colapsado de escritorio cada grupo abre un desplegable (ninguna
 *    ruta queda inalcanzable porque los sub-ítems los oculta la primitiva);
 *  - el drawer móvil sigue cerrándose con Escape aunque el foco esté en un grupo.
 */
import { describe, it, expect, vi, beforeEach, afterEach } from "vitest"
import { render, screen, within, act } from "@testing-library/react"
import userEvent from "@testing-library/user-event"
import type { Plan } from "@/lib/types"

const h = vi.hoisted(() => ({
  pathname: "/dashboard",
  auth: {
    user: { name: "gonzalo sevilla", role: "user" } as { name: string; role: string },
    logout: async () => {},
    isAdmin: false,
    effectivePlan: "gratis" as Plan,
  },
  hasBranchesModule: false,
}))

vi.mock("next/navigation", () => ({
  usePathname: () => h.pathname,
}))

vi.mock("@/contexts/auth-context", () => ({
  useAuth: () => h.auth,
}))

vi.mock("@/hooks/auth/use-plan-limits", () => ({
  usePlanLimits: () => ({ limits: { hasBranchesModule: h.hasBranchesModule } }),
}))

// next-themes no es parte de lo que se prueba acá.
vi.mock("@/components/mode-toggle", () => ({
  ModeToggle: () => <div data-testid="mode-toggle" />,
}))

import { AppSidebar, getVisibleGroups, navGroups, type NavGroup } from "@/components/app-sidebar"
import { SidebarProvider, SidebarTrigger } from "@/components/ui/sidebar"
import { Package } from "lucide-react"

const GRUPOS = ["Operaciones", "Catálogo", "Inteligencia", "Estadísticas", "Ecosistema", "Mi Cuenta"]
const DRAWER = '[data-sidebar="sidebar"][data-mobile="true"]'

// Los clics sobre un <a> los resuelve next/link; en jsdom, lo que quede sin
// cancelar intenta navegar de verdad y ensucia la salida con "not implemented".
const cancelarNavegacion = (e: Event) => e.preventDefault()

beforeEach(() => {
  h.pathname = "/dashboard"
  h.auth.isAdmin = false
  h.auth.user = { name: "gonzalo sevilla", role: "user" }
  h.auth.effectivePlan = "gratis"
  h.hasBranchesModule = false
  document.addEventListener("click", cancelarNavegacion)
})

afterEach(() => {
  document.removeEventListener("click", cancelarNavegacion)
})

function tree(defaultOpen = true) {
  return (
    <SidebarProvider defaultOpen={defaultOpen}>
      <AppSidebar />
    </SidebarProvider>
  )
}

function renderSidebar(opts: { pathname?: string; defaultOpen?: boolean } = {}) {
  h.pathname = opts.pathname ?? "/dashboard"
  const utils = render(tree(opts.defaultOpen ?? true))
  return {
    ...utils,
    navigateTo(pathname: string) {
      h.pathname = pathname
      utils.rerender(tree(opts.defaultOpen ?? true))
    },
  }
}

const trigger = (label: string) => screen.getByRole("button", { name: label })
const link = (name: string) => screen.getByRole("link", { name })
const queryLink = (name: string) => screen.queryByRole("link", { name })

describe("getVisibleGroups — reglas de visibilidad (puras)", () => {
  it("con el módulo de sucursales ve los 6 grupos completos", () => {
    const visibles = getVisibleGroups(navGroups, { isAdmin: false, hasBranchesModule: true })
    expect(visibles.map((g) => g.label)).toEqual(GRUPOS)
    expect(visibles.flatMap((g) => g.items)).toHaveLength(29)
  })

  it("sin el módulo de sucursales se ocultan Sucursales y Por Sucursal", () => {
    const visibles = getVisibleGroups(navGroups, { isAdmin: false, hasBranchesModule: false })
    const titulos = visibles.flatMap((g) => g.items.map((i) => i.title))
    expect(titulos).not.toContain("Sucursales")
    expect(titulos).not.toContain("Por Sucursal")
    expect(titulos).toHaveLength(27)
  })

  it("el admin no ve Operaciones ni Catálogo, pero sí los otros cuatro", () => {
    const visibles = getVisibleGroups(navGroups, { isAdmin: true, hasBranchesModule: true })
    expect(visibles.map((g) => g.label)).toEqual(["Inteligencia", "Estadísticas", "Ecosistema", "Mi Cuenta"])
  })

  it("un grupo sin ningún ítem visible no se renderiza", () => {
    const soloSucursales: NavGroup = {
      label: "Solo sucursales",
      icon: Package,
      items: [{ title: "Sucursal", href: "/s", icon: Package, pro: false, proOnly: true }],
    }
    const sin = getVisibleGroups([soloSucursales, ...navGroups], { isAdmin: false, hasBranchesModule: false })
    expect(sin.map((g) => g.label)).not.toContain("Solo sucursales")
    const con = getVisibleGroups([soloSucursales, ...navGroups], { isAdmin: false, hasBranchesModule: true })
    expect(con.map((g) => g.label)).toContain("Solo sucursales")
  })
})

describe("AppSidebar — cerrado hasta que lo tocan", () => {
  it("al cargar hay un botón por categoría y TODOS están cerrados", () => {
    renderSidebar()
    for (const label of GRUPOS) {
      expect(trigger(label)).toHaveAttribute("aria-expanded", "false")
    }
  })

  it("con todo cerrado no hay ningún módulo de grupo en el DOM, sólo el Tablero suelto", () => {
    renderSidebar()
    for (const nombre of ["Ventas", "POS — Venta Rápida", "Productos", "Copiloto IA", "Rentabilidad", "Comunidad", "Planes"]) {
      expect(queryLink(nombre)).toBeNull()
    }
    expect(link("Tablero")).toHaveAttribute("href", "/dashboard")
  })

  it("ya no hay rótulo 'Principal'", () => {
    renderSidebar()
    expect(screen.queryByText("Principal")).toBeNull()
  })

  it("el Tablero queda ANTES de todas las categorías y las categorías siguen el orden pedido", () => {
    renderSidebar()
    const orden = [link("Tablero"), ...GRUPOS.map(trigger)]
    for (let i = 1; i < orden.length; i++) {
      // DOCUMENT_POSITION_FOLLOWING: orden[i] viene después de orden[i - 1].
      expect(orden[i - 1].compareDocumentPosition(orden[i]) & Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy()
    }
  })
})

describe("AppSidebar — abrir y cerrar categorías", () => {
  it("tocar Operaciones muestra sus 7 módulos con sus rutas", async () => {
    const user = userEvent.setup()
    renderSidebar()

    await user.click(trigger("Operaciones"))

    expect(trigger("Operaciones")).toHaveAttribute("aria-expanded", "true")
    const esperados: Array<[string, string]> = [
      ["Ventas", "/ventas"],
      ["POS — Venta Rápida", "/ventas/pos"],
      ["Compras", "/compras"],
      ["Gastos", "/gastos"],
      ["Caja", "/caja"],
      ["Banco", "/banco"],
      ["Cobranzas", "/cobranzas"],
    ]
    for (const [nombre, href] of esperados) {
      expect(link(nombre)).toHaveAttribute("href", href)
    }
    // …y no se filtra nada de otra categoría.
    expect(queryLink("Productos")).toBeNull()
  })

  it("tocar Mi Cuenta muestra Planes, Facturación y Exportaciones", async () => {
    const user = userEvent.setup()
    renderSidebar()

    await user.click(trigger("Mi Cuenta"))

    expect(link("Planes")).toHaveAttribute("href", "/planes")
    expect(link("Facturación")).toHaveAttribute("href", "/facturacion")
    expect(link("Exportaciones")).toHaveAttribute("href", "/exportaciones")
  })

  it("tocar de nuevo la categoría abierta la cierra", async () => {
    const user = userEvent.setup()
    renderSidebar()

    await user.click(trigger("Operaciones"))
    expect(link("Ventas")).toBeInTheDocument()
    await user.click(trigger("Operaciones"))

    expect(trigger("Operaciones")).toHaveAttribute("aria-expanded", "false")
    expect(queryLink("Ventas")).toBeNull()
  })

  it("tocar un módulo cierra la categoría sola", async () => {
    const user = userEvent.setup()
    renderSidebar()

    await user.click(trigger("Operaciones"))
    await user.click(link("Ventas"))

    expect(trigger("Operaciones")).toHaveAttribute("aria-expanded", "false")
    expect(queryLink("Ventas")).toBeNull()
  })

  it("lo mismo en otra categoría: tocar Productos cierra Catálogo", async () => {
    const user = userEvent.setup()
    renderSidebar()

    await user.click(trigger("Catálogo"))
    await user.click(link("Productos"))

    expect(trigger("Catálogo")).toHaveAttribute("aria-expanded", "false")
    expect(queryLink("Stock")).toBeNull()
  })

  it("abrir Catálogo con Operaciones abierta cierra Operaciones (un solo grupo abierto)", async () => {
    const user = userEvent.setup()
    renderSidebar()

    await user.click(trigger("Operaciones"))
    await user.click(trigger("Catálogo"))

    expect(trigger("Operaciones")).toHaveAttribute("aria-expanded", "false")
    expect(trigger("Catálogo")).toHaveAttribute("aria-expanded", "true")
    expect(queryLink("Ventas")).toBeNull()
    expect(link("Productos")).toBeInTheDocument()
  })

  it("nunca hay más de un grupo abierto aunque se vayan abriendo todos", async () => {
    const user = userEvent.setup()
    renderSidebar()

    for (const label of GRUPOS) {
      await user.click(trigger(label))
      const abiertos = GRUPOS.filter((g) => trigger(g).getAttribute("aria-expanded") === "true")
      expect(abiertos).toEqual([label])
    }
  })

  it("un cambio de ruta cierra el grupo abierto (breadcrumb, atrás, adelante)", async () => {
    const user = userEvent.setup()
    const { navigateTo } = renderSidebar({ pathname: "/ventas" })

    await user.click(trigger("Operaciones"))
    expect(link("Compras")).toBeInTheDocument()

    await act(async () => {
      navigateTo("/compras")
    })

    expect(trigger("Operaciones")).toHaveAttribute("aria-expanded", "false")
    expect(queryLink("Compras")).toBeNull()
  })

  it("el mismo cierre vale desde otro grupo: Estadísticas se cierra al cambiar de ruta", async () => {
    const user = userEvent.setup()
    const { navigateTo } = renderSidebar({ pathname: "/dashboard" })

    await user.click(trigger("Estadísticas"))
    expect(link("Libro diario")).toBeInTheDocument()

    await act(async () => {
      navigateTo("/estadisticas")
    })

    expect(trigger("Estadísticas")).toHaveAttribute("aria-expanded", "false")
    expect(queryLink("Libro diario")).toBeNull()
  })
})

describe("AppSidebar — el grupo y el módulo activos", () => {
  it("/ventas/pos marca el grupo Operaciones aun cerrado, y ningún otro", () => {
    renderSidebar({ pathname: "/ventas/pos" })

    expect(trigger("Operaciones")).toHaveAttribute("data-active", "true")
    for (const label of GRUPOS.filter((g) => g !== "Operaciones")) {
      expect(trigger(label)).toHaveAttribute("data-active", "false")
    }
    expect(link("Tablero")).toHaveAttribute("data-active", "false")
  })

  it("abierto, /ventas/pos marca POS y NO Ventas (prefijo más largo)", async () => {
    const user = userEvent.setup()
    renderSidebar({ pathname: "/ventas/pos" })

    await user.click(trigger("Operaciones"))

    expect(link("POS — Venta Rápida")).toHaveAttribute("data-active", "true")
    expect(link("POS — Venta Rápida")).toHaveAttribute("aria-current", "page")
    expect(link("Ventas")).toHaveAttribute("data-active", "false")
    expect(link("Ventas")).not.toHaveAttribute("aria-current")
  })

  it("una subruta del detalle marca a su módulo: /estadisticas/productos/abc activa Estadísticas", async () => {
    const user = userEvent.setup()
    renderSidebar({ pathname: "/estadisticas/productos/abc" })

    expect(trigger("Estadísticas")).toHaveAttribute("data-active", "true")
    await user.click(trigger("Estadísticas"))
    expect(link("Estadísticas")).toHaveAttribute("data-active", "true")
    expect(link("Rentabilidad")).toHaveAttribute("data-active", "false")
  })

  it("/dashboard marca el Tablero y ninguna categoría", () => {
    renderSidebar({ pathname: "/dashboard" })

    expect(link("Tablero")).toHaveAttribute("data-active", "true")
    expect(link("Tablero")).toHaveAttribute("aria-current", "page")
    for (const label of GRUPOS) {
      expect(trigger(label)).toHaveAttribute("data-active", "false")
    }
  })

  it("una ruta fuera del menú (/configuracion) no marca nada", () => {
    renderSidebar({ pathname: "/configuracion" })

    expect(link("Tablero")).toHaveAttribute("data-active", "false")
    for (const label of GRUPOS) {
      expect(trigger(label)).toHaveAttribute("data-active", "false")
    }
  })
})

describe("AppSidebar — visibilidad por rol y plan", () => {
  it("el admin no ve Operaciones ni Catálogo y conserva las otras cuatro categorías", () => {
    h.auth.isAdmin = true
    h.auth.user = { name: "admin", role: "admin" }
    renderSidebar()

    expect(screen.queryByRole("button", { name: "Operaciones" })).toBeNull()
    expect(screen.queryByRole("button", { name: "Catálogo" })).toBeNull()
    for (const label of ["Inteligencia", "Estadísticas", "Ecosistema", "Mi Cuenta"]) {
      expect(trigger(label)).toBeInTheDocument()
    }
  })

  it("el admin sigue viendo su grupo Administración, plano y siempre expandido", () => {
    h.auth.isAdmin = true
    h.auth.user = { name: "admin", role: "admin" }
    renderSidebar()

    expect(screen.getByText("Administración")).toBeInTheDocument()
    expect(link("Métricas Globales")).toHaveAttribute("href", "/admin/metricas")
    expect(link("Gestionar Landing")).toHaveAttribute("href", "/admin/landing")
    expect(link("Panel Técnico")).toHaveAttribute("href", "/admin/analytics")
  })

  it("quien no es admin no ve la sección Administración", () => {
    renderSidebar()
    expect(screen.queryByText("Administración")).toBeNull()
    expect(queryLink("Métricas Globales")).toBeNull()
  })

  it("sin módulo de sucursales no aparecen Sucursales ni Por Sucursal", async () => {
    const user = userEvent.setup()
    renderSidebar()

    await user.click(trigger("Catálogo"))
    expect(queryLink("Sucursales")).toBeNull()
    expect(link("Proveedores")).toBeInTheDocument()

    await user.click(trigger("Estadísticas"))
    expect(queryLink("Por Sucursal")).toBeNull()
    expect(link("Centros de costo")).toBeInTheDocument()
  })

  it("con módulo de sucursales aparecen Sucursales y Por Sucursal", async () => {
    h.hasBranchesModule = true
    const user = userEvent.setup()
    renderSidebar()

    await user.click(trigger("Catálogo"))
    expect(link("Sucursales")).toHaveAttribute("href", "/sucursales")

    await user.click(trigger("Estadísticas"))
    expect(link("Por Sucursal")).toHaveAttribute("href", "/reportes/sucursal")
  })

  it("en plan gratis los módulos pro llevan corona y los demás no", async () => {
    const user = userEvent.setup()
    renderSidebar()

    await user.click(trigger("Estadísticas"))
    expect(link("Rentabilidad").querySelector("svg.lucide-crown")).not.toBeNull()
    expect(link("Comparativo").querySelector("svg.lucide-crown")).not.toBeNull()
    expect(link("Estadísticas").querySelector("svg.lucide-crown")).toBeNull()

    await user.click(trigger("Inteligencia"))
    expect(link("Copiloto IA").querySelector("svg.lucide-crown")).not.toBeNull()
    expect(link("Simulador").querySelector("svg.lucide-crown")).toBeNull()
  })

  it("con plan avanzado o superior ningún módulo lleva corona", async () => {
    h.auth.effectivePlan = "avanzado"
    const user = userEvent.setup()
    renderSidebar()

    await user.click(trigger("Estadísticas"))
    expect(link("Rentabilidad").querySelector("svg.lucide-crown")).toBeNull()
    expect(link("Comparativo").querySelector("svg.lucide-crown")).toBeNull()
  })
})

describe("AppSidebar — riel colapsado de escritorio", () => {
  it("cada categoría pasa a ser un disparador de desplegable (aria-haspopup=menu)", () => {
    renderSidebar({ defaultOpen: false })
    for (const label of GRUPOS) {
      expect(trigger(label)).toHaveAttribute("aria-haspopup", "menu")
    }
  })

  it("expandido NO hay disparadores de desplegable (el grupo se pliega en su lugar)", () => {
    renderSidebar({ defaultOpen: true })
    for (const label of GRUPOS) {
      expect(trigger(label)).not.toHaveAttribute("aria-haspopup")
    }
  })

  it("el desplegable de Operaciones ofrece los 7 módulos como enlaces con su ruta", async () => {
    const user = userEvent.setup()
    renderSidebar({ defaultOpen: false })

    await user.click(trigger("Operaciones"))

    const menu = await screen.findByRole("menu")
    const items = within(menu).getAllByRole("menuitem")
    expect(items.map((i) => i.textContent)).toEqual([
      "Ventas",
      "POS — Venta Rápida",
      "Compras",
      "Gastos",
      "Caja",
      "Banco",
      "Cobranzas",
    ])
    expect(items.map((i) => i.getAttribute("href"))).toEqual([
      "/ventas",
      "/ventas/pos",
      "/compras",
      "/gastos",
      "/caja",
      "/banco",
      "/cobranzas",
    ])
    // El desplegable nombra a su categoría.
    expect(within(menu).getByText("Operaciones")).toBeInTheDocument()
  })

  it("ninguna ruta queda inalcanzable: entre los 6 desplegables se llega a los 29 módulos", async () => {
    h.hasBranchesModule = true
    const user = userEvent.setup()
    renderSidebar({ defaultOpen: false })

    const hrefs: string[] = []
    for (const label of GRUPOS) {
      await user.click(trigger(label))
      const menu = await screen.findByRole("menu")
      hrefs.push(...within(menu).getAllByRole("menuitem").map((i) => i.getAttribute("href") ?? ""))
      await user.keyboard("{Escape}")
      await act(async () => {
        await new Promise((r) => setTimeout(r, 30))
      })
    }

    const esperados = navGroups.flatMap((g) => g.items.map((i) => i.href))
    expect(hrefs).toHaveLength(29)
    expect([...hrefs].sort()).toEqual([...esperados].sort())
  })

  it("el desplegable también marca la corona en los módulos pro", async () => {
    const user = userEvent.setup()
    renderSidebar({ defaultOpen: false })

    await user.click(trigger("Estadísticas"))

    const menu = await screen.findByRole("menu")
    expect(within(menu).getByRole("menuitem", { name: "Rentabilidad" }).querySelector("svg.lucide-crown")).not.toBeNull()
    expect(within(menu).getByRole("menuitem", { name: "Libro diario" }).querySelector("svg.lucide-crown")).toBeNull()
  })

  it("con el riel colapsado el grupo de la pantalla actual también se ve marcado", () => {
    renderSidebar({ pathname: "/reportes/formas-pago", defaultOpen: false })
    expect(trigger("Estadísticas")).toHaveAttribute("data-active", "true")
    expect(trigger("Operaciones")).toHaveAttribute("data-active", "false")
  })
})

describe("AppSidebar — drawer móvil", () => {
  beforeEach(() => {
    // useIsMobile() lee window.innerWidth (< 768 = móvil).
    Object.defineProperty(window, "innerWidth", { writable: true, value: 390 })
  })

  afterEach(() => {
    Object.defineProperty(window, "innerWidth", { writable: true, value: 1024 })
  })

  async function abrirDrawer() {
    const user = userEvent.setup()
    render(
      <SidebarProvider>
        <AppSidebar />
        <SidebarTrigger data-testid="trigger-menu" />
      </SidebarProvider>,
    )
    await user.click(screen.getByTestId("trigger-menu"))
    const drawer = document.querySelector(DRAWER)
    expect(drawer).not.toBeNull()
    return { user, drawer: drawer as HTMLElement }
  }

  it("el drawer abre con todas las categorías cerradas y se despliegan como en escritorio", async () => {
    const { user, drawer } = await abrirDrawer()

    for (const label of GRUPOS) {
      expect(within(drawer).getByRole("button", { name: label })).toHaveAttribute("aria-expanded", "false")
    }
    expect(within(drawer).queryByRole("link", { name: "Ventas" })).toBeNull()

    await user.click(within(drawer).getByRole("button", { name: "Operaciones" }))
    expect(within(drawer).getByRole("link", { name: "Ventas" })).toHaveAttribute("href", "/ventas")
    // En móvil los desplegables del riel NO se usan.
    expect(within(drawer).getByRole("button", { name: "Operaciones" })).not.toHaveAttribute("aria-haspopup")
  })

  it("Escape cierra el drawer aunque el foco esté en una categoría (no se rompe G13/H19)", async () => {
    const { user, drawer } = await abrirDrawer()
    const grupo = within(drawer).getByRole("button", { name: "Catálogo" })

    await act(async () => {
      grupo.focus()
    })
    await act(async () => {
      await new Promise((r) => setTimeout(r, 30))
    })
    await user.keyboard("{Escape}")
    await act(async () => {
      await new Promise((r) => setTimeout(r, 60))
    })

    expect(document.querySelector(DRAWER)).toBeNull()
  })

  it("al cerrar el drawer y volver a abrirlo las categorías vuelven a estar cerradas", async () => {
    const { user, drawer } = await abrirDrawer()
    await user.click(within(drawer).getByRole("button", { name: "Operaciones" }))
    expect(within(drawer).getByRole("link", { name: "Compras" })).toBeInTheDocument()

    await user.keyboard("{Escape}")
    await act(async () => {
      await new Promise((r) => setTimeout(r, 60))
    })
    expect(document.querySelector(DRAWER)).toBeNull()

    await user.click(screen.getByTestId("trigger-menu"))
    const reabierto = document.querySelector(DRAWER) as HTMLElement
    expect(reabierto).not.toBeNull()
    expect(within(reabierto).getByRole("button", { name: "Operaciones" })).toHaveAttribute("aria-expanded", "false")
    expect(within(reabierto).queryByRole("link", { name: "Compras" })).toBeNull()
  })
})
