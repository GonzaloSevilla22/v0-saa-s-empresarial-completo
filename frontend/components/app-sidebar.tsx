"use client"

import Link from "next/link"
import { useEffect, useLayoutEffect, useRef, useState, type RefObject } from "react"
import { usePathname } from "next/navigation"
import { useAuth } from "@/contexts/auth-context"
import { planHasAccess, PLAN_DISPLAY_NAMES } from "@/lib/plan-utils"
import { usePlanLimits } from "@/hooks/auth/use-plan-limits"
import { PLAN_LIMITS } from "@/lib/constants"
import {
  LayoutDashboard, ShoppingCart, ShoppingBag, Receipt,
  Package, Warehouse, Users, Sparkles, Calculator,
  MessageSquare, GraduationCap, Settings, LogOut, Zap, Crown,
  ShieldCheck, BarChart3, LayoutGrid, Bot, TrendingUp, GitCompare, MapPin,
  CreditCard, FolderDown, Leaf, Scan, Landmark, ShieldAlert, Tags, Wallet, Banknote, Truck, HandCoins, BookOpen,
  Briefcase, Boxes, Brain, ChartPie, Globe, CircleUser, ChevronRight,
  type LucideIcon,
} from "lucide-react"
import {
  Sidebar, SidebarContent, SidebarFooter, SidebarGroup,
  SidebarGroupContent, SidebarGroupLabel, SidebarHeader,
  SidebarMenu, SidebarMenuButton, SidebarMenuItem,
  SidebarMenuSub, SidebarMenuSubButton, SidebarMenuSubItem,
  SidebarSeparator, useSidebar,
} from "@/components/ui/sidebar"
import { Collapsible, CollapsibleContent, CollapsibleTrigger } from "@/components/ui/collapsible"
import {
  DropdownMenu, DropdownMenuContent, DropdownMenuItem,
  DropdownMenuLabel, DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu"
import { Badge } from "@/components/ui/badge"
import { Avatar, AvatarFallback } from "@/components/ui/avatar"
import { ModeToggle } from "@/components/mode-toggle"
import { getFirstName, capitalizeName } from "@/lib/helpers/user-helpers"

/**
 * Cierre de sesión del botón del riel.
 *
 * auth-hardening-jwt-cookies (D6, task 14.9): el `onClick` lanzaba `logout()`
 * y en la línea siguiente forzaba `window.location.href = "/"`, así que la
 * navegación salía **antes** de que la revocación contra el proveedor y el
 * borrado de cookies terminaran; y `logout()` relanza su error, que sin
 * `.catch()` quedaba como promesa rechazada sin manejar.
 *
 * Extraído del JSX para poder fijar el orden sin montar el árbol completo del
 * Sidebar (que exige `SidebarProvider` y el contexto de auth).
 *
 * @param navigate seam de navegación — jsdom no implementa la navegación real.
 */
export async function handleSidebarLogout(
  logout: () => Promise<void>,
  navigate: (url: string) => void = (url) => {
    window.location.href = url
  },
): Promise<void> {
  try {
    await logout()
  } catch (error) {
    // El cierre visual no puede quedar condicionado a que el proveedor
    // conteste: se registra y se navega igual.
    console.error("[app-sidebar] logout failed (navigating anyway):", error)
  }
  navigate("/")
}

// sidebar-menu-grupos (2026-09-30): la forma del menú se tipa explícita para
// que las funciones puras de abajo (visibilidad, ítem/grupo activo) y los tests
// compartan el mismo contrato que el render.
export interface NavItem {
  title: string
  href: string
  icon: LucideIcon
  /** Se muestra la corona mientras el plan efectivo no llegue a "avanzado". */
  pro: boolean
  /** Sólo se renderiza para cuentas con `hasBranchesModule`. */
  proOnly: boolean
}

export interface NavGroup {
  label: string
  /** Ícono del disparador: es lo único que distingue al grupo con el riel colapsado. */
  icon: LucideIcon
  items: NavItem[]
}

// El Tablero vive suelto arriba del menú, sin categoría ni rótulo "Principal"
// (pedido del PO, 2026-09-30).
export const dashboardItem: NavItem = {
  title: "Tablero",
  href: "/dashboard",
  icon: LayoutDashboard,
  pro: false,
  proOnly: false,
}

// Exportado para testear la posición/href/icono de cada entrada sin montar el
// árbol completo de Sidebar (que requiere SidebarProvider) — ver
// __tests__/components/app-sidebar-nav-groups.test.ts.
export const navGroups: NavGroup[] = [
  {
    label: "Operaciones",
    icon: Briefcase,
    items: [
      { title: "Ventas", href: "/ventas", icon: ShoppingCart, pro: false, proOnly: false },
      { title: "POS — Venta Rápida", href: "/ventas/pos", icon: Scan, pro: false, proOnly: false },
      { title: "Compras", href: "/compras", icon: ShoppingBag, pro: false, proOnly: false },
      { title: "Gastos", href: "/gastos", icon: Receipt, pro: false, proOnly: false },
      // banco-caja-historial-ajustes (D8): Caja pasa a ser un módulo propio
      // (antes solo se llegaba desde el detalle de sucursal, sin entrada de
      // menú). "Bancos" → "Banco" apunta a /banco (tabs Movimientos |
      // Conciliación), ícono Landmark preservado.
      { title: "Caja", href: "/caja", icon: Banknote, pro: false, proOnly: false },
      { title: "Banco", href: "/banco", icon: Landmark, pro: false, proOnly: false },
      // cobranzas-panel (D11): la cobranza es una tarea diaria del negocio
      // (abrir, mirar, llamar, cobrar) — vive junto a Caja y Banco, no en
      // Análisis. Sin gate de plan (D10).
      { title: "Cobranzas", href: "/cobranzas", icon: HandCoins, pro: false, proOnly: false },
    ],
  },
  {
    label: "Catálogo",
    icon: Boxes,
    items: [
      { title: "Productos", href: "/productos", icon: Package, pro: false, proOnly: false },
      { title: "Stock", href: "/stock", icon: Warehouse, pro: false, proOnly: false },
      { title: "Clientes", href: "/clientes", icon: Users, pro: false, proOnly: false },
      // compras-proveedor-cuenta-corriente (D9): un proveedor es un maestro,
      // no una operación — simetría con "Clientes", no cuelga de Operaciones.
      { title: "Proveedores", href: "/proveedores", icon: Truck, pro: false, proOnly: false },
      { title: "Sucursales", href: "/sucursales", icon: MapPin, pro: false, proOnly: true },
    ],
  },
  {
    label: "Inteligencia",
    icon: Brain,
    items: [
      { title: "Copiloto IA", href: "/copiloto-ia", icon: Zap, pro: true, proOnly: false },
      { title: "Consejos IA", href: "/insights", icon: Sparkles, pro: false, proOnly: false },
      { title: "Feria IA", href: "/ferias/ia", icon: LayoutGrid, pro: false, proOnly: false },
      { title: "Simulador", href: "/simulador", icon: Calculator, pro: false, proOnly: false },
    ],
  },
  // sidebar-menu-grupos: categoría nueva. Reúne lo que antes colgaba de
  // Inteligencia y es lectura de datos del negocio (qué se vende, qué deja
  // margen, cómo se reparte), separado de las herramientas de IA.
  {
    label: "Estadísticas",
    icon: ChartPie,
    items: [
      // estadisticas-ventas E1 (task 4.9): "qué se vende y cuándo". Sin gate de
      // plan — disponible en todos los planes; el historial consultable lo
      // recorta el servidor (D8), no un candado de entrada.
      { title: "Estadísticas", href: "/estadisticas", icon: BarChart3, pro: false, proOnly: false },
      { title: "Rentabilidad", href: "/rentabilidad", icon: TrendingUp, pro: true, proOnly: false },
      { title: "Comparativo", href: "/reportes/comparativo", icon: GitCompare, pro: true, proOnly: false },
      { title: "Por Sucursal", href: "/reportes/sucursal", icon: MapPin, pro: false, proOnly: true },
      // cost-center-surface: sin gate de plan — el catálogo está disponible en
      // todos los planes, gatear su único consumidor dejaría al free imputando
      // datos que no puede leer (design.md Decisión 7).
      { title: "Centros de costo", href: "/reportes/centros-costo", icon: Tags, pro: false, proOnly: false },
      // metodos-pago-operaciones (D10): mismo criterio que centros de costo —
      // sin gate de plan, el catálogo está disponible en todos los planes.
      { title: "Formas de pago", href: "/reportes/formas-pago", icon: Wallet, pro: false, proOnly: false },
      // asiento-contable-gastos (D9/D10, task 10.5): mismo criterio que
      // Centros de costo y Formas de pago — es lectura de datos que el
      // propio usuario generó, sin gate de plan. GET /journal-entries existe
      // desde journal-entry-outbox y no tenía consumidor en el frontend.
      // sidebar-menu-grupos: el PO no lo nombró en su lista; vive bajo
      // /reportes/ como los demás de esta categoría, así que va al final.
      { title: "Libro diario", href: "/reportes/libro-diario", icon: BookOpen, pro: false, proOnly: false },
    ],
  },
  {
    label: "Ecosistema",
    icon: Globe,
    items: [
      { title: "Comunidad", href: "/comunidad", icon: MessageSquare, pro: false, proOnly: false },
      { title: "Cursos", href: "/cursos", icon: GraduationCap, pro: false, proOnly: false },
      { title: "Seguros", href: "/seguros", icon: ShieldCheck, pro: false, proOnly: false },
    ],
  },
  {
    label: "Mi Cuenta",
    icon: CircleUser,
    items: [
      { title: "Planes", href: "/planes", icon: Crown, pro: false, proOnly: false },
      { title: "Facturación", href: "/facturacion", icon: CreditCard, pro: false, proOnly: false },
      { title: "Exportaciones", href: "/exportaciones", icon: FolderDown, pro: false, proOnly: false },
    ],
  },
]

/** Categorías operativas que el admin de plataforma no ve (pedido previo, sin cambio). */
const ADMIN_HIDDEN_GROUPS: readonly string[] = ["Operaciones", "Catálogo"]

/**
 * Los grupos (y, dentro de ellos, los módulos) que el usuario actual ve:
 *  - el admin no ve Operaciones ni Catálogo;
 *  - los módulos `proOnly` sólo existen para cuentas con módulo de sucursales;
 *  - un grupo que se queda sin ningún módulo visible no se renderiza.
 */
export function getVisibleGroups(
  groups: readonly NavGroup[],
  { isAdmin, hasBranchesModule }: { isAdmin: boolean; hasBranchesModule: boolean },
): NavGroup[] {
  return groups
    .filter((group) => !(isAdmin && ADMIN_HIDDEN_GROUPS.includes(group.label)))
    .map((group) => ({
      ...group,
      items: group.items.filter((item) => !item.proOnly || hasBranchesModule),
    }))
    .filter((group) => group.items.length > 0)
}

/**
 * El href del menú que corresponde a `pathname`: el coincidente MÁS LARGO.
 *
 * Un ítem coincide si `pathname` es igual a su href o lo tiene como prefijo
 * hasta un separador (`/estadisticas/productos/abc` → `/estadisticas`, pero
 * `/ventas-archivo` NO coincide con `/ventas`). Y si dos ítems coinciden gana
 * el más específico: `/ventas/pos` marca POS y no Ventas. `null` si ninguno
 * coincide (Configuración, Administración, rutas fuera del menú). La barra
 * final no necesita normalizarse: `/ventas/` ya tiene a `/ventas/` como prefijo.
 */
export function getActiveHref(pathname: string, hrefs: readonly string[]): string | null {
  let activo: string | null = null
  for (const href of hrefs) {
    const coincide = pathname === href || pathname.startsWith(`${href}/`)
    if (coincide && (activo === null || href.length > activo.length)) activo = href
  }
  return activo
}

/** `true` sólo para el ganador de {@link getActiveHref} entre `hrefs`. */
export function isItemActive(pathname: string, href: string, hrefs: readonly string[]): boolean {
  return getActiveHref(pathname, hrefs) === href
}

/**
 * Etiqueta del grupo que contiene la pantalla actual, o `null` (Tablero, rutas
 * fuera del menú). Con el menú plegado es lo único que le dice al usuario
 * dónde está, así que el disparador del grupo se marca con esto.
 *
 * Sólo compiten los grupos que recibe (pasar los VISIBLES): un grupo oculto
 * nunca se marca. El Tablero compite por el href pero no pertenece a ningún grupo.
 */
export function findActiveGroupLabel(pathname: string, groups: readonly NavGroup[]): string | null {
  const activo = getActiveHref(pathname, [dashboardItem.href, ...groups.flatMap((g) => g.items.map((i) => i.href))])
  if (activo === null) return null
  return groups.find((group) => group.items.some((item) => item.href === activo))?.label ?? null
}

interface NavGroupMenuProps {
  group: NavGroup
  /** Relevo del foco entre el botón plegable y el del riel (ver {@link useGroupFocusHandoff}). */
  focusHandoff: RefObject<string | null>
  /** El grupo contiene la pantalla actual (se marca aun plegado). */
  groupActive: boolean
  /** Los hrefs visibles: la regla del prefijo más largo compite entre ellos. */
  hrefs: readonly string[]
  pathname: string
  /** Muestra la corona en los módulos `pro` (plan efectivo por debajo de "avanzado"). */
  showProBadge: boolean
}

/**
 * Alto de una fila del menú (Tablero, disparador de categoría y módulo): 44 px
 * de objetivo táctil en el drawer móvil (por debajo de `md`, que es donde
 * existe el drawer) y los 32 px de siempre en escritorio. El riel colapsado lo
 * pisa la primitiva con `!size-8`.
 */
const FILA_MENU = "h-11 md:h-8"

/**
 * Relevo del foco al alternar el riel (Ctrl+B o el botón del menú).
 *
 * Expandido y riel usan componentes distintos para cada categoría (plegable y
 * desplegable), así que alternar el riel DESMONTA el botón de la categoría y
 * monta otro: sin relevo, el foco del teclado caía a <body> (WCAG 2.4.3; con
 * los ítems planos de antes el botón era el mismo en los dos modos).
 *
 * El que se desmonta anota su categoría si el foco estaba dentro de su fila
 * (disparador o un módulo abierto): la limpieza de un efecto de layout corre
 * ANTES de que su DOM salga del documento. El que se monta en el mismo commit
 * la retoma y enfoca su disparador. AppSidebar descarta lo que nadie retomó.
 */
function useGroupFocusHandoff(
  label: string,
  handoff: RefObject<string | null>,
  itemRef: RefObject<HTMLLIElement | null>,
  triggerRef: RefObject<HTMLButtonElement | null>,
) {
  useLayoutEffect(() => {
    if (handoff.current === label) {
      handoff.current = null
      triggerRef.current?.focus()
    }
    const item = itemRef.current
    return () => {
      if (item?.contains(document.activeElement)) handoff.current = label
    }
  }, [label, handoff, itemRef, triggerRef])
}

function ProCrown({ className }: { className?: string }) {
  return <Crown aria-hidden="true" className={className ?? "h-3 w-3 text-yellow-500"} />
}

/**
 * Grupo plegable (riel expandido de escritorio y drawer móvil).
 *
 * El estado abierto vive en AppSidebar (`openGroup`): sólo un grupo a la vez, y
 * cerrado hasta que lo tocan. Tocar un módulo lo cierra (`onNavigate`).
 */
function NavGroupCollapsible({
  group, groupActive, hrefs, pathname, showProBadge, focusHandoff, open, onOpenChange, onNavigate,
}: NavGroupMenuProps & {
  open: boolean
  onOpenChange: (open: boolean) => void
  onNavigate: () => void
}) {
  // Tocar un módulo cierra el grupo y DESMONTA el enlace que tenía el foco: sin
  // devolverlo al disparador, el foco caería a <body> y el usuario de teclado o
  // de lector de pantalla perdería su lugar en el menú (WCAG 2.4.3). Tras un
  // click de mouse `:focus-visible` no se activa, así que no aparece anillo.
  const triggerRef = useRef<HTMLButtonElement>(null)
  const itemRef = useRef<HTMLLIElement>(null)
  useGroupFocusHandoff(group.label, focusHandoff, itemRef, triggerRef)
  const handleNavigate = () => {
    triggerRef.current?.focus()
    onNavigate()
  }

  return (
    <SidebarMenuItem ref={itemRef}>
      <Collapsible open={open} onOpenChange={onOpenChange} className="group/collapsible">
        <CollapsibleTrigger asChild>
          <SidebarMenuButton ref={triggerRef} tooltip={group.label} isActive={groupActive} className={FILA_MENU}>
            <group.icon className="h-4 w-4" />
            <span className="truncate">{group.label}</span>
            <ChevronRight className="ml-auto h-4 w-4 transition-transform duration-200 group-data-[state=open]/collapsible:rotate-90" />
          </SidebarMenuButton>
        </CollapsibleTrigger>
        <CollapsibleContent>
          <SidebarMenuSub>
            {group.items.map((item) => {
              const active = isItemActive(pathname, item.href, hrefs)
              return (
                <SidebarMenuSubItem key={item.href}>
                  {/* FILA_MENU: 32 px en escritorio, como los ítems de primer nivel de
                      siempre (el h-7 de la primitiva los dejaba más chicos), 44 px en móvil. */}
                  <SidebarMenuSubButton asChild isActive={active} className={FILA_MENU}>
                    <Link
                      href={item.href}
                      aria-current={active ? "page" : undefined}
                      onClick={handleNavigate}
                    >
                      <item.icon />
                      <span className="truncate">{item.title}</span>
                      {item.pro && showProBadge && (
                        <span className="ml-auto shrink-0">
                          <ProCrown />
                        </span>
                      )}
                    </Link>
                  </SidebarMenuSubButton>
                </SidebarMenuSubItem>
              )
            })}
          </SidebarMenuSub>
        </CollapsibleContent>
      </Collapsible>
    </SidebarMenuItem>
  )
}

/**
 * Grupo con el riel COLAPSADO de escritorio.
 *
 * `SidebarMenuSub` se oculta con el riel colapsado (`group-data-[collapsible=icon]:hidden`),
 * así que un grupo plegable dejaría sus módulos inalcanzables. En su lugar el
 * disparador (sólo ícono, nombre en el tooltip) abre un desplegable a la
 * derecha con los módulos del grupo como enlaces.
 */
function NavGroupRail({ group, groupActive, hrefs, pathname, showProBadge, focusHandoff }: NavGroupMenuProps) {
  const triggerRef = useRef<HTMLButtonElement>(null)
  const itemRef = useRef<HTMLLIElement>(null)
  useGroupFocusHandoff(group.label, focusHandoff, itemRef, triggerRef)

  // Al elegir un módulo el desplegable devuelve el foco al disparador (bien,
  // WCAG 2.4.3), pero Radix Tooltip abre ante ese foco porque el puntero no se
  // presionó sobre el disparador: el rótulo de la categoría quedaba flotando
  // junto al riel sobre la pantalla nueva (el sidebar no se desmonta entre
  // páginas). La marca hace que ESE foco no abra el tooltip: el `onFocus` del
  // botón corre antes que el del tooltip (Slot) y éste se saltea si el evento
  // viene con `defaultPrevented`. Escape no marca nada: ahí el foco vuelve por
  // teclado y el nombre se anuncia como con Tab.
  const eligioModuloRef = useRef(false)

  return (
    <SidebarMenuItem ref={itemRef}>
      <DropdownMenu>
        <DropdownMenuTrigger asChild>
          <SidebarMenuButton
            ref={triggerRef}
            tooltip={group.label}
            isActive={groupActive}
            onFocus={(event) => {
              if (!eligioModuloRef.current) return
              eligioModuloRef.current = false
              event.preventDefault()
            }}
          >
            <group.icon className="h-4 w-4" />
            <span>{group.label}</span>
          </SidebarMenuButton>
        </DropdownMenuTrigger>
        <DropdownMenuContent side="right" align="start" sideOffset={8} className="min-w-52">
          <DropdownMenuLabel>{group.label}</DropdownMenuLabel>
          {group.items.map((item) => {
            const active = isItemActive(pathname, item.href, hrefs)
            return (
              <DropdownMenuItem
                key={item.href}
                asChild
                onSelect={() => {
                  eligioModuloRef.current = true
                }}
              >
                <Link
                  href={item.href}
                  aria-current={active ? "page" : undefined}
                  className="aria-[current=page]:bg-accent aria-[current=page]:font-medium"
                >
                  <item.icon />
                  <span>{item.title}</span>
                  {item.pro && showProBadge && <ProCrown className="ml-auto text-yellow-500" />}
                </Link>
              </DropdownMenuItem>
            )
          })}
        </DropdownMenuContent>
      </DropdownMenu>
    </SidebarMenuItem>
  )
}

export function AppSidebar() {
  const pathname = usePathname()
  const { user, logout, isAdmin, effectivePlan } = useAuth()
  const { limits } = usePlanLimits()
  // "pro" menu items are gated at avanzado+; show the crown when locked.
  const showProBadge = !planHasAccess(effectivePlan, "avanzado")
  // Mientras la consulta a plan_limits no respondió (`limits` undefined) se usa el
  // valor estático del plan EFECTIVO — ya resuelto: el AuthProvider no monta el
  // layout hasta tener la sesión — en vez de esconder Sucursales / Por Sucursal
  // hasta que llegue la red (tablero-menu-pulido P6). Una cuenta sin el módulo
  // sigue sin verlos nunca: el estático es el mismo seed que el fallback del
  // hook. Cuando llega el valor de la base, ése manda.
  const hasBranchesModule =
    limits?.hasBranchesModule ?? PLAN_LIMITS[effectivePlan]?.hasBranchesModule ?? false
  const { isMobile, openMobile, setOpenMobile, state } = useSidebar()
  // Riel colapsado de escritorio: los sub-ítems no se ven, cada grupo abre un desplegable.
  const isRail = state === "collapsed" && !isMobile

  // Un solo grupo abierto a la vez; `null` = todos cerrados (estado inicial:
  // el menú está cerrado hasta que lo tocan).
  const [openGroup, setOpenGroup] = useState<string | null>(null)

  // Relevo del foco al alternar el riel (useGroupFocusHandoff). Los efectos de
  // layout de los hijos corren antes que éste: lo que ningún grupo retomó en
  // este commit se descarta, así una anotación nunca sobrevive a su commit.
  const focusHandoffRef = useRef<string | null>(null)
  useLayoutEffect(() => {
    focusHandoffRef.current = null
  })

  const visibleGroups = getVisibleGroups(navGroups, { isAdmin, hasBranchesModule })
  const visibleHrefs = [dashboardItem.href, ...visibleGroups.flatMap((group) => group.items.map((item) => item.href))]
  const activeGroupLabel = findActiveGroupLabel(pathname, visibleGroups)
  const tableroActive = isItemActive(pathname, dashboardItem.href, visibleHrefs)

  // Close the mobile drawer whenever the user navigates to a new route
  useEffect(() => {
    if (isMobile) {
      setOpenMobile(false)
    }
  }, [pathname, isMobile, setOpenMobile])

  // Invariante "cerrado salvo que lo toquen": cualquier navegación (módulo
  // tocado, breadcrumb, atrás/adelante) deja el menú plegado…
  useEffect(() => {
    setOpenGroup(null)
  }, [pathname])

  // …y también cuando el menú deja de verse: drawer móvil cerrado o riel
  // colapsado (ahí los grupos son desplegables, no hay nada "abierto").
  const menuHidden = isRail || (isMobile && !openMobile)
  useEffect(() => {
    if (menuHidden) setOpenGroup(null)
  }, [menuHidden])

  return (
    <Sidebar collapsible="icon" className="border-r border-sidebar-border">
      <SidebarHeader className="p-4">
        <Link href="/dashboard" className="flex items-center gap-2">
          <div className="flex h-10 w-10 shrink-0 items-center justify-center rounded-lg overflow-hidden">
            <img src="/aliadata-logo.png" alt="Logo" className="h-full w-full object-contain" />
          </div>
          <div className="flex flex-col group-data-[collapsible=icon]:hidden">
            <span className="text-sm font-bold text-sidebar-foreground">ALIADATA</span>
            <span className="text-[10px] text-sidebar-foreground/60">Emprender es Inteligente</span>
          </div>
        </Link>
      </SidebarHeader>

      <SidebarSeparator />

      <SidebarContent>
        <SidebarGroup>
          <SidebarGroupContent>
            <SidebarMenu>
              <SidebarMenuItem>
                <SidebarMenuButton asChild isActive={tableroActive} tooltip={dashboardItem.title} className={FILA_MENU}>
                  <Link href={dashboardItem.href} aria-current={tableroActive ? "page" : undefined}>
                    <dashboardItem.icon className="h-4 w-4" />
                    <span>{dashboardItem.title}</span>
                  </Link>
                </SidebarMenuButton>
              </SidebarMenuItem>

              {visibleGroups.map((group) =>
                isRail ? (
                  <NavGroupRail
                    key={group.label}
                    group={group}
                    groupActive={activeGroupLabel === group.label}
                    hrefs={visibleHrefs}
                    pathname={pathname}
                    showProBadge={showProBadge}
                    focusHandoff={focusHandoffRef}
                  />
                ) : (
                  <NavGroupCollapsible
                    key={group.label}
                    group={group}
                    groupActive={activeGroupLabel === group.label}
                    hrefs={visibleHrefs}
                    pathname={pathname}
                    showProBadge={showProBadge}
                    focusHandoff={focusHandoffRef}
                    open={openGroup === group.label}
                    onOpenChange={(open) => setOpenGroup(open ? group.label : null)}
                    onNavigate={() => setOpenGroup(null)}
                  />
                ),
              )}
            </SidebarMenu>
          </SidebarGroupContent>
        </SidebarGroup>

        {isAdmin && (
          <SidebarGroup>
            <SidebarGroupLabel className="text-emerald-500 uppercase text-[10px] tracking-wider font-bold">
              Administración
            </SidebarGroupLabel>
            <SidebarGroupContent>
              <SidebarMenu>
                <SidebarMenuItem>
                  <SidebarMenuButton
                    asChild
                    isActive={pathname === "/admin/metricas"}
                    tooltip="Métricas Estratégicas"
                    className="text-emerald-500 hover:text-emerald-400 hover:bg-emerald-500/10"
                  >
                    <Link href="/admin/metricas">
                      <BarChart3 className="h-4 w-4" />
                      <span>Métricas Globales</span>
                    </Link>
                  </SidebarMenuButton>
                </SidebarMenuItem>

                <div className="px-4 py-2 grid grid-cols-2 gap-x-4 gap-y-1 border-l border-emerald-500/20 ml-4 mt-1">
                  <Link href="/admin/metricas/ventas" className="text-[11px] text-slate-400 hover:text-emerald-400 transition-colors">Ventas</Link>
                  <Link href="/admin/metricas/compras" className="text-[11px] text-slate-400 hover:text-emerald-400 transition-colors">Compras</Link>
                  <Link href="/admin/metricas/gastos" className="text-[11px] text-slate-400 hover:text-emerald-400 transition-colors">Gastos</Link>
                  <Link href="/admin/metricas/stock" className="text-[11px] text-slate-400 hover:text-emerald-400 transition-colors">Stock</Link>
                  <Link href="/admin/metricas/clientes" className="text-[11px] text-slate-400 hover:text-emerald-400 transition-colors">Clientes</Link>
                  <Link href="/admin/metricas/ai" className="text-[11px] text-slate-400 hover:text-emerald-400 transition-colors">Consejo IA</Link>
                  <Link href="/admin/metricas/simulador" className="text-[11px] text-slate-400 hover:text-emerald-400 transition-colors">Simulador</Link>
                  <Link href="/admin/metricas/comunidad" className="text-[11px] text-slate-400 hover:text-emerald-400 transition-colors">Comunidad</Link>
                  <Link href="/admin/metricas/cursos" className="text-[11px] text-slate-400 hover:text-emerald-400 transition-colors">Cursos</Link>
                </div>

                <SidebarMenuItem>
                  <SidebarMenuButton
                    asChild
                    isActive={pathname === "/admin/landing"}
                    tooltip="Gestionar Landing Page"
                  >
                    <Link href="/admin/landing">
                      <LayoutGrid className="h-4 w-4" />
                      <span>Gestionar Landing</span>
                    </Link>
                  </SidebarMenuButton>
                </SidebarMenuItem>

                <SidebarMenuItem>
                  <SidebarMenuButton
                    asChild
                    isActive={pathname === "/admin/pagos"}
                    tooltip="Recibos de Pago"
                    className="text-emerald-500 hover:text-emerald-400 hover:bg-emerald-500/10"
                  >
                    <Link href="/admin/pagos">
                      <Receipt className="h-4 w-4" />
                      <span>Recibos de Pago</span>
                    </Link>
                  </SidebarMenuButton>
                </SidebarMenuItem>

                <SidebarMenuItem>
                  <SidebarMenuButton
                    asChild
                    isActive={pathname === "/admin/pagos/ambiguas"}
                    tooltip="Suscripciones Ambiguas"
                    className="text-emerald-500 hover:text-emerald-400 hover:bg-emerald-500/10"
                  >
                    <Link href="/admin/pagos/ambiguas">
                      <ShieldAlert className="h-4 w-4" />
                      <span>Suscripciones Ambiguas</span>
                    </Link>
                  </SidebarMenuButton>
                </SidebarMenuItem>

                <SidebarMenuItem>
                  <SidebarMenuButton
                    asChild
                    isActive={pathname === "/admin/cursos"}
                    tooltip="Gestionar Cursos"
                    className="text-emerald-500 hover:text-emerald-400 hover:bg-emerald-500/10"
                  >
                    <Link href="/admin/cursos">
                      <GraduationCap className="h-4 w-4" />
                      <span>Gestionar Cursos</span>
                    </Link>
                  </SidebarMenuButton>
                </SidebarMenuItem>

                <SidebarMenuItem>
                  <SidebarMenuButton
                    asChild
                    isActive={pathname === "/admin/seguros"}
                    tooltip="Gestionar Seguros"
                    className="text-emerald-500 hover:text-emerald-400 hover:bg-emerald-500/10"
                  >
                    <Link href="/admin/seguros">
                      <ShieldCheck className="h-4 w-4" />
                      <span>Gestionar Seguros</span>
                    </Link>
                  </SidebarMenuButton>
                </SidebarMenuItem>

                <SidebarMenuItem>
                  <SidebarMenuButton
                    asChild
                    isActive={pathname === "/admin/feria-ia"}
                    tooltip="Gestionar Feria IA"
                    className="text-emerald-500 hover:text-emerald-400 hover:bg-emerald-500/10"
                  >
                    <Link href="/admin/feria-ia">
                      <Sparkles className="h-4 w-4" />
                      <span>Gestionar Feria IA</span>
                    </Link>
                  </SidebarMenuButton>
                </SidebarMenuItem>

                <SidebarMenuItem>
                  <SidebarMenuButton
                    asChild
                    isActive={pathname === "/admin/copilot-ia"}
                    tooltip="Gestionar Copilot IA"
                    className="text-emerald-500 hover:text-emerald-400 hover:bg-emerald-500/10"
                  >
                    <Link href="/admin/copilot-ia">
                      <Bot className="h-4 w-4" />
                      <span>Gestionar Copilot IA</span>
                    </Link>
                  </SidebarMenuButton>
                </SidebarMenuItem>

                <SidebarMenuItem>
                  <SidebarMenuButton
                    asChild
                    isActive={pathname === "/admin/analytics"}
                    tooltip="Analiticas Técnicas"
                  >
                    <Link href="/admin/analytics">
                      <ShieldCheck className="h-4 w-4" />
                      <span>Panel Técnico</span>
                    </Link>
                  </SidebarMenuButton>
                </SidebarMenuItem>
              </SidebarMenu>
            </SidebarGroupContent>
          </SidebarGroup>
        )}
      </SidebarContent>

      <SidebarSeparator />

      <SidebarFooter className="p-2">
        <SidebarMenu>
          <SidebarMenuItem>
            <SidebarMenuButton asChild tooltip="Configuración">
              <Link href="/configuracion">
                <Settings className="h-4 w-4" />
                <span>Configuración</span>
              </Link>
            </SidebarMenuButton>
          </SidebarMenuItem>
          <SidebarMenuItem>
            <SidebarMenuButton
              onClick={() => {
                void handleSidebarLogout(logout)
              }}
              tooltip="Cerrar sesion"
              data-testid="logout-button"
            >
              <LogOut className="h-4 w-4" />
              <span>Cerrar sesión</span>
            </SidebarMenuButton>
          </SidebarMenuItem>
          <SidebarMenuItem>
            <div className="px-2 py-1 flex items-center justify-between group-data-[collapsible=icon]:justify-center">
              <span className="text-xs text-sidebar-foreground/60 group-data-[collapsible=icon]:hidden">Interfaz</span>
              <ModeToggle />
            </div>
          </SidebarMenuItem>
        </SidebarMenu>
        <SidebarSeparator />
        <div className="flex items-center gap-3 p-2 group-data-[collapsible=icon]:justify-center">
          <Avatar className="h-8 w-8 shrink-0">
            <AvatarFallback className="bg-primary/20 text-primary text-xs">
              {getFirstName(user?.name, "U").charAt(0).toUpperCase()}
            </AvatarFallback>
          </Avatar>
          <div className="flex flex-col group-data-[collapsible=icon]:hidden">
            <span className="text-xs font-medium text-sidebar-foreground truncate max-w-[120px]">
              {capitalizeName(user?.name ?? "") || "Usuario"}
            </span>
            <Badge
              variant="outline"
              className={`w-fit gap-1 text-[10px] px-1.5 py-0 ${user?.role === "admin"
                ? "border-emerald-500/50 text-emerald-500"
                : effectivePlan === "gratis"
                  ? "border-sidebar-border text-sidebar-foreground/60"
                  : "border-primary/50 text-primary"
                }`}
            >
              {user?.role === "admin" ? (
                "Administrador"
              ) : (
                <>
                  {effectivePlan === "gratis"
                    ? <Leaf className="h-3 w-3" />
                    : <Crown className="h-3 w-3" />}
                  {PLAN_DISPLAY_NAMES[effectivePlan]}
                </>
              )}
            </Badge>
          </div>
        </div>
      </SidebarFooter>
    </Sidebar>
  )
}
