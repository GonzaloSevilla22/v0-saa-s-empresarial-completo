# Informe de QA — ALIADATA / EmprendeSmart

**Fecha:** 2026-08-30
**Alcance:** 5 frentes en paralelo sobre el stack **local** (Supabase en Docker + Next.js dev + FastAPI). **No se tocó producción en ningún momento.**
**Viewports:** escritorio 1440x900 y móvil 390x844 con emulación táctil real (`hasTouch` + `isMobile`) y gestos del dedo despachados por CDP (`Input.dispatchTouchEvent`), no clics simulados. Tema claro y oscuro.
**Método:** se operó la aplicación de verdad (formularios enviados, ventas cobradas, gastos creados, stock ajustado, cobros registrados), con escucha de consola / `pageerror` / `requestfailed` / respuestas ≥400 en todas las corridas, y verificación de cada mutación contra Postgres. Cada hallazgo se reprodujo **al menos dos veces recargando la página entre intentos**.
**Verificación adversarial:** los 8 hallazgos más graves se volvieron a atacar con una instancia independiente del navegador, buscando activamente refutarlos. 7 quedaron **confirmados** (varios resultaron **peores** que lo reportado), 1 quedó **refutado en su conclusión** y se descartó.

**Capturas:** todas en `C:/Users/Usuario/AppData/Local/Temp/claude/C--Users-Usuario-Desktop-EIE-v0-saa-s-empresarial-completo--claude-worktrees-unruffled-davinci-ecdb04/9688ee9d-58a4-4768-b8d1-9b09be89976f/scratchpad/qa/` — abajo se nombran sólo por su nombre de archivo.

---

## Resumen ejecutivo

**27 hallazgos** tras descartar 1 refutado: **0 críticos · 5 altos · 14 medios · 8 bajos**.

La mala noticia es concentrada, no dispersa: **dos defectos de componentes compartidos explican 17 de los 27 síntomas**. Arreglando dos archivos del design system se cierran problemas en once pantallas distintas. Eso es una buena noticia disfrazada de mala.

| # | Hallazgo (una línea) | Sev. |
|---|---|---|
| **H1** | **[BUG DEL PO]** El desplegable de productos no se puede desplazar dentro de ningún modal: 23 de 32 productos son inalcanzables en /ventas, /compras y /stock | **Alto** |
| **H2** | El contenido del dashboard no puede encogerse: 12 pantallas se desbordan en móvil/tablet y esconden botones primarios (borrar producto, transferir stock, nueva compra) | **Alto** |
| **H3** | /reportes/comparativo muestra las 4 variaciones al revés y con el color invertido: "gastos -23% en verde" cuando en realidad subieron 30% | **Alto** |
| **H4** | /reportes/sucursal está vacío siempre, para todos los usuarios, desde el día uno — y tiene un segundo defecto detrás que lo mantendría vacío aun arreglando el primero | **Alto** |
| **H5** | La campana muestra 6 de 15 notificaciones y el panel no scrollea: el badge "9+" promete algo inalcanzable | **Alto** |
| **H6** | Cerrar la caja no muestra el arqueo: el panel con el faltante aparece 56–181 ms y se autodestruye | Medio |
| **H7** | Los tres botones "Exportar … CSV" no dan nunca ningún mensaje — ni de éxito ni de error — porque su sistema de toasts no está montado | Medio |
| **H8** | El formulario de compra afirma que "Cuenta corriente" NO genera cargo al proveedor, y sí lo genera | Medio |
| **H9** | Vaciar un campo opcional del perfil no se guarda, pero la app avisa "Perfil actualizado correctamente" | Medio |
| **H10** | Se puede borrar un proveedor con deuda abierta sin ninguna advertencia y la deuda queda invisible en toda la app | Medio |
| **H11** | Los movimientos de caja y banco que genera un gasto quedan sin motivo: plata que se movió sin explicación | Medio |
| **H12** | Borrar una compra a cuenta corriente no avisa que va a revertir el cargo del proveedor (el mismo diálogo en /gastos sí avisa) | Medio |
| **H13** | "Limpiar filtro" del popover de fechas de /gastos borra también el buscador, el centro de costo y la forma de pago | Medio |
| **H14** | La cuenta corriente del proveedor nunca dice de qué proveedor es | Medio |
| **H15** | Los diálogos de ajuste y de alta de cuenta reabren con el borrador que se había descartado, a un clic de confirmar una operación irreversible | Medio |
| **H16** | Los gráficos de los 3 reportes no tienen leyenda y pintan dos series distintas con el mismo color | Medio |
| **H17** | El breadcrumb dice "ALIADATA" en vez del nombre de la pantalla en 11 de 24 rutas, incluidas Caja, Banco y Sucursales | Medio |
| **H18** | Objetivos táctiles por debajo del mínimo en móvil: checkbox de conciliación de 16x16 px, acciones de fila y botón de menú de 28x28 px | Medio |
| **H19** | El menú lateral móvil no se cierra con Escape y no tiene botón de cerrar | Medio |
| **H20** | En /planes el CTA del plan que ya tenés está habilitado y dispara el alta de suscripción | Bajo |
| **H21** | Errores del servidor crudos en pantalla: "RN-B4…", "amounts_mismatch: Σ líneas…", "periodo_invalido…", "Error interno del servidor" | Bajo |
| **H22** | La cuenta corriente de un proveedor sin movimientos muestra un banner rojo de error para un caso normal | Bajo |
| **H23** | /reportes/formas-pago oculta en móvil las columnas Comprado, Gastado y Operaciones | Bajo |
| **H24** | El CSV de compras no incluye ni la forma de pago ni el proveedor, que sí se ven en el listado | Bajo |
| **H25** | Pluralizaciones mal formadas: "21 operaciónes" y "1 clientes registrados" | Bajo |
| **H26** | El cierre de caja imprime "$-37.200,00" (el signo adentro del importe) | Bajo |
| **H27** | El KPI "Margen por Canal" se corta y no hay tooltip que revele el valor completo | Bajo |

**Por qué no hay ningún hallazgo "crítico":** los dos candidatos iniciales se revisaron con lupa y bajaron. Uno (`/stock` en móvil) quedó **refutado** — ver la sección al final. El otro (`/sucursales/{id}/stock`) se absorbió en H2 y se bajó a alto porque, si bien el botón "Transferir" es invisible al abrir la pantalla, el usuario puede alcanzarlo paneando la ventana visual del navegador. **No encontramos pérdida de datos, corrupción, ni un solo agujero de seguridad o de tenencia en toda la corrida.**

---

# 1) El bug que reportó el PO

## H1 — [ALTO] El desplegable de productos no se puede desplazar dentro de ningún modal

**Confirmado.** Reproducido 4 veces en el reporte original y otras 6 en la verificación adversarial independiente, en los dos viewports, con el 100% de éxito. No es una carrera de carga (se probó esperando 8 s tras abrir el modal y 2,5 s tras abrir el desplegable: idéntico) y no depende de los datos sembrados.

**Dónde ocurre**
- `/ventas` → botón **"Nueva venta"** → campo **"Seleccionar producto"** ← *esto es exactamente lo que reportó el PO*
- `/ventas` → **"Editar venta"** (ícono lápiz) → mismo formulario, mismo defecto
- `/ventas` → mismo formulario → campo **"Seleccionar cliente"**
- `/compras` → **"Nueva compra"** → campo de producto *(no estaba en el reporte del PO — lo encontramos nosotros)*
- `/stock` → botón **"Ajustar"** → selector de producto *(tampoco estaba; y este modal ni siquiera usa el mismo contenedor, lo que prueba que la causa es más profunda)*
- **NO** ocurre en `/ventas/pos`, que usa el mismísimo componente pero fuera de un modal. Ese es el control positivo.

**Viewport:** ambos. En móvil (dedo) y en escritorio (rueda del mouse).

**Pasos**
1. Entrar a `/ventas` (en teléfono 390x844 táctil, o en escritorio 1440x900).
2. Tocar **"Nueva venta"** — se abre el panel desde abajo.
3. Tocar **"Seleccionar producto"** — se despliega la lista con los 32 ítems del catálogo.
4. Arrastrar con el dedo hacia arriba sobre la lista (o girar la rueda del mouse en escritorio).

**Qué se esperaba:** que la lista se desplace y se llegue hasta el último producto.

**Qué pasa:** la lista **no se mueve un solo píxel**. Se ven ~9 productos y los ~23 restantes son inalcanzables. Tampoco se pinta una barra de scroll que se pueda arrastrar. El único rodeo es escribir el nombre en "Buscar producto…" — si el usuario no recuerda cómo se llama el producto, no puede cargar la venta desde el formulario. En escritorio hay un segundo rodeo (apretar la flecha abajo 20 veces sí arrastra la lista); en móvil no existe, porque el teclado virtual no tiene flechas.

**Cifra corregida:** el reporte inicial hablaba de "8 de 25 visibles / 17 inalcanzables". La medición real es **9 de 32 visibles / ~23 inalcanzables** (25 productos + variantes). Es peor de lo que se creía, no mejor. Y **va a empeorar solo, sin tocar código**, a medida que crezcan los catálogos de los tenants.

**Evidencia**
- Sobre la lista (`[cmdk-list]`): `scrollHeight=1096`, `clientHeight=300`, `scrollTop=0` antes y después del gesto. `offsetWidth − clientWidth = 0` → no hay barra que arrastrar.
- Móvil: 15 eventos `touchmove`, **los 15 con `defaultPrevented=true`**. Escritorio: 2 eventos `wheel`, **los 2 con `defaultPrevented=true`**.
- Asignar `scrollTop=150` por JavaScript **sí funciona** → el elemento es perfectamente scrollable; lo que se está cancelando es el gesto.
- **Control positivo:** el mismo componente en `/ventas/pos` (página normal, sin modal, mismos 32 ítems, mismo alto) sí scrollea: `scrollTop 0 → 245` en móvil y `0 → 400` en escritorio, con 0 eventos cancelados.
- **Contraprueba causal:** con el desplegable ya abierto, moviendo por JavaScript el nodo de la lista desde `document.body` hacia adentro del diálogo y repitiendo **exactamente el mismo gesto**, pasa a `touchmove 0/11 cancelados` y `scrollTop 0 → 245`. El gesto idéntico pasa de bloqueado a funcional con sólo cambiar de dónde cuelga el nodo.

### Causa raíz — qué es exactamente y por qué pasa

Es un choque entre **dos mecanismos de Radix que no se conocen entre sí**.

1. **El desplegable se monta fuera del modal.** `frontend/components/ui/popover.tsx:16-27` envuelve *siempre* el contenido del popover en un `<PopoverPrimitive.Portal>`. Verificado en el DOM: `[data-radix-popper-content-wrapper].parentElement === document.body`. O sea, visualmente la lista aparece adentro del formulario, pero en el árbol del documento cuelga del `body`, afuera del diálogo.

2. **El modal bloquea todo scroll que no sea suyo.** Radix Dialog monta su overlay dentro de `react-remove-scroll` con `shards: [contentRef]` (verificado en el bundle instalado, `@radix-ui/react-dialog@1.1.4/dist/index.js:160`). Ese `shard` es la única excepción: sólo el subárbol del contenido del diálogo queda exceptuado. Todo lo demás recibe `preventDefault()` en cada `wheel`/`touchmove`. En el DOM se ve el efecto: `body[data-scroll-locked="1"]`, `overflow:hidden`, `pointer-events:none`.

3. **Por lo tanto:** como el popover cuelga del `body`, no está en el shard → cada gesto sobre la lista se cancela → la lista nunca se desplaza, aunque sea scrollable.

**La mitigación que el código intenta está rota por dos motivos independientes, y sólo uno era visible:**

- **(a)** El `modal={false}` está puesto sobre el `<PopoverContent>` en vez de sobre el `<Popover>` raíz — `frontend/components/shared/product-picker.tsx:199` y `frontend/components/ui/searchable-select.tsx:135`. Radix nunca lo recibe, y React lo delata en consola: *"Received `false` for a non-boolean attribute `modal`"*. La prop se filtró como atributo del DOM.
- **(b)** **Más importante: aunque estuviera bien ubicada, `modal={false}` no arreglaría nada.** Es el valor **por defecto** de Radix Popover (verificado: `modal = false` en `@radix-ui/react-popover@1.1.4/dist/index.js`), y es justamente ese default el que hace que el Popover **no** monte su propio `RemoveScroll`. Corregir sólo la ubicación deja el bug intacto.

### Qué habría que tocar

El defecto **no vive en la pantalla de ventas**, vive en los componentes compartidos: `frontend/components/ui/popover.tsx`, `frontend/components/ui/searchable-select.tsx` y `frontend/components/shared/product-picker.tsx`. Cualquier arreglo hecho pantalla por pantalla va a dejar las otras rotas.

Tres direcciones, cualquiera ataca el eslabón correcto (la contraprueba de reparentado lo demuestra). A validar en el change:

1. **Pasar `modal` (true) al `<Popover>` raíz**, para que el Popover monte su propio `RemoveScroll` y quede al tope de la pila de bloqueo. Es el cambio de una línea, pero hay que verificar que no rompa el cierre por clic afuera ni el foco dentro del Sheet.
2. **No portalizar el `PopoverContent` cuando vive adentro de un modal** (renderizarlo en su lugar del árbol). Es el equivalente permanente de la contraprueba que ya funcionó. Ojo: en escritorio el contenido del diálogo tiene `overflow-hidden` y podría recortar el desplegable — habría que revisar ese recorte.
3. **Hacer llegar el nodo del popper como `shard` del `RemoveScroll` del Dialog.** Es el más correcto conceptualmente y el más invasivo.

**Además, y aparte:** corregir la ubicación de `modal={false}` en los dos archivos (elimina la advertencia de React y el atributo espurio en el DOM), aunque por sí solo no resuelva nada.

**Cobertura de regresión sugerida:** un test que abra el selector adentro del modal, despache un `wheel` y afirme que `scrollTop > 0`. Hoy no existe ninguno.

**Capturas:** `ventas-mobile-picker-tras-arrastre.png` (móvil, tras arrastrar) · `ventas-desktop-picker-tras-wheel.png` (escritorio, tras 2 ruedas) · `pos-mobile-picker-tras-arrastre.png` (**control positivo**: el POS sí scrollea) · `ventas-mobile-cliente-tras-arrastre.png` (mismo defecto en el selector de clientes) · `v7-compras-mobile.png` y `v7-stock-mobile.png` (el mismo defecto en compras y en stock) · `v3-B-reparentado-mobile.png` (contraprueba: reparentado, funciona) · `ventas-mobile-picker-teclado.png` (con el teclado sí baja).

---

# 2) Hallazgos por prioridad

## H2 — [ALTO] El contenido del dashboard no puede encogerse: 12 pantallas se desbordan y esconden botones primarios

> **Un solo problema con doce síntomas.** Se reportó por separado en los cinco frentes; es el mismo defecto del shell.

**Dónde ocurre** (ancho medido del documento contra un viewport de 390 px):

| Pantalla | Ancho real | Qué queda fuera de pantalla |
|---|---|---|
| `/compras` | **670** px | El CTA **"+ Nueva compra"**, "Exportar", importes y acciones de cada fila |
| `/sucursales/{id}/stock` | **607** px | Los **32 botones "Transferir"** enteros, y "Ajustar" cortado |
| `/caja` y `/banco` al desplegar "Historial de movimientos" | **762** / **698** px | Las columnas **Importe y Saldo de todos los movimientos**, y "Cerrar caja" queda con 14 px visibles de 92 |
| `/stock` | **544** px | "Ajustar stock", "Importar ajuste", la paginación |
| `/sucursales` | **485** px | Los 3 botones **"Desactivar sucursal"** y la campana de notificaciones |
| `/ventas` con una fila expandida | **465** px | "Exportar ventas CSV", "Nueva venta", los importes de cada fila, "Enviar por WhatsApp" |
| `/productos` | **453** px | El **ícono de tacho de las 25 filas** — borrar un producto es imposible desde el teléfono |
| `/productos` → modal "Importar CSV" | modal a 406 px | El botón primario **"Importar N filas"** cortado 47 px |
| `/configuracion` → "Formas de pago" | **427** px | "Nueva" y los 7 botones de desactivar; el badge largo pisa el ícono de editar |
| `/exportaciones` | **415** px | La campana de notificaciones (9 px fuera) |
| `/ventas`, `/gastos`, `/compras`, `/productos`, `/clientes` **a 768–1024 px** (tablet vertical) | hasta **1372** px | Sus CTA primarios. `/productos` a 768 desborda **465 px**, ~38% de la página |

**Viewport:** móvil siempre; **además tablet 768–1024**, que nadie había mirado (`/gastos`, la pantalla que se usaba como contraejemplo "sana", está tan rota como `/compras` en ese rango).

**Pasos (ejemplo con el caso más grave):**
1. Abrir `/productos` en un teléfono (390x844, táctil).
2. Mirar los íconos de acción al final de cada tarjeta de producto: se ve el lápiz, no se ve el tacho.
3. Intentar arrastrar horizontalmente para alcanzarlo.
4. Como alternativa, tocar el lápiz y buscar un "Eliminar" dentro del diálogo de edición.

**Qué se esperaba:** que el contenido entre en el ancho del teléfono, o que la zona ancha se desplace con el dedo sin arrastrar la página entera.

**Qué pasa:** el documento se estira más allá del viewport y, como `body` tiene `overflow-x: hidden`, lo que sobra queda **recortado y sin barra de scroll**. En `/productos` el tacho arranca en x=395 sobre una pantalla de 390 y el diálogo de edición no ofrece ninguna acción de eliminar (verificado en código: `deleteProduct` tiene un solo consumidor en todo el front). En `/caja` y `/banco`, desplegar el historial se lleva puesto el encabezado, el título y las tarjetas de la página entera.

**Salvedad honesta — y es importante:** en varias de estas rutas el contenido **sí es alcanzable**, pero con un gesto que la interfaz no insinúa en ningún lado. Chrome móvil expande el "layout viewport" y el usuario puede panear la ventana visual (medido: `visualViewport.offsetLeft` pasa de 0 a 154 en `/stock`, a 217 en `/sucursales/{id}/stock`, a 95 en `/sucursales`, a 280 en `/compras`; y con ese paneo se llega a tocar "Ajustar stock" y hasta a cambiar de página). En otras rutas (`/caja`, `/banco`, `/productos`) las mediciones dieron que ese paneo **no** ocurre y el contenido queda irrecuperable. **No pudimos conciliar esa diferencia con certeza**, así que la lectura conservadora, que vale para todas: *el control primario es invisible al abrir la pantalla y, en el mejor de los casos, se llega con un arrastre horizontal que ningún usuario va a descubrir solo* — no hay barra de scroll, ni sombra, ni ninguna afordancia. Al panear, además, se pierde por la izquierda la columna del nombre del producto: nunca se ven a la vez el producto y sus acciones.

**Antigüedad:** en `/compras` el ancho mínimo de la fila de encabezado sola es 479 px, así que la pantalla se desborda **incluso con cero compras cargadas**. No es un efecto del sembrado; un tenant nuevo lo sufre en la primera carga.

### Causa raíz

**Capa 1 — el eslabón que convierte un desborde local en el estiramiento de toda la página.**
`frontend/components/ui/sidebar.tsx:334` (`SidebarInset`) emite `<main className="relative flex min-h-svh flex-1 flex-col bg-background …">` **sin `min-w-0`**. Es un flex item con `flex:1 1 0%` y por lo tanto `min-width:auto`, cuyo mínimo automático resuelve al min-content de todo su subárbol. Resultado: cualquier contenido ancho de cualquier pantalla estira el dashboard entero. Llamativo: el resto de ese mismo archivo **sí** pone `min-w-0` en sus sub-componentes (líneas 433, 504, 702, 734) — al inset se le pasó.
`frontend/app/(dashboard)/layout.tsx:28` (`div.flex-1 overflow-auto p-4 md:p-6`) tampoco corta la cadena: le falta `min-w-0` y su `overflow-auto` es letra muerta en el eje horizontal.

**Verificado en vivo:** aplicando sólo `min-width:0` sobre ese `<main>` desde la consola, `documentElement.scrollWidth` cae de 670→390 en `/compras`, de 453→390 en `/productos`, de 762→390 en `/caja`, y el tacho de `/productos` pasa a quedar dentro del viewport. **Un atributo.**

**Capa 2 — lo que convierte el desborde en contenido inalcanzable.**
`frontend/app/globals.css:184`: `body { @apply … overflow-x-hidden }`. Con `html` en `overflow-x: visible`, ese `hidden` se propaga al viewport y mata el scroll horizontal del documento. Sin esa regla el usuario al menos tendría una barra.

**Capa 3 — quién empuja el ancho en cada pantalla** (contribuyentes, no causa raíz):
- `frontend/components/export/ExportButton.tsx:113-135` — la etiqueta "Exportar inventario CSV **(50 restantes)**" mide 285-295 px de una pieza y **no tiene ningún colapso responsive**, a diferencia de sus hermanos en la misma barra, que sí usan `hidden sm:inline`.
- Filas de acciones sin `flex-wrap`: `productos` (`components/products/product-catalog.tsx:358`), `stock` (`app/(dashboard)/stock/page.tsx:160`), `compras` (`app/(dashboard)/compras/page.tsx:51-58`), `sucursales` (`components/branches/BranchList.tsx:105`, además con `shrink-0`). `/gastos` **sí** usa `flex-wrap` (`gastos/page.tsx:142`) — por eso zafa a 390 px.
- `frontend/components/compras/purchase-operations-list.tsx:335-336` — concatena **todos** los nombres de producto de la operación en un solo `<span className="… truncate">`; el `truncate` nunca se activa (medido: `scrollWidth === width` en los 11 spans) y el span crece hasta 518 px. El componente espejo de ventas (`sale-operations-list.tsx:404-408`) hace lo correcto: primer producto + "· +N más". Es literalmente el mismo componente con esa única diferencia.
- `frontend/components/ledger/LedgerMovementsPanel.tsx:77-111` — columnas en píxeles fijos (`w-[84px]` + `w-[140px]` + `w-24` + gaps = 364 px de mínimo contra los ~276 disponibles), sin ningún breakpoint que las angoste o las apile. Amplificado por `frontend/components/ui/scroll-area.tsx:17`, donde Radix inyecta un hijo con `display:table` que dimensiona la fila a max-content (648 px). El mismo molde está copiado en `frontend/components/stock/stock-movements-panel.tsx:111-160`.
- `frontend/components/ventas/sale-operations-list.tsx:496` — la fila de acciones del detalle expandido (`Facturar` + `Comprobante` + `Enviar por WhatsApp`) tiene `flex-wrap: nowrap` y 399 px de ancho mínimo.

### Qué habría que tocar

**Arreglo de raíz (2 líneas, cierra la mayoría):** `min-w-0` en el `<main>` de `SidebarInset` y en el contenedor de `(dashboard)/layout.tsx:28`. Verificado en vivo en cuatro rutas distintas.
**Después, por pantalla:** `flex-wrap` en las cuatro barras de acciones, colapso responsive de la etiqueta del `ExportButton` (mismo patrón `hidden sm:inline` que ya usan sus hermanos), alinear el span de compras con el de ventas, y darle scroll horizontal propio al panel de movimientos (o apilar sus columnas por debajo de `sm`).

**Capturas:** `compras-gastos-h1-compras-mobile-cortada.png` · `compras-gastos-h1-compras-mobile-tras-panear.png` (tras panear se ve el CTA y desaparece el encabezado) · `catalogo-recorte-productos-mob.png` · `z1-productos-mob.png` · `z3-tap-borde-derecho.png` · `nucleo-sucursal-stock-mob.png` · `nucleo-mob-_sucursales.png` · `finanzas-caja-mobile-overflow-i1.png` · `advA1-despues.png` · `advA4-banco-despues.png` · `catalogo-recorte-stock-mob.png` · `catalogo-importador-mob-revision.png` · `nucleo-cfg-mob-formas-pago.png` · `nucleo-mob-_dashboard.png` · `ventas-mobile-fila-expandida.png` · `ventas-mobile-overflow-tras-pan.png` · `ventas-desktop-expandida-control.png` (control: en escritorio no pasa) · `v8-compras-tablet834.png` · `compras-minwidth0-390.png` (el arreglo, aplicado en vivo).

---

## H3 — [ALTO] /reportes/comparativo muestra las variaciones al revés, con el color invertido

**Dónde:** `/reportes/comparativo` — las 4 tarjetas de KPI. **Viewport:** ambos. **Reproducido 6/6.**

**Pasos:** entrar a la pantalla y **no tocar nada** (los períodos por defecto son A = mes en curso, B = mes anterior).

**Qué se esperaba:** que el porcentaje describa cómo evolucionó el negocio del mes viejo al nuevo.

**Qué pasa:** **las cuatro tarjetas** muestran el signo dado vuelta y, en consecuencia, el semáforo de color invertido:

| Tarjeta | Lo que muestra | La realidad |
|---|---|---|
| Ventas | `+0,7%` en **verde** | bajaron 0,65% |
| **Gastos** | `-23,0%` en **verde** | **subieron 29,81%** |
| Compras | `-4,5%` en **verde** | subieron 4,75% |
| Operaciones | `-47,1%` en **rojo** | subieron 88,89% |

El caso de **Gastos es el peor y no estaba en el reporte inicial**: la pantalla le dice al microemprendedor "tus gastos bajaron 23%" en verde, cuando en realidad subieron casi 30%. Es una feature de pago (gateada a plan avanzado) cuyo único propósito es mostrar evolución, y falla en el 100% de sus indicadores, en la configuración por defecto, para cualquier tenant, sin ninguna interacción.

**Evidencia:** llamando la misma RPC con los períodos invertidos —misma función, mismos datos, sólo cambia el orden de los argumentos— salen los números correctos. Colores computados del DOM: `rgb(34,197,94)` verde en las tres primeras, `rgb(197,17,17)` rojo en Operaciones.

**Causa raíz:** contrato roto entre la RPC y la página.
- La RPC calcula los cuatro deltas como **(B − A) / A**, con el período A como base (`supabase/migrations/20260606120000_period_comparison.sql:104-111`, idéntico en la definición viva; la Edge Function `ai-comparativo/index.ts:135-138` lo rotula explícitamente "vs período A").
- Pero `frontend/app/(dashboard)/reportes/comparativo/page.tsx:152-155` asigna los defaults **al revés de ese contrato**: A = mes actual, B = mes anterior. Con A = período nuevo, la base del porcentaje pasa a ser el presente.
- `DeltaBadge` (`page.tsx:57-76`) hace `isGood = value > 0` (negado por `invertColors` en Gastos y Compras), tratando ese número como si fuera el crecimiento del período más nuevo. Como el número está temporalmente dado vuelta, el semáforo queda invertido en las 4 — **incluidas las dos con `invertColors`, donde la doble inversión no se cancela**.
- Agravante de UX: en ningún lado se rotula qué mide el badge. La pantalla sólo dice "PERÍODO A vs PERÍODO B".
- **Agravante extra (lectura de código, no ejecutado):** la Edge Function del botón "Analizar con IA" arma el prompt con la misma cronología invertida y después le pide al modelo "analizá la evolución del negocio". El insight pago de IA se construye sobre el mismo orden temporal dado vuelta.

**Qué tocar:** invertir los defaults en `page.tsx:152-155` (A = mes anterior como base) resuelve signo y color de una sola vez. La alternativa —invertir la fórmula en la RPC— obliga a actualizar `ai-comparativo/index.ts` en el mismo change. Cualquiera de las dos exige rotular el badge y cubrirlo con un test: hoy **no existe ningún test** (frontend, backend ni pgTAP) que toque `rpc_period_comparison` ni la página. El defecto es original de la feature (mismo commit `da211d2`, C-12).

**Capturas:** `finanzas-comparativo-mobile.png` · `adv-comparativo-desktop.png` · `adv-comparativo-final.png`.

---

## H4 — [ALTO] /reportes/sucursal está vacío siempre, y tiene un segundo defecto detrás

**Dónde:** `/reportes/sucursal`. **Viewport:** ambos. **Reproducido 3/3** (una corrida esperando 12 s para descartar carrera de carga).

**Pasos:** entrar a la pantalla con el período por defecto, que tiene 25 ventas por $324.850 y gastos por $1.158.787 repartidos en 2 sucursales activas.

**Qué se esperaba:** el gráfico "Ventas vs Gastos por Sucursal" con sus totales.

**Qué pasa:** "Sin datos para el período seleccionado" y la tabla en $0 / $0 / 0, con cualquier rango. **Sin error, sin request, sin log**: falla en absoluto silencio.

**Causa raíz — son dos defectos apilados, y el primero venía tapando al segundo desde hace casi 3 meses:**

1. `frontend/app/(dashboard)/reportes/sucursal/page.tsx:80` resuelve el tenant desde `session.session?.user.user_metadata?.account_id` y, si es `null`, hace `return []` sin avisar (línea 82). **Nada en todo el repositorio escribe nunca `account_id` en `user_metadata`**: un grep global sobre `frontend/`, `backend/` y `supabase/` cruzando `user_metadata|raw_user_meta_data|app_metadata` con `account_id` no devuelve una sola escritura. Los triggers de alta sólo copian nombre/teléfono/localidad, y el hook de token emite `role`/`plan` bajo `app_metadata` (y además está dormido). O sea: **ningún usuario, en ningún entorno, tiene ese campo. La pantalla nunca funcionó para nadie.** Es el único lugar del frontend que lee ahí; el canon del proyecto es `account_members` (`frontend/contexts/auth-context.tsx:94-97`).

2. **Arreglar eso no alcanza.** Llamando la RPC a mano con el JWT real y el `account_id` correcto devuelve **HTTP 400, SQLSTATE 42702: `column reference "branch_id" is ambiguous`**. El CTE `all_branch_ids` referencia `branch_id` sin calificar y choca con el parámetro OUT homónimo del `RETURNS TABLE` (`supabase/migrations/20260607000000_sucursales_module.sql:304`, arrastrado verbatim a la definición viva en `20260814000001_v3_reporting_invariants.sql:408`). **`rpc_branch_report` nunca ejecutó correctamente desde su creación (C-06, 2026-06-07).** Y como la página no tiene rama de error, tras corregir el punto 1 seguiría mostrando "Sin datos" en silencio, ahora tapando un 400 real.

**Qué tocar:** resolver la cuenta por `account_members` como el resto de la app; calificar `bs.branch_id` / `be.branch_id` en el CTE (o renombrar el parámetro OUT); y agregarle a la página una rama de error visible. Alcance acotado: `rpc_branch_report` tiene un único consumidor; el espejo `rpc_cost_center_report` **no** tiene el bug (se ejecutó y devuelve filas OK).

**Capturas:** `finanzas-sucursal-desktop-vacio.png` · `ver-sucursal-desktop.png` · `finanzas-sucursal-mobile.png`.

---

## H5 — [ALTO] La campana muestra 6 de 15 notificaciones y el panel no scrollea

**Dónde:** campana del encabezado (`frontend/components/dashboard/NotificationBell.tsx`), presente en **todas** las pantallas del dashboard. **Viewport:** ambos. **Reproducido 2 veces.**

**Pasos:** con notificaciones cargadas (el fixture tiene 15), tocar la campana — el badge dice "9+" — e intentar ver las más viejas con la rueda o con el dedo.

**Qué se esperaba:** que el panel scrollee hasta la última, o que haya un "Ver todas".

**Qué pasa:** el panel **renderiza los 15 ítems pero recorta a los 6 primeros** y no hay forma de llegar a los 9 restantes. La rueda no mueve nada (`scrollTop=0` antes y después), el arrastre táctil tampoco. **No existe enlace "ver todas" ni una ruta de notificaciones**. El badge "9+" promete contenido que el usuario no puede alcanzar.

**Evidencia:** el contenido del dropdown mide `scrollHeight === clientHeight === 328` con `overflow-y:hidden`; el viewport interno de Radix tiene `clientHeight === scrollHeight === 810` (crece a su contenido y queda recortado por el padre). El último ítem cae en y=811..865 contra un borde en 380.

**Causa raíz:** `NotificationBell.tsx:92` pone `<ScrollArea className="max-h-80">`. La clase de altura va al **root** del ScrollArea (que es `overflow-hidden`) y no al **viewport interno**, así que el límite recorta en lugar de habilitar el scroll. Es el mismo error de una línea que en `frontend/components/ui/scroll-area.tsx` aparece del otro lado (ver H2).

**Capturas:** `nucleo-dash-mob-notificaciones.png` · `nucleo-dash-desk-notificaciones.png`.

---

## H6 — [MEDIO] Cerrar la caja no muestra el arqueo

**Dónde:** `/caja` → "Cerrar caja". **Viewport:** ambos. **Reproducido 5/5.**

**Pasos:** con una sesión abierta, "Cerrar caja" → escribir un efectivo contado distinto del esperado → "Confirmar cierre".

**Qué se esperaba:** el panel de arqueo que el propio componente trae ("Faltante en caja: −$1.000,00", con Esperado / Contado y un botón "Listo").

**Qué pasa:** el diálogo desaparece de golpe y la pantalla pasa a "No hay ninguna sesión de caja abierta". Ni panel, ni toast, ni mensaje: **cero confirmación** de que el cierre ocurrió y de cuál fue la diferencia. Sólo se descubre bajando hasta "Historial de sesiones".

**Corrección importante sobre el reporte original:** se dijo que el bloque de resultado era "código muerto". **Es falso: el panel sí renderiza**, midiendo cada 10 ms se lo ve aparecer a los ~222 ms y desaparecer a los ~403 ms. **La ventana de visibilidad es de ~181 ms en escritorio y ~56 ms en móvil** — o sea que en teléfono es peor, y también afecta al caso "Arqueo exacto" sin diferencia. La medición inicial no lo vio porque los locators de Playwright aliasean a ~300-400 ms.

**Prueba causal decisiva:** retrasando artificialmente 3000 ms **sólo el refetch** de `current-session`, el panel aparece a los 198 ms y **queda visible hasta los 3320 ms**, desapareciendo exactamente cuando resuelve ese GET. La ventana de visibilidad *es* la latencia del refetch. Es una carrera cuyo perdedor es siempre el usuario en red rápida.

**Causa raíz:** `frontend/app/(dashboard)/caja/page.tsx:216-232` monta el `<CloseSessionDialog>` (línea 227) **adentro** de la rama `{!currentSession ? … : (…)}`. Al resolverse la mutación, `frontend/hooks/data/use-cash-session.ts:183-186` invalida las queries → el GET responde 404 → `currentSession` pasa a `null` → la rama se invierte → Radix desmonta el diálogo con su `result` adentro. El `setResult` sí corre y sí pinta; lo que lo mata es el desmontaje.

**Qué tocar:** subir el `<CloseSessionDialog>` fuera del ternario, con estado `open` propio a nivel página — exactamente como ya se hace con `LedgerAdjustmentDialog` en la línea 298. Elimina la carrera sin tocar el hook.

**Antigüedad:** el patrón viene del commit original del módulo (`804db74`, C-28). Estuvo **enmascarado desde julio hasta el 2026-08-23**: mientras el cierre fallaba por el header `Idempotency-Key` faltante (#451), el diálogo mostraba el error, que sí es persistente. Al arreglar el cierre quedó expuesto el parpadeo. No es una regresión reciente.

**Atenuantes:** cero pérdida de datos (importes y diferencia se persisten correctos), y la diferencia queda visible en la misma pantalla, en "Historial de sesiones", sin navegar. **Agravante:** es un flujo de dinero donde el cajero necesita ver el faltante en el momento; y la pantalla **no tiene ningún toaster montado** (grep de `toast|sonner|Toaster` en `caja/page.tsx` y `components/cash/*`: cero coincidencias).

**Capturas:** `finanzas-arqueo-tras-cierre.png` · `vx-arqueo-normal.png` · `vx-arqueo-mobile.png` · `vx-arqueo-slow.png` (el experimento con el refetch retrasado).

---

## H7 — [MEDIO] Los tres "Exportar … CSV" no dicen nunca nada

> Un solo defecto, tres pantallas.

**Dónde:** el botón `ExportButton` de `/ventas` ("Exportar ventas CSV"), `/gastos` y `/compras`. **No** afecta a los otros botones "Exportar" (los client-side), que sí funcionan y sí avisan. **Viewport:** ambos. **Reproducido 3-4 veces por pantalla.**

**Pasos:** tocar el botón y esperar 7 segundos mirando la pantalla.

**Qué se esperaba:** que algo diga qué pasó — "Exportación lista", "Cuota agotada" o "Error al exportar", que es exactamente lo que el componente intenta emitir.

**Qué pasa:** un spinner brevísimo y después **nada**: sin toast, sin banner, sin texto de error. El usuario no sabe si el archivo salió o si falló.

**Causa raíz:** `frontend/components/export/ExportButton.tsx` importa `toast` desde `@/hooks/use-toast` (el toast de shadcn con reducer), que necesita el `<Toaster />` de `components/ui/toaster.tsx` para pintarse — y **ese componente no se monta en ningún archivo del proyecto**. El único `<Toaster />` de la app es el de `sonner` (`app/layout.tsx:8` y `:68`), otro sistema distinto. Grep de `<Toaster` en `app/` y `components/`: sólo esa línea. Por eso **las cinco ramas del botón son invisibles**, incluida la de éxito.

**Salvedad honesta:** el 503 concreto que se observó es del entorno local (no hay contenedor `supabase_edge_runtime` levantado), así que **no podemos afirmar que en producción el export falle**. Lo que sí es un defecto de código independiente del entorno es que ninguna de las cinco respuestas del botón llegue jamás al usuario.

**Qué tocar:** o montar el `<Toaster />` de shadcn, o —mejor, para no tener dos sistemas de toast conviviendo— migrar `ExportButton` a `sonner`, que es el que el resto de la app ya usa.

**Capturas:** `ventas-mobile-export-silencioso.png` · `ventas-desktop-export-edge.png` · `compras-gastos-h9-export-sin-feedback.png` · `export-silencio-r1-desktop.png`.

---

## H8 — [MEDIO] El formulario de compra dice que "Cuenta corriente" no genera cargo, y sí lo genera

**Dónde:** `/compras` → "Nueva compra" → Forma de pago = "Cuenta corriente". **Viewport:** ambos. **Reproducido 2 veces.**

**Pasos:** elegir "Cuenta corriente" y leer el texto de ayuda; elegir un proveedor con saldo $0; agregar un producto y confirmar; ir a la cuenta corriente de ese proveedor.

**Qué se esperaba:** que el texto de ayuda diga lo que el sistema hace.

**Qué pasa:** el texto afirma *"Esta etiqueta no genera un cargo en la cuenta corriente del proveedor. Para eso, registrá el pago desde la cuenta corriente del proveedor."* — y el cargo **sí se postea**: "Insumos Andinos" pasó de $0 a $8.900 y "Panificados El Trigal" de $0 a $8.900 en la segunda vuelta (verificado en `supplier_accounts`). El propio diálogo se contradice dos líneas más abajo: muestra "Saldo actual: $0" y "Después de esta compra: $8.900". **El usuario lee que la etiqueta es inocua y termina generando deuda real contra el proveedor.**

**Causa raíz:** `frontend/components/payment-methods/PaymentMethodSelect.tsx:183`, dentro de `PaymentMethodSupportText`, rama `kind === "credit"` con `context` distinto de `"sale"`. El comentario del propio archivo (L158-160) explica el desfasaje: *"Compra — 'credit'/'cash': SIN CAMBIOS — el lado proveedor sigue sin cargo automático (…) `compras-proveedor-cuenta-corriente` es un change aparte"*. **Ese change ya se mergeó** (2026-08-23, PR #452) y el texto quedó desactualizado.

**Qué tocar:** reescribir esa rama del texto de ayuda, espejando el que ya existe para la venta a crédito. Es texto, no lógica.

**Captura:** `compras-gastos-h4-copy-ctacte-contradictoria.png`.

---

## H9 — [MEDIO] Vaciar un campo del perfil no se guarda, pero la app dice que sí

**Dónde:** `/configuracion` → pestaña Perfil. **Viewport:** ambos. **Reproducido 2 veces.**

**Pasos:** cargar un valor en "Nombre del negocio" y guardar (persiste bien); después **borrarlo** hasta dejarlo vacío y guardar; recargar.

**Qué se esperaba:** que el campo quede vacío, o que la app avise que no se puede.

**Qué pasa:** sale el toast verde "Perfil actualizado correctamente", el campo se ve vacío, **y al recargar reaparece el valor viejo**. Verificado en la base: `profiles.business_name` conservaba el valor anterior. Afecta a los **cinco** campos opcionales (Apellido, Nombre del negocio, Teléfono, Localidad, Bio): una vez cargados, **no se pueden vaciar nunca más**.

**Causa raíz:** `frontend/components/settings/ProfileForm.tsx:45-49` arma el payload con `businessName: businessName.trim() || undefined` (mismo patrón en los otros cuatro). El string vacío se vuelve `undefined`, se omite del update y la columna queda intacta — mientras la UI reporta éxito.

**Qué tocar:** distinguir "campo no enviado" de "campo enviado vacío" (mandar `null` explícito, o usar el equivalente de `model_fields_set` que el backend ya usa en otras rutas).

**Captura:** `nucleo-perfil-vaciar.png`.

---

## H10 — [MEDIO] Se puede borrar un proveedor con deuda abierta sin ninguna advertencia

**Dónde:** `/proveedores` → ícono de tacho. **Viewport:** ambos. **Reproducido 2 veces.**

**Pasos:** tocar el tacho de un proveedor con saldo, leer el diálogo, confirmar, y después intentar encontrar el proveedor y su deuda en cualquier pantalla.

**Qué se esperaba:** que el diálogo diga que ese proveedor tiene saldo pendiente y cuánto, o que bloquee el borrado mientras haya deuda — igual que la app bloquea editar una compra que ya movió plata.

**Qué pasa:** el diálogo sólo dice *"¿Eliminar «Panificados El Trigal»? Esta acción no se puede deshacer. Las compras que ya lo referencian siguen siendo legibles."* Se borra con un clic. **Como el único acceso a la cuenta corriente de un proveedor es el botón de su fila en ese listado, la deuda deja de ser alcanzable desde la UI.** En la prueba quedaron **$116.550 de deuda fuera de la vista** entre dos borrados.

**Evidencia:** `SELECT` posterior → *Distribuidora Cuyo SA* (borrado, $107.650) y *Panificados El Trigal* (borrado, $8.900). El borrado es **soft** (`backend/services/suppliers.py:53-61`), así que el saldo no se pierde: **se vuelve inaccesible**. Ojo con el futuro: los FK hacia `suppliers` son `ON DELETE CASCADE` (`supplier_accounts_supplier_id_fkey`, `payments_made_supplier_id_fkey`), o sea que un hard delete sí borraría cuenta y pagos.

**Qué tocar:** guard en el servicio de baja (o al menos advertencia con el monto en el diálogo). Vale la pena mirarlo junto con el equivalente de clientes.

**Capturas:** `compras-gastos-h6-borrar-proveedor-con-deuda.png` · `proveedores-tras-borrado.png`.

---

## H11 — [MEDIO] Los movimientos de caja y banco que genera un gasto quedan sin motivo

**Dónde:** `/caja` → Historial de movimientos y `/banco` → Historial de movimientos. **Viewport:** ambos. **Reproducido 4 veces.**

**Pasos:** crear un gasto en efectivo con "Registrar en caja" tildado, y otro por transferencia; mirar los historiales.

**Qué se esperaba:** que la fila del libro diga de qué gasto se trata en la columna MOTIVO, como lo hacen todos los demás movimientos ("Compra de insumos de limpieza", "Alquiler del local"). **El dato existe: la descripción del gasto es obligatoria.**

**Qué pasa:** sale `Gasto | (motivo vacío) | 30/8/26 | -1.234,56` y `Transferencia sal. | (motivo vacío) | Sin conciliar | -3.210,00`. Desde el libro no hay forma de saber a qué gasto corresponde el egreso.

**Causa raíz:** `rpc_create_expense` llama a `public.c28_register_cash_movement(p_cash_session_id, -p_amount, 'expense', v_expense_id)` **sin pasar el 5º parámetro `p_description`** (la firma lo tiene, con `DEFAULT NULL`), y a `public._pay_register_operation_bank_movement(..., p_date, v_gate_branch, NULL)` donde ese último `NULL` es justamente `p_description`. Verificado sobre el cuerpo vivo con `pg_get_functiondef`.

**Qué tocar:** pasar la descripción del gasto en ambas llamadas. Dos argumentos. Conviene además un backfill de los movimientos históricos si el PO lo quiere.

**Capturas:** `compras-gastos-h2-caja-motivo-vacio.png` · `compras-gastos-h2-banco-motivo-vacio.png`.

---

## H12 — [MEDIO] Borrar una compra a cuenta corriente no avisa que revierte el cargo

**Dónde:** `/compras` → tacho de una operación con badge "Cuenta corriente". **Viewport:** ambos. **Reproducido 2 veces.**

**Qué se esperaba:** que el diálogo enumere la compensación, **como ya hace `/gastos`**: *"Se va a compensar: se registrará el ingreso correspondiente en la caja abierta actual"*. La app ya sabe redactarlo: el tooltip del lápiz bloqueado de esa misma fila dice *"borrá esta compra (revierte el cargo y repone el stock)"*.

**Qué pasa:** el diálogo dice sólo *"¿Eliminar esta compra? Esta acción no se puede deshacer."* Nada sobre el cargo en cuenta corriente ni sobre la reposición de stock, **aunque el borrado efectivamente revierte ambos** (verificado: el saldo de Insumos Andinos pasó de $8.900 a $0.00).

**Qué tocar:** copiar el patrón de compensación que ya existe en el diálogo de `/gastos`.

**Capturas:** `compras-gastos-h5-borrar-compra-sin-compensacion.png` · `compras-gastos-h5-borrar-gasto-con-compensacion.png` (el contraejemplo correcto).

---

## H13 — [MEDIO] "Limpiar filtro" del popover de fechas borra todos los filtros

**Dónde:** `/gastos` → "Filtrar fechas" → "Limpiar filtro". **Viewport:** ambos. **Reproducido 2 veces.**

**Pasos:** buscar "Alquiler", filtrar por Transferencia (el contador baja a 2), abrir "Filtrar fechas", poner un Desde, y tocar "Limpiar filtro" (el único botón del popover, debajo del título "Rango de fechas").

**Qué se esperaba:** que limpie **sólo el rango de fechas**, como sugiere el título del popover y la etiqueta en singular.

**Qué pasa:** se limpia todo — el buscador vuelve a vacío, "Transferencia" vuelve a "Todas las formas", el centro vuelve a "Todos los centros" y el contador salta de 2 a 19. El usuario pierde en un clic el filtrado que venía armando.

**Causa raíz:** ese botón llama a `clearFilters()` (`frontend/app/(dashboard)/gastos/page.tsx`, dentro del `PopoverContent` de "Filtrar fechas"), que es el limpiador **global** del hook `useExpenses`, no un limpiador del rango. `/compras`, que usa el mismo popover, directamente no expone ese botón.

**Captura:** `compras-gastos-h3-limpiar-filtro.png`.

---

## H14 — [MEDIO] La cuenta corriente del proveedor nunca dice de qué proveedor es

**Dónde:** `/proveedores/{id}/cuenta`. **Viewport:** ambos. **Reproducido 2 veces.**

**Qué se esperaba:** que el encabezado nombre al proveedor, como hace la pantalla equivalente de cliente, que titula con el nombre y el email debajo.

**Qué pasa:** el encabezado dice sólo "Cuenta corriente / Saldo y movimientos del proveedor". **En ningún lugar de la página aparece el nombre** (verificado sobre el `innerText` completo: cero ocurrencias). Con 6 proveedores en el listado no hay forma de confirmar en qué cuenta estás parado antes de apretar **"Registrar pago"**, ni de saberlo si volvés por el historial del navegador o por un enlace guardado.

**Capturas:** `compras-gastos-h7-cuenta-prov-sin-nombre.png` · `cliente-cuenta.png` (el contraejemplo correcto, del lado cliente).

---

## H15 — [MEDIO] Los diálogos de ajuste y de alta de cuenta reabren con el borrador descartado

**Dónde:** `/caja` y `/banco` — `components/ledger/LedgerAdjustmentDialog.tsx` y `components/bank-accounts/BankAccountFormDialog.tsx`. **Viewport:** ambos. **Reproducido 2 veces.**

**Pasos (A):** "Registrar ajuste" → marcar "Faltante (−)", importe 55555, motivo largo → **Escape para descartar** → volver a abrir.
**Pasos (B):** "+ Banco" → nombre y saldo inicial → **Cancelar** → abrir "+ Billetera virtual".

**Qué se esperaba:** formulario limpio al reabrir; y en (B), un formulario de billetera sin los datos que se tipearon para un banco.

**Qué pasa:** (A) el diálogo reaparece con el importe, el motivo completo y "Faltante" todavía marcado — **a un clic de "Confirmar ajuste", que el propio diálogo advierte que es irreversible**. (B) "Nueva billetera virtual" abre con el nombre y el saldo del banco; si antes se había intentado enviar vacío, además arrastra el error "El nombre es obligatorio" sobre un campo que el usuario nunca tocó.

**Causa raíz:** en ambos componentes `react-hook-form` sólo llama a `reset()` dentro del `onSubmit` exitoso (`BankAccountFormDialog.tsx:82`); no hay `reset` al cerrar ni al cambiar de `kind`.

**Captura:** `finanzas-ajuste-estado-sucio.png` · `finanzas-alta-cuenta-estado-sucio.png`.

---

## H16 — [MEDIO] Los gráficos de los 3 reportes no tienen leyenda y repiten colores entre series

**Dónde:** `/reportes/formas-pago`, `/reportes/centros-costo` y `/reportes/sucursal`. **Viewport:** ambos. **Reproducido 2 veces.**

**Qué pasa:** no hay leyenda en ninguno de los tres (`.recharts-legend-wrapper === null`). La primera serie se pinta con un color distinto por fila, y esa paleta **incluye exactamente el color fijo de otra serie**: en "Efectivo", Vendido y Comprado son el mismo azul `#60a5fa`; en "Tarjeta", Vendido y Gastado son dos rojos casi iguales. En `/reportes/centros-costo` pasa lo mismo en "Logística" (Gastos y Compras, ambos azules).

**Agravante:** en móvil la tabla oculta las columnas Comprado/Gastado/Operaciones (ver H23), así que el gráfico es la **única** vía de leer esos números.

**Causa raíz:** `<Bar dataKey="Vendido">` usa `<Cell fill={COLORS[i % COLORS.length]}>` y `COLORS[1] === '#60a5fa' === ` el `fill` fijo de `<Bar dataKey="Comprado">`. Mismo patrón en `centros-costo/page.tsx:128-133` y `sucursal/page.tsx:159-164` (`COLORS[4]='#f87171'` colisiona con el fill de Gastos).

**Captura:** `finanzas-formaspago-grafico.png` · `finanzas-centros-mobile.png`.

---

## H17 — [MEDIO] El breadcrumb dice "ALIADATA" en 11 de 24 rutas

**Dónde:** barra superior del dashboard (`frontend/components/dashboard/breadcrumb-nav.tsx`). **Viewport:** ambos. **Reproducido 2 veces.**

**Qué pasa:** en `/ventas/pos`, `/caja`, `/banco`, `/sucursales`, `/reportes/formas-pago`, `/reportes/centros-costo`, `/rentabilidad`, `/planes`, `/facturacion`, `/exportaciones` y `/configuracion/fiscal` el breadcrumb dice sólo "ALIADATA". **En móvil, con el menú cerrado, ese breadcrumb es lo único que indica dónde estás**: el usuario navega y la barra superior no cambia. Afecta a rutas de uso diario (Caja y Banco son entradas del menú principal).

**Causa raíz:** el mapa `PAGE_NAMES` de `breadcrumb-nav.tsx:21-42` no las cubre y cae al literal "ALIADATA". El dato existe: el `<h1>` de cada una de esas páginas sí trae el nombre correcto.

**Captura:** `nucleo-breadcrumb-generico-caja.png`.

---

## H18 — [MEDIO] Objetivos táctiles por debajo del mínimo en móvil

> Dos reportes distintos, mismo problema de fondo.

**Dónde:** `/banco?tab=conciliacion` (checkbox de línea del extracto), el panel de historial de `/caja` y `/banco` (píldoras de filtro), la barra superior (botón de menú), `/sucursales` (Ver stock / Cerrar / Desactivar) y `/configuracion` (las 8 pestañas y las acciones de fila de Centros de costo y Formas de pago). **Viewport:** móvil. **Reproducido 2 veces.**

**Qué pasa:** el checkbox de conciliación mide **16x16 px** dentro de una fila de 78 px de alto que **no es clickeable**: sólo se marca si el tap cae exactamente en el centro (en el primer intento el tap no lo marcó). El botón de menú del encabezado y los botones de editar/desactivar de las filas miden **28x28 px**; las 8 pestañas de Configuración, 28 px de alto; el buscador y el select del historial, 28 px; las píldoras de filtro, 26 px. El mínimo recomendado es ~44x44 px (y WCAG 2.5.8 pide 24 px como piso duro).

Son tocables, pero requieren puntería: el usuario falla y toca la fila o la pestaña de al lado. Es el tipo de fricción que se acumula en un teléfono real.

**Qué tocar:** área de toque ampliada en los botones de ícono, y hacer clickeable la fila entera en el tablero de conciliación (hoy sólo el `<Checkbox>` tiene `onCheckedChange`).

**Contraste positivo:** la grilla de 7 formas de pago del POS **sí** respeta el mínimo (46 px de alto los 7 botones). El patrón correcto existe en el proyecto.

**Capturas:** `finanzas-concil-mobile-checkbox.png` · `nucleo-cfg-mob-centros-costo.png`.

---

## H19 — [MEDIO] El menú lateral móvil no se cierra con Escape y no tiene botón de cerrar

**Dónde:** drawer del sidebar en móvil (`frontend/components/ui/sidebar.tsx:204-220`). **Viewport:** móvil. **Reproducido 2 veces.**

**Qué pasa:** después de abrir el menú y presionar Escape, el menú **sigue abierto**, con el foco adentro del propio panel (verificado: `document.activeElement` está dentro del sheet, o sea Radix debería estar escuchando). Tampoco hay una "X" visible: el sheet la esconde por CSS (`[&>button]:hidden`, línea 210). Quedan sólo dos salidas: tocar la zona oscurecida o tocar un ítem y navegar. **Un usuario que abrió el menú por accidente y aprieta Escape (o busca la X) no encuentra cómo volver.**

Llamativo porque **todos los demás diálogos de la app sí cierran por las tres vías** — se verificó uno por uno.

**Captura:** `nucleo-sidebar-escape-no-cierra.png`.

---

## H20 — [BAJO] En /planes el CTA del plan vigente está habilitado y dispara el cobro

**Dónde:** `/planes`, tarjeta rotulada "Plan actual". **Viewport:** ambos. **Reproducido 2 veces.**

**Qué pasa:** la página anuncia "Actualmente estás en el plan Pro" y la tarjeta lleva el rótulo "Plan actual", pero su único botón es **"Suscribirme a Pro" habilitado**, y al tocarlo arranca el alta de suscripción del plan que ya está vigente (`POST /payments/subscriptions`). **En una cuenta real eso es un camino directo a pagar dos veces el mismo plan.** En la misma pantalla el botón del plan Gratis sí viene deshabilitado ("Cancelar y bajar a Gratis"), o sea el patrón existe y no se aplicó al plan vigente.

Se deja en severidad baja porque el backend tiene la última palabra sobre el alta duplicada — pero **no verificamos que la rechace**, así que vale confirmarlo.

**Capturas:** `nucleo-planes-mob-full.png` · `nucleo-planes-tras-suscribir.png`.

---

## H21 — [BAJO] Errores del servidor crudos en pantalla

> Cuatro apariciones del mismo criterio faltante: el `detail` del backend se muestra tal cual al microemprendedor.

- **`/productos`** → borrar un producto con stock: *"RN-B4: el producto \"QAT676743\" tiene stock (6.0000) — ajustá el stock a 0 antes de borrarlo"*. Le expone un identificador interno de regla de negocio y un número con 4 decimales. *(Aclaración: en una primera pasada se creyó que el borrado fallaba en silencio; instrumentando con muestreo cada 200 ms se confirmó que el aviso sí aparece, a los ~271 ms. **No es una falla silenciosa**, y el guard funciona bien: el producto sin stock sí se borra.)*
- **`/banco?tab=conciliacion`** → "Conciliar selección" con sumas que no cierran: *"amounts_mismatch: Σ líneas (420000.00) ≠ Σ movimientos (-64000.00)"*. **Agravante propio:** el botón está **habilitado** aunque la pantalla ya está avisando "Las sumas no coinciden" justo al lado; el `disabled` sólo mira la cantidad de ítems seleccionados. El guard del servidor sí funciona (422, no se creó el match).
- **`/banco`** → "Nueva conciliación" con período invertido: *"periodo_invalido: period_from debe ser <= period_to"*.
- **`/planes`** → cuando el alta de suscripción falla, el usuario ve *"Error interno del servidor"* aunque el backend explicó el motivo: el 503 del backend cae al fallback `/api/billing/preferences`, esa ruta responde 500 genérico (`frontend/app/api/billing/preferences/route.ts`) y el detalle se pierde. El botón queda habilitado y sin estado de carga, así que invita a reintentar en loop. *(El 503 en sí es la palanca de suscripciones apagada en local; lo que se reporta es el manejo del error.)*

**Capturas:** `catalogo-409-con-stock-espera-error.png` · `finanzas-concil-mismatch.png` · `finanzas-nueva-concil-invertido.png` · `nucleo-planes-tras-suscribir.png`.

---

## H22 — [BAJO] Cuenta corriente de proveedor sin movimientos = banner rojo de error

**Dónde:** `/proveedores/{id}/cuenta` de un proveedor que nunca tuvo una compra a crédito. **Viewport:** ambos.

**Qué pasa:** banner rojo destructivo *"Cuenta corriente no encontrada para este proveedor"* y, justo debajo, la tarjeta normal "Saldo a pagar $0,00 — Sin deuda pendiente" con "Sin movimientos registrados". **La página se contradice**: dice que hubo un error y a la vez muestra el dato correcto. El `GET .../cuenta` responde 404 porque la fila en `supplier_accounts` la crea recién la primera compra a crédito; el 404 se pinta como error de la query en vez de tratarse como "sin cuenta aún". El formulario de compra, con el mismo 404, **sí** lo degrada bien a "Saldo actual: $0".

**Captura:** `compras-gastos-h8-cuenta-prov-error-falso.png`.

---

## H23 — [BAJO] /reportes/formas-pago oculta 3 columnas en móvil

**Dónde:** `/reportes/formas-pago` → tabla "Detalle por forma de pago". **Viewport:** móvil.

**Qué pasa:** en móvil sólo se ven "Forma de pago" y "Vendido". **Comprado, Gastado y Operaciones no están ocultas por scroll sino por `display:none`** (`hidden sm:table-cell`, `page.tsx` L161-163, L180-182, L190-192), así que no hay gesto que las traiga — el contenedor ya tiene `overflow-x-auto`, que alcanzaría. Además la fila de cierre dice "Total del período $324.850" sin aclarar que es sólo lo vendido. Justamente "Gastado" es el dato que agrega el change de forma de pago en gastos. Severidad baja porque el gráfico de arriba sí muestra las tres series y su tooltip responde al tap.

**Captura:** `compras-gastos-h10-formas-pago-mobile.png`.

---

## H24 — [BAJO] El CSV de compras no lleva forma de pago ni proveedor

**Dónde:** `/compras` → botón "Exportar" (el client-side). **Viewport:** ambos.

**Qué pasa:** el CSV trae `Fecha; Producto; Cantidad; Costo unit.; Total; Descripción; ID Operación` — **ni forma de pago ni proveedor**, que son justamente los dos badges con los que el usuario filtra en pantalla. Quien exporta para conciliar en una planilla pierde los dos datos. Contraste: el de gastos sí lleva "Forma de pago" y el de proveedores lleva la identidad fiscal completa.

**Evidencia:** los archivos `export-compras.csv`, `export-gastos.csv` y `export-proveedores.csv` quedaron en el directorio de QA.

---

## H25 — [BAJO] Pluralizaciones mal formadas

- `/ventas` → el contador dice **"21 operaciónes"** (la tilde del singular concatenada con el sufijo del plural). Con una sola venta sí dice bien "1 operación". `frontend/components/ventas/sale-operations-list.tsx:292`. **El mismo patrón está copiado** en `frontend/components/compras/purchase-operations-list.tsx:222`.
- `/clientes` → el subtítulo dice **"1 clientes registrados"**. Llamativo porque el contador de la barra de filtros, justo al lado, sí resuelve bien ("1 cliente") y el pie de la tabla también ("1–1 de 1 clientes"): **tres criterios de pluralización distintos conviviendo en la misma pantalla**.

**Capturas:** `ventas-mobile-lista.png` · `catalogo-cliente-fiscal-lista.png`.

---

## H26 — [BAJO] El cierre de caja imprime "$-37.200,00"

**Dónde:** `/caja` → "Cerrar caja" → campo "Diferencia (previa)". **Viewport:** ambos.

**Qué pasa:** con un esperado de $38.200 y un contado de $1.000, muestra **"$-37.200,00"** (el signo adentro del importe) en vez de "-$ 37.200,00", que es el formato que usa el resto de la app — incluido el "Historial de sesiones" de esa misma pantalla, que sí imprime "Dif: -$ 25.854,33". El prefijo condicional sólo agrega "+" cuando es positivo, y para el negativo queda el "$" pegado al menos que ya trae `toLocaleString`.

**Captura:** `finanzas-cerrar-caja-preview.png`.

---

## H27 — [BAJO] El KPI "Margen por Canal" se corta sin tooltip

**Dónde:** `/dashboard`, segunda tarjeta de KPIs. **Viewport:** ambos.

**Qué pasa:** muestra "Feria 46% / S/C …" cuando el valor real es "Feria 46% / S/C 45%": **el segundo porcentaje, que es justamente el que permite comparar los dos canales, nunca se ve**. No hay `title`, ni `aria-label`, ni tooltip (`scrollWidth=180` vs `clientWidth=168`, con `text-overflow:ellipsis`). En móvil el recorte es mayor (`clientWidth=139`).

**Captura:** `nucleo-kpi-truncado.png`.

---

# 3) Lo que funciona bien

Esto también es información, y en esta corrida es la mayor parte del sistema. **La lógica de negocio y el circuito de la plata están sólidos**; lo que falla es casi todo presentación, texto y responsive.

### Ventas y POS
- **El POS funciona de punta a punta en escritorio Y en móvil**: armar carrito, editar cantidad y subtotal, quitar ítem y cobrar. Verificado en la base: la venta quedó en `sales` con su `operation_id` y generó su movimiento en `cash_movements`.
- El **guard de cuenta corriente del POS** funciona: al elegir "Cuenta corriente" sin cliente aparece "Elegí un cliente…" y "Cobrar" queda deshabilitado (verificado con `isDisabled()`, no a ojo).
- El chip de caja abierta y el override de cuenta bancaria del POS funcionan; el modal lista las 3 cuentas y cierra con Escape y con clic afuera.
- **Edición de una venta**: prefillea todo el contexto (cliente, moneda, fecha, sucursal, forma de pago, los 2 ítems con cantidad y precio), guarda y el listado se refresca solo.
- **Borrado**: el diálogo es correcto, cierra con Escape y con Cancelar, **no** cierra con clic afuera (correcto, es destructivo) y al confirmar borra de verdad.
- **Paginación server-side real**: al pasar de 25 a 10 la app pide `page=0&page_size=10`, el backend devuelve `{total:21, pages:3}` y la página 2 trae otras 10 filas.
- Filtros del listado: búsqueda en página, popover de rango de fechas con badge y "Limpiar filtro", filtro por las 8 formas de pago. Idéntico en móvil.
- Adentro del formulario de venta, el scroll táctil de los campos y del carrito **sí** funciona (13 `touchmove`, 0 cancelados) y "Confirmar venta" nunca queda tapado.
- El alta inline de cliente abre dentro del mismo panel, sin generar un modal anidado.

### Compras, Gastos y Proveedores
- **El impacto del gasto en caja y en banco se refleja sin recargar**: un gasto en efectivo de $777 bajó el saldo esperado de $89.315,44 a $88.538,44 navegando por el sidebar, y el borrado generó su reversa correctamente.
- **El opt-in de caja del gasto se comporta exactamente como está especificado**: pre-marcado con Efectivo, nombra la sesión, y al cambiar a una sucursal sin caja abierta lo reemplaza por la nota correcta. Destildado, el gasto se crea con 0 movimientos (verificado en DB).
- El selector de cuenta bancaria es condicional y correcto, y frena en cliente si falta la cuenta.
- Los **bloqueos de edición** llegan con el motivo exacto y diferenciado por causa ("…ya descontó de la caja", "…ya registró un movimiento bancario", y la variante combinada), con candado y botón deshabilitado.
- **El importador de CSV de gastos es de lo mejor que se probó**: pasos numerados, template descargable, previsualización que clasifica OK / advertencia / error fila por fila con el motivo, resumen honesto, y explica sin vueltas que lo importado queda sin forma de pago y sin impacto en caja ni banco.
- Filtros y paginación de `/gastos` server-side y consistentes, con los botones correctamente deshabilitados en los extremos.
- **El circuito de pago a proveedor está bien resuelto**: importe vacío → error inline sin disparar petición; importe mayor al saldo → 409 traducido a "El pago excede el saldo deudor con el proveedor" con el diálogo abierto; pago válido → el saldo baja y aparece en el historial al instante.
- El ABM de proveedores es parejo: validación sin cerrar el diálogo, datos fiscales opcionales, buscador, y confirmación que nombra al proveedor.
- `/compras` en escritorio está sólido: expandir, detalle de líneas, buscador, filtro por las 7 formas de pago, alta con carrito y preview del saldo, edición precargada.

### Catálogo
- **ABM de productos completo en escritorio**, con refresco sin recargar y soft delete que respeta el guard de stock.
- **Ajuste de inventario real de punta a punta**: 104 → 107, persistente tras recargar.
- **Cuenta corriente de cliente completa**: cobro de $1.000 → saldo de $11.080 a $10.080, con la fila en el historial y el diálogo cerrando solo.
- Validaciones del formulario de cliente correctas y **accionables**: *"El CUIT/DNI no es válido. Formato CUIT: 20-12345678-6 — o DNI de 7/8 dígitos"*, sin mandar la petición.
- **El stock coincide entre pantallas y con la base**: 104 en `/productos` = 104 en `/stock` = 68+20+16 en `branch_stock`. No hay discrepancia de datos.
- Filtros, orden y paginación de `/clientes` y `/stock` coherentes.

### Caja, Banco y Reportes
- El historial de movimientos filtra bien y **del lado del servidor**: Todos 18 = Ingresos 8 + Egresos 7 + Reversas 2 + Ajustes 1.
- El **ajuste de caja y el bancario** se reflejan al instante y correctos, con toast y la fila ya en el historial.
- **El importador de extracto bancario está muy bien resuelto**: encabezados irreconocibles → mensaje claro; CSV válido → preview con nombre, cantidad de líneas y rango de fechas; **reimportar el mismo archivo responde "Este extracto ya estaba importado (sin duplicar)"** — la idempotencia por hash funciona.
- **El tablero de conciliación anda**: sugerencias 1:1 con monto exacto y ±3 días, conciliar bajó pendientes 11→10 y sistema 10→9 sin recargar, y el guard de sumas del servidor rechaza el match desparejo sin crear nada.
- El scroll táctil funciona donde importa: historial de caja (0→245) y lista de pendientes de conciliación (0→213).
- Los date pickers de los reportes refetchean correctamente en ambos viewports.
- Estados vacíos y redirects correctos (`/finanzas/conciliacion`, `/sucursales/{id}/caja`).
- "Analizar con IA" maneja bien el error de la Edge Function caída (503 → toast).

### Navegación, tema y shell
- **Navegar entre módulos con el menú móvil abierto es limpio**: 6 destinos probados, el drawer se cierra solo, no queda overlay vivo, `body` recupera `pointer-events:auto`. **Ningún caso de pantalla bloqueada.**
- **Rotación portrait↔landscape sin secuelas**: con el menú abierto, al girar el drawer se cierra y aparece el sidebar fijo, sin instancias duplicadas; al volver, todo responde.
- **El cambio de tema es correcto y persistente** (cookie `ui:theme`), sobrevive a recarga dura y a navegación, en ambos viewports.
- El scroll táctil dentro del menú móvil funciona bien (contenido de 1276 px en una ventana de 572, arrastre de 0→704).
- Colapso del sidebar en escritorio con tooltips correctos y persistencia por cookie.
- Los filtros del tablero (período y sucursal) recalculan **todos** los KPIs de verdad.
- **El límite de plan de sucursales se respeta** con un mensaje claro del servidor.
- **Prácticamente todos los diálogos de la app cierran por las tres vías** (Escape, clic afuera, botón), y los destructivos correctamente **no** cierran con clic afuera. La única excepción es el menú lateral móvil (H19).

### Transversal
- **Tema oscuro correcto en todas las pantallas probadas**, en ambos viewports. Cero texto ilegible; en la medición de contraste del frente catálogo, ninguna de las 60 muestras por pantalla bajó de 3:1.
- **Consola y red limpias.** Los únicos errores son conocidos y ajenos a lo probado: el websocket de Realtime contra el CSP en dev, los 503 de las Edge Functions que no corren en local, el 400 del embed `account_members→profiles` y el 404 de `/fiscal/profile` (este tenant no tiene perfil fiscal).
- **Cero hallazgos de seguridad, tenencia, pérdida de datos o corrupción** en toda la corrida.

---

# 4) Cobertura y qué quedó sin probar

## Qué se cubrió, y cómo

**No se miraron capturas: se operó la aplicación.** En total, ~80 scripts de Playwright sobre Chromium con sesión inyectada por cookies, en 1440x900 y en 390x844 con emulación táctil real, tema claro y oscuro. Se enviaron formularios, se abrieron y cerraron todos los diálogos por sus tres vías, se desplegaron todos los selectores, se cambiaron tamaños de página verificando las peticiones al backend, y se arrastró con el dedo por CDP (`Input.dispatchTouchEvent`), que produce scroll nativo real, no eventos sintéticos.

**Mutaciones reales ejecutadas y verificadas contra Postgres:** 2 ventas cobradas por POS (1 borrada), 1 venta editada, 1 venta borrada, 6 gastos creados y 1 editado y 1 borrado, 2 compras a cuenta corriente creadas y 1 borrada, 1 pago a proveedor de $1.000, 3 proveedores borrados, 7 productos creados y varios editados/borrados, 2 importaciones de CSV, 1 ajuste de inventario (104→107), 1 cobro en cuenta corriente de cliente ($11.080→$10.080), 1 ajuste de caja (−$123,45), 1 ajuste bancario ($777,77), 1 par conciliado, 1 extracto importado, 3 cierres de caja, 1 centro de costo creado.

**Cada hallazgo se reprodujo al menos dos veces con recarga entre intentos**, y cada uno viene con una medición concreta —`scrollWidth`/`clientWidth`, `getBoundingClientRect`, `getComputedStyle`, `elementFromPoint`, `visualViewport.offsetLeft`, eventos con `defaultPrevented`, código HTTP, `pg_get_functiondef` de la RPC o el `SELECT` que lo confirma— y no con una impresión. Para los desbordes se hizo **bisección ocultando nodos** hasta aislar el elemento que fuerza el ancho mínimo, y para los más graves se aplicó el arreglo candidato **en vivo desde la consola** para comprobar que efectivamente cierra el problema.

**Se descartaron activamente falsos positivos.** Vale dejarlos anotados para que nadie los persiga:
- La búsqueda de `/productos` y `/stock` "no filtraba" → era `page.fill()` sin disparar el debounce. Con tecleo real anda perfecto.
- "El borrado de producto falla en silencio" → el aviso aparece a los 271 ms; se estaba mirando a los 4 segundos.
- "El tema no persiste" → era un artefacto del propio script, que pisaba `localStorage` en cada carga.
- "'Analizar con IA' falla en silencio" → el toast ya se había autocerrado.
- "Se pierde el primer carácter al tipear en CUIT/email" → sólo ocurre tecleando a 0 ms del click (carrera con el foco); con 600 ms de espera nunca pasa.
- El importador de productos "duplica" → el CSV de prueba no traía SKU ni código de barras, que es presumiblemente lo que usa para matchear. **Queda sin verificar cuál es la semántica esperada**, por eso no se reporta.

## Un hallazgo refutado (se descarta)

**"En móvil `/stock` se corta 154 px sin scroll horizontal y `Ajustar stock`, `Importar ajuste` y la paginación son inalcanzables"** — reportado como **crítico**, **refutado en su conclusión central**.

El desborde es real y determinístico (7/7 cargas). Lo que es falso es el "inalcanzable": la medición original sólo miró `window.scrollX`, `documentElement.scrollLeft` y `body.scrollLeft`, que efectivamente quedan pinneados en 0 por el `overflow-x:hidden` del `body`. No se midió `window.visualViewport`. En la verificación, tras un arrastre horizontal `visualViewport.offsetLeft = 154` (exactamente el desborde), el contenido se pinta ahí, y con el gesto natural **se pudo tocar "Ajustar stock" (abrió el modal) y avanzar de página (las filas cambiaron)**. Control negativo: en `/dashboard`, que no desborda, el mismo arrastre deja `offsetLeft=0` → es el modelo de viewport móvil real de Chrome, no un artefacto.

El desborde en sí **no se pierde**: quedó absorbido en **H2**, donde es uno de los doce síntomas de la misma causa raíz.

## Qué quedó sin probar — honestamente

**Por limitación del entorno local (no del código):**
- **Facturación AFIP** desde el listado (botón "Facturar", `EmitInvoiceButton`, promoción a `SalesOrder`, emisión de CAE): este tenant no tiene perfil fiscal (`GET /fiscal/profile` → 404) y el flujo real exige credenciales de ARCA.
- **La ruta feliz de los "Exportar … CSV" por Edge Function**: no hay contenedor `supabase_edge_runtime` en local, así que `/functions/v1/generate-export` siempre devuelve 503. Se probó el camino de error (y ahí apareció H7), no el de éxito ni el de cuota agotada.
- **"Precio IA"**, **"Subir factura IA"** de `/compras` y el resto de las Edge Functions de IA: sin clave de OpenAI. Se vio que abren y que degradan el error, no el resultado.
- **Escáner de código de barras** (ventas y compras) y **subida de foto de perfil**: requieren cámara / archivo real y Storage.
- **Realtime de notificaciones**: el websocket está bloqueado por CSP en dev, así que no se verificó que una notificación nueva aparezca sola.
- **"Comprobante" y "Enviar por WhatsApp"** del detalle de venta: abren descarga / enlace externo y el sandbox los bloquea. Sólo se verificó que están presentes.
- **Los botones "Exportar" del frente catálogo**: no se accionaron para no reportar un falso positivo por el bloqueo de descargas del headless.
- **Impacto real en producción de H4**: en local el usuario no tiene `account_id` en `user_metadata`; se verificó por grep que **nada en el repo lo escribe nunca**, pero no se pudo comprobar el estado de los usuarios de prod.

**Por decisión deliberada (para no romper el fixture o la sesión):**
- **Cambio real de email o contraseña**, "Cerrar todas las sesiones" y "Cerrar sesión": habrían invalidado las cookies inyectadas. Sólo se verificaron las validaciones y los botones deshabilitados.
- **Bajar de plan** ("Cancelar y bajar a Gratis"): habría gateado Sucursales, Rentabilidad, Comparativo, Por Sucursal y Copiloto para el resto de la corrida.
- **Desactivar una sucursal** hasta el final: el fixture está en 3 de 3 y lo comparten varios frentes.
- **Confirmar una venta a cuenta corriente completa desde el formulario de venta** (para no dejar saldo espurio). Sí se probó el guard equivalente en el POS.
- **Cerrar una sesión de conciliación bancaria**, **"Anotar" un movimiento** y **"Deshacer" una conciliación** de punta a punta: habrían destruido la única sesión con datos, necesaria para probar el resto. Se verificaron sus diálogos y validaciones.

**Por falta de recorrido — lo que habría que cubrir en la próxima pasada:**
- **Alta de variantes de producto** completa (se abrió el diálogo, no se completó una variante).
- **Transferencia de stock entre sucursales** completa (se abrió el diálogo y lista bien las 3 sucursales con su stock; no se eligió destino ni se confirmó).
- **"Importar ajuste" de stock** con un archivo real (sólo se verificó que el diálogo abre con sus 3 pasos).
- **Edición y borrado de clientes** e **importador CSV de clientes** (se abrieron, no se completó un ciclo).
- **Pago a proveedor con Transferencia / Tarjeta / Cheque** (sólo Efectivo). *Se anota de paso, sin reportarlo por no haberlo probado: ese selector ofrece **4 métodos fijos** y no el catálogo de 7 `payment_methods` que usa el resto de la app.*
- **`/ventas/ordenes`**: devuelve 500 con cualquier pedido cargado. Es un hallazgo previo, ya documentado, del sembrado — no se volvió a reportar ni se pudo probar la pantalla.
- **Paginación "Ver más movimientos"** del historial de caja/banco: ninguna caja del fixture llega a las 30 filas de página, así que el botón nunca se renderizó.
- **El módulo Equipo**: hereda el 400 ya conocido del embed `account_members→profiles` (por eso muestra "0 / 10 usuarios" y "Creada por no registrado"). No se investigó más allá.
- **Guards de servidor** (P0422 / P0412 / P0423 / P0426 / inmutabilidad): se vieron los botones con candado y su tooltip, pero no se forzó la llamada al backend saltando la validación de cliente.
- **Concurrencia / idempotencia**: no se forzó un doble submit del POS ni dos pestañas editando el mismo registro.
- **Roles distintos de owner**: todo se probó con el owner. No se ejercitó el `NoWriteAccessBanner` ni el ocultamiento de CTA para un rol de sólo lectura.
- **Verificación contable cruzada** de lo registrado (que el ajuste de caja y el bancario hayan generado su asiento en `journal_entries` y su evento de outbox): se miró el efecto en la UI y en los saldos, no la partida doble.
- **Tablet 834x1112 como frente propio**: no era parte del pedido. Apareció igual en H2, y es peor de lo esperado — **conviene una pasada dedicada a 768–1024**.
- **Accesibilidad formal**: sólo se verificó Escape en diálogos y se revisaron los `aria-label` de los botones bloqueados. **No** se hizo un recorrido completo de tabulación ni una pasada con lector de pantalla, ni medición formal de contraste en móvil, ni zoom del navegador / tamaño de fuente aumentado, ni viewports por debajo de 390 px (donde los desbordes de H2 serían peores).

---

# 5) Estado del entorno al cerrar

- **Producción intacta.** Todo el QA corrió contra el stack local (Supabase en Docker, Next.js dev, FastAPI). No se ejecutó una sola operación contra prod.
- **Árbol de git limpio.** No se modificó código de la aplicación en ningún momento (QA de sólo lectura). Los dos archivos que el arranque de los servidores había tocado —`.claude/launch.json` y `frontend/next-env.d.ts`— quedaron revertidos, los servidores apagados y el kit de scripts con credenciales de sesión eliminado del scratchpad.
- **Los datos sembrados en la base local se dejan como están**, por decisión: son locales, no afectan a nadie y le ahorran el sembrado a la próxima corrida de QA. Lo que quedó tocado, para que quien siga sepa con qué se encuentra:
  - **Ventas:** +1 venta por POS (Arroz $2.450), −1 borrada, 1 editada sin cambiar importes.
  - **Gastos:** +6 gastos con prefijo "QA", 1 gasto histórico renombrado ("Energia electrica [QA editado]", forma de pago cambiada a Cheque).
  - **Compras:** +2 compras a cuenta corriente, −1 borrada.
  - **Proveedores:** 3 borrados con **soft delete** — "QA Proveedor Test", "Panificados El Trigal" ($8.900 de saldo) y "Distribuidora Cuyo SA" ($107.650). **Se revierten con `UPDATE suppliers SET deleted_at = NULL`.** 1 pago de $1.000 a Lácteos del Valle.
  - **Catálogo:** +7 productos de prueba (y 2 importados dos veces por el CSV), varios editados/borrados; stock de un producto 104→107.
  - **Clientes:** 1 cobro de $1.000 en cuenta corriente.
  - **Finanzas:** 1 ajuste de caja (−$123,45 en Casa Central), 1 ajuste bancario ($777,77 en Mercado Pago), 1 par conciliado en Cuenta Corriente Operativa, 1 extracto de 2 líneas importado en Mercado Pago (figura en la app como "qa-extracto.csv"; el archivo original se borró con el kit), y la caja de Godoy Cruz con 5 sesiones cerradas extra (se la dejó **con sesión abierta de $30.000**, como estaba).
  - **Configuración:** +1 centro de costo "QA Nucleo 73202". `profiles.business_name` se tocó durante las pruebas y **se restauró a NULL**.
