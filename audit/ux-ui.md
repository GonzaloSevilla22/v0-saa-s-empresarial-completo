# Auditoría UX/UI — ALIADATA (EmprendeSmart / EIE)

**Dimensión:** UX Engineer / Design Systems Reviewer
**Alcance:** `frontend/app/`, `frontend/components/`, `frontend/styles/`, `frontend/tailwind.config.ts` (solo lectura)
**Método:** revisión de código estática (sin browser). Conteos verificados con grep/ripgrep sobre el árbol real.
**Clasificación del área:** **Mejorable** (base sólida de shadcn/ui bien montada, pero con deuda de consistencia transversal y accesibilidad que impacta a usuarios reales en producción).

---

## Resumen ejecutivo

El frontend está construido sobre shadcn/ui + Tailwind con tokens HSL en CSS variables y una capa de componentes `ui/` correcta. El flujo core (POS venta rápida) está notablemente bien resuelto: mobile-first (`max-w-2xl`), errores traducidos a castellano legible, idempotencia por tab, guardas de sesión de caja, estados de éxito/warning con affordances claras. La base de datos de conocimiento y las convenciones existen.

Sin embargo, la ejecución del design system es **inconsistente a escala**, y hay tres brechas que tocan a usuarios reales hoy:

1. **Accesibilidad de botones-ícono:** 59 botones `size="icon"` en el árbol de app/components y solo 2 tienen `aria-label`; 3 `sr-only` en total. Las acciones de editar/eliminar de tablas, el toggle de contraseña del login y la campana de notificaciones se anuncian como "button" sin nombre accesible (WCAG 4.1.2).
2. **Design tokens saltados masivamente:** 883 clases de color de escala Tailwind hardcodeadas (`emerald-*`, `green-*`, `slate-*`, `amber-*`, `red-*`, …) fuera de `ui/`, más 43 hex literales. Los tokens `--success`/`--warning` definidos en `globals.css` casi no se usan; el "verde de marca" se replica a mano por todos lados. Esto rompe theming, dark mode fino y consistencia.
3. **RHF + Zod prácticamente ausente:** cero archivos llaman `useForm(`, y el wrapper `@/components/ui/form` se importa una sola vez. Las 5 formas núcleo de captura de datos (venta, compra, gasto, producto, cliente) validan con `useState` + `toast.error`, sin validación inline, sin `aria-invalid`, sin mensajes por campo. Esto contradice el stack declarado (RHF+Zod) y degrada la UX de corrección de errores.

Nada de esto es CRÍTICO en el sentido de plata/datos (el hot path transaccional vive en RPCs y está bien guardado en el POS), pero sí es deuda de calidad de producto pre-producción con impacto probable en usabilidad y accesibilidad.

---

## Fortalezas (reconocidas con seriedad)

- **Flujo POS (`app/(dashboard)/ventas/pos/page.tsx`) ejemplar:** `friendlyError()` traduce códigos de backend a castellano accionable (stock insuficiente, caja cerrada, sin permiso, punto de venta ambiguo); idempotency-key por tab estable ante F5; estados de éxito, warning de caja y chip de sesión bien diferenciados; layout mobile-first `max-w-2xl mx-auto`; botón submit con label dinámico ("Cobrar — $X"). Es el estándar que el resto de la app debería seguir.
- **Componente `data-table` compartido (`components/data-table/data-table.tsx`)** con estado vacío ("No se encontraron resultados"), ordenamiento, paginación y **AlertDialog** para eliminación destructiva. Cuando se usa, la UX es consistente.
- **Estados vacíos presentes** en las tablas crudas revisadas (rentabilidad, reportes/sucursal "Sin datos para el período seleccionado", CashMovementsList "Sin movimientos registrados en esta sesión"). No se detectaron tablas sin empty state.
- **Sin texto de UI en inglés residual** en botones/labels visibles (búsqueda de `>Save<`, `>Cancel<`, `>Loading<`, etc. dio 0). La localización es-AR está bien mantenida a nivel de copy.
- **Helper de formato es-AR sólido** (`lib/format.ts`): `formatMoney` con `Intl.NumberFormat` por moneda, `formatNumber`, `formatDate` con timezone-safe `T12:00:00`. La infraestructura correcta existe.
- **Login accesible en lo básico** (`app/auth/login/page.tsx`): `Label htmlFor`, `required`, `role="alert"` en mensaje de idle logout, toggle de contraseña.
- **Sidebar responsive** con cierre automático del drawer móvil al navegar (`useEffect` sobre `pathname`), tooltips en modo colapsado, y persistencia de estado vía cookie server-side (evita flash colapsado→expandido).
- **Gating de planes en la navegación** integrado (badges Pro/Crown, `proOnly` por módulo de sucursales).

---

## Debilidades / Hallazgos detallados

### H1 — Botones-ícono sin nombre accesible (ALTA)
**Evidencia:** `grep 'size="icon"'` fuera de `ui/` = **59 ocurrencias**; con `aria-label` (misma línea o ±2 líneas) = **2**; `sr-only` total = **3**.
Ejemplos concretos:
- `components/data-table/data-table.tsx:419-438` — botones editar (Pencil) y eliminar (Trash2) de **todas** las tablas de la app, sin `aria-label`.
- `components/products/product-catalog.tsx:70-72, 459-462, 517-520, 589-592` — editar/eliminar producto y variantes.
- `app/auth/login/page.tsx:111` — toggle mostrar/ocultar contraseña (Eye/EyeOff) sin `aria-label` en la pantalla de entrada.
- `components/dashboard/NotificationBell.tsx` (campana) y `SidebarTrigger`.

**Impacto:** un lector de pantalla anuncia "botón" sin propósito. Falla WCAG 2.1 SC 4.1.2 (Name, Role, Value). El público objetivo (microemprendedores, muchos con lectores de pantalla o navegación por teclado en móvil) queda sin poder identificar acciones destructivas.
**Recomendación:** añadir `aria-label` (o `<span className="sr-only">`) a cada botón-ícono. Idealmente centralizar en el `data-table` y en un wrapper `IconButton`.

### H2 — Design tokens saltados: 883 clases de color hardcodeadas + 43 hex (ALTA)
**Evidencia:** `grep -E '(bg|text|border|ring)-(emerald|slate|gray|zinc|amber|red|green|blue|yellow)-[0-9]'` fuera de `ui/` = **883**. Hex literales (`#...`) = **43**.
Ejemplos:
- `components/dashboard/KpiSummaryCard.tsx:30-32` — `text-[#34D399]`, `text-[#F87171]`, `text-[#FBBF24]` en vez de tokens success/destructive/warning.
- `app/(dashboard)/admin/metricas/*` — spinner `border-2 border-emerald-500` repetido literal en ~12 páginas.
- `components/app-sidebar.tsx:161,171,181-189,338` — `text-emerald-500`, `text-slate-400` hardcodeados en la sección admin.
- `components/forms/client-form.tsx:132-158`, `components/ventas/sale-receipt-button.tsx:234` — verde WhatsApp `#25D366` literal.

**Impacto:** los tokens `--success`/`--warning` existen en `app/globals.css:41-44,75-78` pero casi no se consumen; el "verde de marca" (`142 71% 45%`) se re-hardcodea como `emerald-500`/`green-500`. Rompe theming coherente, complica dark mode y hace el rebranding costoso. Es la inconsistencia dominante del design system.
**Recomendación:** mapear `success`/`warning` en `tailwind.config.ts` (hoy no están), migrar `emerald-*`/`green-*` a `text-success`/`bg-primary`, y prohibir hex literales con un lint (`eslint-plugin-tailwindcss` o regla propia).

### H3 — RHF + Zod ausente en formularios núcleo; validación por toast sin inline errors (ALTA)
**Evidencia:** `useForm(` = **0 ocurrencias**; import de `@/components/ui/form` = **1**. Las formas `components/forms/{sale,purchase,expense,product,client}-form.tsx` usan `useState` + `toast.error` (sale=9, purchase=7, product/client=varias llamadas). Ej.: `product-form.tsx:87-90` valida `if (!name || !category) { toast.error("Completá nombre y categoría"); return }`.
**Impacto:** contradice el stack declarado (RHF + Zod). Sin validación por campo, sin `aria-invalid`, sin mensajes inline: el usuario recibe un toast global genérico y debe adivinar qué campo corregir. En formas financieras (venta/compra/gasto) esto aumenta el error de captura.
**Recomendación:** migrar las 5 formas núcleo a RHF + `zodResolver`, usando el `Form`/`FormField`/`FormMessage` de shadcn (ya instalado). Prioridad: sale-form y purchase-form (impacto en datos financieros).

### H4 — Dos `globals.css` divergentes; el neutral está huérfano y desincroniza el design system (MEDIA)
**Evidencia:**
- `app/globals.css` (importado por `app/layout.tsx:10`): `--primary: 142 71% 45%` (verde), `--radius: 0.75rem`, define `--success`/`--warning`.
- `styles/globals.css`: `--primary: 0 0% 9%` (negro/neutral), `--radius: 0.5rem`, sin success/warning. **No está referenciado en ningún archivo** (`grep styles/globals` = 0).
- `components.json:9` declara `"baseColor": "neutral"` y `tailwind.config.ts` (raíz) NO define `success`/`warning`, mientras que el CSS efectivo sí.

**Impacto:** archivo muerto que confunde a cualquiera que edite tokens; `tailwind.config.ts` y `components.json` describen un sistema (neutral, radius 0.5) distinto al que corre (verde, radius 0.75). Alto riesgo de que un `npx shadcn add` regenere con la base equivocada.
**Recomendación:** borrar `styles/globals.css`, alinear `components.json`/`tailwind.config.ts` con el tema verde real, y registrar `success`/`warning` en el config de Tailwind.

### H5 — "Breadcrumb" no es breadcrumb y su mapa de rutas está incompleto (MEDIA)
**Evidencia:** `components/dashboard/breadcrumb-nav.tsx:14-38` — `PAGE_NAMES` mapea ~19 rutas; el sidebar navega a ~35 (`compras`, `ventas/pos`, `finanzas/conciliacion`, `rentabilidad`, `reportes/comparativo`, `reportes/sucursal`, `facturacion`, `exportaciones`, `planes`, `sucursales`, detalles `/[id]`, etc. no están). Fallback: `?? "ALIADATA"`. Además renderiza un único `BreadcrumbPage`, no una jerarquía.
**Impacto:** en muchas rutas el encabezado dice "ALIADATA" en vez del nombre de la sección; el usuario pierde orientación (IA de información). No hay migas reales para rutas anidadas (`/sucursales/[id]/caja`).
**Recomendación:** derivar el título del `navGroups` del sidebar (fuente única) o del segmento de ruta, y construir migas jerárquicas para rutas anidadas.

### H6 — Estados de carga inconsistentes: dos spinners + sin `loading.tsx` de ruta (MEDIA)
**Evidencia:** `Loader2` en 44 archivos; spinner artesanal `border-2 border-emerald-500 ... animate-spin` en ~12 páginas admin (`app/(dashboard)/admin/**`); `animate-spin` total = 82; `Skeleton` solo en 7 archivos; `find app -name loading.tsx` = **0**.
**Impacto:** dos idiomas visuales de carga distintos (ícono Lucide vs. div con borde verde hardcodeado) y ausencia total de Suspense boundaries a nivel de ruta → transiciones sin skeleton, percepción de lentitud (agravado por cold start de Render ~50s, K10).
**Recomendación:** un único `<Spinner>` tokenizado, adoptar `Skeleton` en listados clave, y añadir `loading.tsx` en las rutas de datos pesados.

### H7 — Confirmaciones destructivas con `window.confirm()` nativo (7 casos, incluye datos financieros) (MEDIA)
**Evidencia:** `confirm(` fuera de AlertDialog = **7**:
- `components/ventas/sale-operations-list.tsx:158` — eliminar **venta**.
- `components/compras/purchase-operations-list.tsx:96` — eliminar **compra**.
- `components/branches/BranchList.tsx:30,41` — desactivar / cerrar **sucursal**.
- `components/settings/AccountForm.tsx:89` — cerrar sesión en todos los dispositivos.
- `app/(dashboard)/admin/copilot-ia/page.tsx:110`, `app/(dashboard)/comunidad/page.tsx:54`.
Conviven con 6 archivos que sí usan `AlertDialog`.
**Impacto:** inconsistencia visual (diálogo del navegador, no estilizable, no accesible con el theme), y confirmación de acciones sobre datos financieros con un modal nativo que rompe la identidad de producto. En móvil el `confirm()` nativo es especialmente pobre.
**Recomendación:** reemplazar los 7 por `AlertDialog` (patrón ya presente en `data-table`).

### H8 — Formato de moneda inconsistente (helper vs. crudo) (MEDIA)
**Evidencia:** `formatMoney/formatCurrency` = 43 usos; `toLocaleString(` = 47; interpolaciones crudas `${...}` con total/price/monto = 43. Ej.: en el mismo POS conviven `formatMoney(cartTotal, "ARS")` (línea 501) y `$${Number(result.total).toLocaleString("es-AR")}` (línea 375).
**Impacto:** algunos importes muestran símbolo `$` crudo, otros el formato `Intl` es-AR completo, con decimales y separadores distintos. Inconsistencia percibida en una app financiera donde la moneda es central.
**Recomendación:** enrutar todo importe por `formatMoney`; regla de lint que marque `toLocaleString` sobre montos.

### H9 — Uso de `any` en frontend contra regla dura del proyecto (BAJA-MEDIA)
**Evidencia:** `:\s*any|<any>|as any` en app+components (fuera de `ui/`) = **108**. Ej.: `app/auth/login/page.tsx:38` `catch (error: any)`.
**Impacto:** el CLAUDE.md prohíbe `any` explícitamente ("NUNCA usar `any`"). No es un defecto de UX per se, pero degrada la seguridad de tipos en handlers de UI (props de eventos, errores) y facilita bugs de render.
**Recomendación:** `error: unknown` + narrowing (patrón ya usado en `BranchList.tsx:33`), y `unknown`/tipos explícitos en el resto.

### H10 — Selector de sucursal ausente en POS multi-sucursal (BAJA)
**Evidencia:** `app/(dashboard)/ventas/pos/page.tsx:103` `const activeBranch = branches[0] ?? null`. Siempre toma la primera sucursal; no hay UI para elegir cuál cuando la cuenta tiene varias (módulo de sucursales es un feature de plan).
**Impacto:** un usuario con 2+ sucursales cobra siempre contra la primera sin saberlo (afecta caja y stock por sucursal). Es más funcional que estético, pero es una brecha de UX de un flujo core.
**Recomendación:** agregar `SearchableSelect` de sucursal cuando `branches.length > 1`.

### H11 — Bug menor de `colSpan` en empty state del data-table (BAJA)
**Evidencia:** `components/data-table/data-table.tsx:401` `colSpan={columns.length + (onDelete ? 1 : 0)}` — ignora `onEdit`. Cuando hay `onEdit` pero no `onDelete`, la celda de "No se encontraron resultados" abarca una columna menos que el header (que sí reserva col para `onEdit || onDelete`, línea 394).
**Impacto:** desalineación visual leve del estado vacío en tablas solo-editables.
**Recomendación:** `colSpan={columns.length + ((onDelete || onEdit) ? 1 : 0)}`.

---

## Verificación de issues conocidos (área UX/UI)

- **K7 (products.min_stock DEPRECATED):** parcialmente visible en UI — `components/forms/product-form.tsx:36` sigue exponiendo `minStock` (default 10) en el formulario de producto; el mínimo real vive per-branch (`branch_stock.min_stock`). El form no comunica que el mínimo es por sucursal → inconsistencia doc/UX. Estado: **CONFIRMADO** (a nivel de UI).
- **K11 (enum units_of_measure.type ≠ canónico V3):** `product-form.tsx:73-79` mapea `typeLabels` con exactamente `unit|weight|volume|length|custom` (el enum real de prod), NO el canónico V3 (`peso|volumen|contable`). La UI está atada al enum legacy; el rename sería BREAKING también en el frontend. Estado: **CONFIRMADO**.
- **K9 (RBAC singular):** el sidebar solo distingue `isAdmin` vs. usuario (`components/app-sidebar.tsx:85,118,159`); no hay diferenciación de roles funcionales (SELLER/CASHIER) en la navegación, coherente con RBAC singular pendiente. Estado: **CONFIRMADO** (consistente con K9; no es defecto nuevo).
- **K19 (dos proyectos Supabase):** fuera de alcance UI directo; `NO_EVALUADO` desde el frontend.

Los demás known issues (K1-K6, K8, K10, K12-K18, K20) son de backend/DB/infra y no corresponden a esta dimensión: `NO_EVALUADO`.

---

## Inconsistencias documentación ↔ código (UX)

1. Stack declara **React Hook Form + Zod** para formularios; el código real no usa `useForm` en ninguna forma núcleo (H3).
2. `components.json` (`baseColor: neutral`) y `tailwind.config.ts` (sin success/warning) describen un design system distinto al `app/globals.css` efectivo (verde + success/warning) (H4).
3. `CLAUDE.md` prohíbe `any`; hay 108 usos en app/components (H9).

---

## Deuda técnica UX priorizada

1. Migrar 5 formas núcleo a RHF+Zod con errores inline y `aria-invalid` (H3).
2. Tokenizar color: erradicar 883 clases hardcodeadas + 43 hex; registrar success/warning en Tailwind (H2, H4).
3. Accesibilidad: aria-label en 59 botones-ícono; auditar foco/teclado (H1).
4. Unificar spinner + adoptar Skeleton + `loading.tsx` por ruta (H6).
5. Reemplazar 7 `confirm()` nativos por AlertDialog (H7).
6. Enrutar toda moneda por `formatMoney` (H8).
7. Completar/rehacer el breadcrumb como fuente única (H5).
8. Borrar `styles/globals.css` huérfano (H4).

---

## Justificación de la clasificación: **Mejorable**

Hay una base real y buena (shadcn/ui montado con criterio, POS ejemplar, empty states presentes, es-AR consistente en copy, helper de formato correcto), lo que descarta "Crítica". Pero tres brechas transversales de alto conteo y con impacto en usuarios reales —accesibilidad de botones-ícono (59/2), tokens de color saltados (883+43), y ausencia total de RHF+Zod en formularios financieros— más deuda media (dos globals.css, breadcrumb incompleto, dos spinners, 7 confirm nativos, moneda inconsistente) impiden calificarla como "Buena". Para un MVP en producción con ~29 cuentas reales apuntando a junio 2026, el área es **Mejorable**: sólida en esqueleto, inconsistente en ejecución.
