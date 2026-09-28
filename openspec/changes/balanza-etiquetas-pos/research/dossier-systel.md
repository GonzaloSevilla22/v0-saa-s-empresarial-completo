# Dossier — change `balanza-etiquetas-pos` (integración con balanza etiquetadora)

> **Nota de vigencia (revisión adversarial del propose, 2026-09-28).** Este archivo es la copia del brief original y se conserva sin reescribir. **La fuente vigente sobre el hardware es la tabla "Lo que dice el hardware (verificado)" de `design.md`**, que corrige afirmaciones de acá: (1) que el "Código de PLU" del archivo de la Neo "es el que va en el código de barras" (Anexo A, tabla del Formato 1) es **inferencia** — la frase es de la Nota 2 del CSV de Qendra, no del archivo de la Neo; (2) el ejemplo `2 0 0261 001363 8` ($13,63) "verificado … idéntico al de la Neo" (Anexo A, "Semántica del importe") es un **caso sintético**: su fuente no está entre las copiadas; (3) "9 campos" como forma exacta del archivo: las tres líneas del ejemplo oficial tienen 31 campos (D12); (4) la venta directa acumula artículos sólo con papel continuo (manual pág. 35). Las letras de campo de la Cuora clásica (C = cantidad en Kg o Unidades), "evitar ñ" y "no repetir descripciones" tienen su fuente en `qendra-importar-datos-automatico-rev2.txt` (págs. 7-8).

> Preparado por el orquestador el 2026-09-28 para brifear a los sub-agentes del propose. Todo lo que dice acá está VERIFICADO contra el código del repo (mapa de la sección 4) o contra los PDFs oficiales de Systel (sección 2, con número de página del manual). Lo que es recomendación del orquestador está marcado como tal (sección 5) y NO es sign-off del PO.

## 1. Pedido y decisión de dirección

- Pedido del PO (2026-09-28): *"quiero implementar integraciones con balanzas porque me lo están pidiendo para una verdulería"*. La verdulería compra una **Systel Cuora Neo Black 15 kg con mástil, ETH + WiFi** (balanza **etiquetadora** con impresor de etiquetas y ticket).
- Conclusión de la sesión cloud del PO ("Software local y integraciones (balanza/facturadora)"), pegada por el PO y adoptada como dirección: **opción A** — la balanza imprime una etiqueta con un EAN-13 de **peso variable** (prefijo 2x + código del producto + peso o importe + dígito verificador); el POS **no habla con la balanza**: sólo lee la etiqueta con el lector USB común (keyboard-wedge). La opción B (peso en vivo por serie/USB vía Web Serial o agente local) queda **fuera** — sólo valdría si la verdulería no etiquetara, y la Cuora Neo no tiene puerto serie.
- El PO agregó: *"igual haz tu propia investigación si es necesaria para dejarlo todo bien"* → se leyeron los 5 PDFs oficiales de Systel (sección 2).
- Roadmap V4 ya lo tenía anotado como **M-INT-11** (`ROADMAP_MEJORAS_ALIADATA.md:1320`, esfuerzo S): "el lector de código de barras ya está construido; sólo la balanza es gap real".

## 2. Hechos verificados sobre la Systel Cuora Neo (manual oficial `CUORA-NEO-manual_ESP.pdf`, 146 págs.)

Copia local con texto extraído: `C:\Users\Usuario\AppData\Local\Temp\claude\C--Users-Usuario-Desktop-EIE-v0-saa-s-empresarial-completo\a1b376e9-d71b-476d-836f-f45b5fc02ca0\scratchpad\systel\` (`systel-cuora-neo-manual.pdf` + `.txt`, y los otros 4 PDFs con su `.txt`).

### 2.1 Código de barras de la etiqueta (manual págs. 133-135) — EL DATO CENTRAL

- "En cada comprobante de venta, tanto ticket como etiqueta, se imprimirá un código de barras en formato **EAN-13**. Desde este acceso podrá modificar la configuración del código de barras, seleccionando entre 3 opciones posibles y determinando **el campo, la posición y la cantidad de dígitos** que requiera (**12 dígitos en total**)" + dígito verificador = 13.
- Pantalla "Formato de código de barras" (pág. 135, captura): `Código Barra: EAN13`, `Tipo: Pesable`, cuatro campos ordenados A/B/C/D, cada uno con **tipo de campo** (desplegable) y **cantidad de dígitos**; ejemplo de fábrica: **A = Número Fijo (2) = "20", B = Código (4), C = Importe (6), D = Tara (0)** → `Resultado: 20BBBBCCCCCCX`. Tipos de campo vistos en las capturas: *Número Fijo, Código, Importe, Tara* (el desplegable no está expandido; **"Peso" no aparece en el texto del manual** — hay que asumirlo configurable pero verificarlo con el equipo o una etiqueta de muestra).
- Las **tres clases** de fábrica (pág. 134):
  - **VENTA POR PESO** (artículo pesable): `2 0 P P P P I I I I I I X` — cabecera **20**, PLU de 4 dígitos (P), **importe** de 6 dígitos (I), verificador (X). "El valor por defecto de la cabecera es 20, el cual puede utilizarse para que el lector de códigos de la caja identifique dicho artículo como pesable."
  - **VENTA POR UNIDAD** (no pesable): `2 1 P P P P I I I I I I X` — cabecera **21**.
  - **VARIOS**: `2 2 A A I I I I I I I I X` — cabecera **22**, se usa cuando dos o más artículos se venden en un mismo comprobante (ticket) y no cabe el código de artículo: **no trae PLU**, sólo el importe total (8 dígitos). "Se aconseja utilizar una cabecera (2 dígitos iniciales) de números fijos diferentes para cada configuración."
- **De fábrica el valor embebido es el IMPORTE, no el peso.** Los decimales del importe dependen de la **precisión de precios de la moneda** configurada en la balanza (ABM → Monedas → "Precisión precios: coloque los decimales correspondientes", págs. 97-98): no está fijado en el manual → **el SaaS debe tratar los decimales como configurables** y verificarlos con una etiqueta real.
- Cada PLU tiene además una solapa **"Cód. barras"** (pág. 80): "Reemplazar PLU por el número" (permite que el campo Código del barcode lleve otro número que el PLU interno), "UPC / Código de barras fijo" y "Código de barras fijo" (para unitarios envasados con EAN propio).

### 2.2 Modelo de artículo (PLU) en la balanza (págs. 70-72)

- Campos: **Código** (número de PLU, lo genera el usuario en la balanza), **Código ERP** ("la identificación propia de su empresa", alfanumérico), Nombre, Descripción, **Modo de venta: Pesable / Unitario / Congelado / Escurridos**, Departamento, Grupo, Tara, Lote, Descuentos por rango, **Precios por lista de precios** (múltiples listas con vigencia desde/hasta), Ingredientes, tabla nutricional, imagen, formatos de impresión (venta directa / pre-empaque), Fechas (vencimiento = fecha de venta + margen en días).
- Capacidad: "artículos casi ilimitados en memoria" (pág. 9); la ficha comercial dice hasta 100.000.
- El comprobante (pág. 32) imprime PLU Nº, descripción, peso o cantidad, precio por kg o por unidad, total y el EAN-13.

### 2.3 Vías para cargar/sincronizar PLUs en la balanza (lo que EXISTE de verdad)

| Vía | Evidencia | Implicancia para el SaaS |
|---|---|---|
| **Pantalla táctil** (ABM → PLU's → Nuevo) | manual págs. 71-79 | Carga manual; sirve para arrancar con pocos productos. Teclado/mouse USB opcionales (pág. 64). |
| **Importación desde servidor FTP/SFTP, periódica** — Configuración → General → solapa Importación: `Dirección HOST, Puerto, Usuario, Contraseña, Formato de archivo (Systel \| MGV), Ruta del archivo Artículos, Usar SFTP`, y `Periodicidad: por minuto / intervalo / horas programadas`, opcional email de verificación | manual págs. 113, 118-119 (capturas) | **La balanza es CLIENTE FTP/SFTP: descarga sola un archivo de artículos.** Hoy el SaaS no tiene ningún servidor FTP/SFTP (Vercel + Render + Supabase). Un endpoint SFTP administrado por la plataforma es un candidato FUTURO (`balanza-sync-sftp`), no de este change. |
| **Systel Suite Neo** (PC Windows): Página web, Sincronizador, Editor de etiquetas, **Importador**; instala **PostgreSQL** local y en modo cliente-servidor las balanzas usan esa DB por **TCP 5432** ("Conectividad DB → Usar base de datos remota", manual págs. 135-136) | `systel-suite-neo-instalacion-rev1.pdf` págs. 3, 9-11, 17 | Software local del comercio; **no lo distribuye ni lo automatiza el SaaS**. El SaaS sólo puede generarle el archivo que su Importador lee. |
| **Neo Basic Tools** (PC Windows, liviano): Editor de etiquetas + **Importador** | ídem, pág. 4 | Ídem: consume un archivo. |
| **Qendra** (software de la Cuora clásica, no confirmado para la Neo): importa un **CSV `;` sin encabezados** (ver 2.4) desde una carpeta, con importación automática cada N minutos y transmisión a las balanzas | `systel-qendra-csv-interconexion.pdf` (4 págs.) | Es el único formato de importación **documentado con columnas**. Si el "formato Systel" de la Neo no aparece documentado, éste es el mejor candidato y hay que validarlo con el equipo real. |
| **"Página web de configuración y reportes"** embebida en la balanza + **VNC** para soporte | manual pág. 9, 19, 116 | Es una UI humana, no una API. No sirve para integrar. |
| Protocolo RS-232 (peso en vivo, ASCII, $02 peso $03 XOR) | `systel-protocolo-rs232-rev10.pdf` | **Sólo** para Clipse/Croma/Bumer/Maya; la Cuora Neo no lo tiene. Opción B descartada. |
| Systel ONE (cloud de Systel sobre Odoo) | web (sub-agente de research) | Sin API pública para terceros. Fuera. |

Precedentes verificados por el sub-agente de research: Odoo conecta las Systel vía PosBox (Raspberry local, USB); AutoCaja (POS cloud AR) exige instalar un "driver"/paquete Systel local. **Nadie habla con la balanza desde el navegador.** Confirma la opción A.

### 2.4 Formato CSV de Qendra (documentado, `;`, sin encabezados)

```
Sección;Código PLU;Descripción;Número de PLU;Precio lista 1;Precio lista 2;Tipo de venta;Vencimiento;Ingredientes
Verduleria;509;Lechuga;509;2,50;0,00;P;0;;
```
- Sección: alfanumérico ≤ 18 chars. **Código PLU**: numérico 1–99.997 ("es el que se imprimirá en el código de barras"). Descripción: ≤ 18 chars. **Número de PLU**: 1–4.000 (posición interna; Systel recomienda usar el mismo número que el código). Precio lista 1/2: decimal con la coma regional, sin símbolo. Tipo de venta: `u`/`unidad` o `p`/`peso` (no sensible a mayúsculas). Vencimiento: días 1–9999 (0 = sin). Ingredientes ≤ 100.
- **Nota 1 (charset)**: los equipos Cuora sólo soportan `` !"#$%&´()*+,-./0-9:;<=>?@A-Z[\]º_`a-z{|}ñÑ`` → **sin tildes** (hay que transliterar "Zanahoria orgánica" → "Zanahoria organica") y **jamás `;` dentro de un campo**.
- Formato "Systel" de la Neo / formato "MGV" (Toledo): **pendiente** — un sub-agente de research lo está buscando; ver anexo A al final de este dossier cuando exista. Si no se documenta, el change adopta el CSV de Qendra como formato v1 con OQ para validarlo contra el equipo real.

## 3. Lo que YA EXISTE en el repo (verificado por el sub-agente Explore, 2026-09-28)

- **Lector de código de barras (keyboard-wedge)**: `frontend/hooks/use-barcode-scanner.ts` (123 líneas; ráfaga < 50 ms por tecla, terminador Enter/Tab, auto-flush a 4× el umbral, `capture: true` a nivel `document`, no intercepta tipeo humano) + badge `frontend/components/shared/barcode-scanner-input.tsx` (estados idle/success/error; el estado `error` **nunca se dispara** hoy: `onScan` no devuelve resultado). Consumidores: `components/forms/sale-form.tsx:11,355-366,1059`, `components/forms/purchase-form.tsx:12,985`, `components/forms/product-form.tsx:12`. **`frontend/app/(dashboard)/ventas/pos/page.tsx` (1034 líneas) NO lo importa** — alta al carrito sólo por `ProductPicker` (`components/shared/product-picker.tsx`, combobox `Command` que filtra por nombre/SKU/barcode en `searchKey`, línea 99).
- **Utilería EAN**: `frontend/lib/barcode-utils.ts` — `validateEAN13`, `validateUPCA`, `validateEAN8`, `detectBarcodeFormat`, `normalizeBarcode`, `generateEAN13`. **No hay parser de peso variable.** No existe el concepto **PLU** en ningún lado (`grep -i plu` → 0 en frontend/backend/supabase/openspec).
- **Búsqueda por barcode**: 100 % client-side (`products.find(p => p.barcode?.toUpperCase() === code)` en sale-form 355-366 y purchase-form 985). En backend `ProductRepository.search_by_barcode` (`backend/repositories/product_repository.py:294-300`, sobre `v_products_with_stock`) y `search_by_sku` (:285) existen pero **no están cableados a ningún endpoint** (sólo tests).
- **Producto**: `frontend/lib/types.ts:361-410` (`barcode?` 389, `sku?` 391 único por cuenta case-insensitive, `baseUnitId?` 403, `categoryId` 375, `cost` nullable 383, `price` 384, `parentId/isVariant`, `stockControlType` 409). Backend: `backend/schemas/products.py:35,65,90,169`; `backend/services/products.py` (`normalize_sku` 34, `_translate_unique_violation` 43 con `_BARCODE_UNIQUE_INDEX` 31, `_resolve_base_unit_for_account` 79, `_guard_base_unit_change` 140, `create_product` 175, `update_product` 229 con tri-estado `model_fields_set`, `import_products` 325); router `backend/routers/products.py` (GET "", PATCH /bulk-category, POST /import, GET /{id}, POST "", PUT /{id}, DELETE /{id} — **sin lookup por barcode**). Unicidad de barcode por cuenta: `supabase/migrations/20261031000001_products_barcode_account_scope.sql:84-91` (`idx_products_barcode_account_unique ON products(account_id, barcode) WHERE barcode IS NOT NULL AND barcode <> '' AND deleted_at IS NULL`) — **molde exacto para el índice del PLU**.
- **Unidades / kg**: `openspec/specs/units-of-measure/spec.md` (normalización única `_uom_normalize_quantity` para todo camino que escriba stock, "El POS deja de descontar la cantidad cruda" L84; "El precio de una línea es por unidad de la línea y se guarda sin redondear" L187 y "El POS guarda el precio por gramo sin redondear y el total es exacto" L205). `products.base_unit_id` (migración `20261062000001_ventas_unidades_conversion.sql:198`), cantidades `numeric(15,4)`, `lib/unit-utils.ts` (`unitInputStep/unitInputMin` 47-61, `convertUnitPrice` 115, `compatibleUnits` 158), `lib/cart-utils.ts` (`calcSaleSubtotal` 63, `unitPriceFromSubtotal` 81 — **el subtotal es editable y recalcula el precio unitario: sirve para "cobrar exactamente el importe de la etiqueta"**). Reglas KB 05 L147 (a)-(h): un producto sin unidad base admite líneas en unidades base (Kilogramo es base, factor 1); la base efectiva no se cambia bajo stock (`P0409 base_unit_locked`); una variante hereda la base del padre. Con `ventas-unidades-conversion` (PR #584) 45 productos de prod ya quedaron con Kilogramo.
- **POS** (`ventas/pos/page.tsx`): `handleProductChange` L344 precarga unidad base y mínimo; `NumericInput` L900-906 con `step/min` por unidad (**sí acepta decimales**); selector de unidad compatible L911-943; `handleSubmit` L474 → `useQuickSale` (`hooks/data/use-sales-orders.ts:301-325`) → `POST /sales-orders/quick-sale` → `backend/routers/sales_orders.py:60` → `services/sales_orders.py:75` → `repositories/sales_order_repository.py:84-108` → `rpc_quick_sale` → `_c29_confirm_order_core`. **Ningún RPC/servicio necesita cambiar**: el barcode sólo alimenta `quantity`/`unitId`/`unitPrice`/subtotal de una línea ya soportada.
- **/configuracion**: `frontend/app/(dashboard)/configuracion/page.tsx`, `TAB_VALUES` ≈ L44: `perfil, cuenta, fiscal, sistema, equipo, centros-costo, formas-pago, categorias, cobranzas, plan` (10 pestañas; `categorias` y `cobranzas` son el molde para una nueva). **No existe ningún concepto de dispositivo/hardware/integración** en la app.
- **Exportaciones**: fuente única `EXPORT_TYPES` en `supabase/functions/_shared/export-ranking.ts:29-36` (6 tipos), espejo `ExportType` en `frontend/lib/types.ts:1110-1117`, rama en `supabase/functions/generate-export/index.ts:180-183`; `export_logs` tiene CHECK de tipos (se amplió en `20261026000001` para el 6º). Importador de productos: `frontend/lib/import/validator.ts:219,239` (columna "codigo" → `barcode`), `importer.ts:98`, backend `POST /products/import` (`ProductImportRow` en `schemas/products.py:169`).
- **Sidebar**: `frontend/components/app-sidebar.tsx` `navGroups` L60+; "Operaciones" tiene `{ title: "POS — Venta Rápida", href: "/ventas/pos", icon: Scan }` L72.
- Migración más reciente en `main`: `20261065000001_unidades_decisiones_8_9.sql` (312 en prod) → **la de este change es `20261066000001_balanza_etiquetas_pos.sql`** (renumerar si otro PR la toma primero).
- `openspec list` → **vacío** (ningún change activo). Rama base: `main` en `1181071e`.

## 4. Alcance recomendado por el orquestador (NO es sign-off del PO — el propose lo convierte en decisiones + OQs)

**Nombre**: `balanza-etiquetas-pos`. **Governance**: MEDIA (lógica de negocio del mostrador y del formulario de venta; sin caminos de dinero nuevos; ninguna RPC de venta cambia). Tramo LOW: columna de producto, tabla de configuración, exportación.

**Superficie frontend obligatoria (regla PO 2026-08-02)**: (1) `/configuracion` → pestaña nueva **"Balanza"** (11ª); (2) `/ventas/pos` gana el lector y el badge; (3) formulario de venta (`sale-form`) entiende las etiquetas; (4) `/productos` → campo "Código de balanza (PLU)" en el formulario e importador; (5) botón "Exportar catálogo para la balanza" en la pestaña Balanza. Desktop + móvil, claro + oscuro.

### D1 — Campo `products.scale_plu` (integer, NULL, 1..999999)
- Índice único parcial por cuenta: `(account_id, scale_plu) WHERE scale_plu IS NOT NULL AND deleted_at IS NULL` (molde: `20261031000001`), `CHECK (scale_plu > 0 AND scale_plu <= 999999)`. Traducción de la unique violation a 409 legible en `_translate_unique_violation` (mismo patrón que barcode). Tri-estado en `PUT /products` por `model_fields_set` (D12 de `productos-categorias-sku`). Exponer en `ProductOut`, `Product` (types.ts), `v_products_with_stock` (**agregar al final**, como se hizo con `category_id`), formulario de producto, importador (columna opcional `plu` / `codigo_balanza`).
- Alternativas rechazadas: reutilizar `sku` (alfanumérico, libre, el comercio ya lo usa para otra cosa) o `barcode` (el EAN de la etiqueta cambia con cada pesada — no identifica al producto). El PLU es un número corto de dígitos fijos que el comercio carga en la balanza: merece campo propio. El **Código ERP** de la balanza se llena con nuestro `sku` en la exportación.

### D2 — Configuración por cuenta del formato de etiqueta
- Tabla nueva `scale_settings` (o nombre equivalente) con `account_id` PK/FK, `enabled boolean`, y los **layouts**: como mínimo el pesable y el unitario, cada uno con `prefix` (texto de 1-3 dígitos, default `20` / `21`), `plu_digits` (default 4), `value_kind` (`price` | `weight` para pesable — default **`price`** porque es la configuración de fábrica; `price` | `quantity` para unitario), `value_digits` (default 6), `value_decimals` (default **2 para importe, 3 para peso** — con OQ porque la precisión de precios de la balanza es configurable), invariante `len(prefix) + plu_digits + value_digits = 12`. Recomendación: **jsonb `layouts` validado por Pydantic v2 y Zod** (schema compartido) antes que N columnas; si el propose prefiere columnas, que lo justifique. RLS por cuenta (lectura para miembros; escritura sólo vía FastAPI con `require_account_role` owner/admin). Endpoints `GET/PUT /scale-settings` (3 capas). **No** guardar esto en `accounts` (columnas de privilegio con allow-list, gate `test_accounts_privilege_columns.sql`).
- UI: pestaña "Balanza" con switch, los campos de cada layout, una línea **"Resultado"** que espeje la de la balanza (`20BBBBCCCCCCX`), y un **probador**: pegar/escanear un código y ver PLU, valor decodificado y producto resuelto. Es lo que reemplaza a "pedirle una etiqueta de muestra al cliente": la verdulería escanea una etiqueta real y confirma.

### D3 — Decodificador puro `frontend/lib/scale-barcode.ts`
- `decodeScaleBarcode(code, settings) → ScaleScan | null`: exige 13 dígitos + `validateEAN13` (reutilizar), matchea prefijo por layout, parsea PLU (int, sin ceros a la izquierda) y valor con `value_decimals`; devuelve `{ layout: 'weight'|'unit', plu, value: { kind: 'price'|'weight'|'quantity', amount } }`. Prefijo "varios" (22) → **fuera de alcance v1** (no trae PLU): devolver `null` con motivo `multi_item_not_supported` para que la UI lo explique. TDD estricto: ejemplo de fábrica `20 0509 004500 X` (PLU 509, importe 4500 → $45,00 con 2 decimales / $4.500 con 0), peso `20 0509 01250 X` (1,250 kg), dígito verificador inválido, prefijo desconocido, PLU 0, overflow.

### D4 — Resolución compartida a línea de carrito `frontend/lib/scale-cart.ts` (reutilización antes que repetición)
- `resolveScaleScan(scan, products, units) → { product, quantity, unitId, unitPrice, subtotal } | { error }`, usada **idénticamente** por el POS y por `sale-form`:
  - `weight` → `quantity = kg`, unidad = Kilogramo (si la base del producto es Gramo, convertir con `unit-utils`); precio = precio de lista del producto por esa unidad (`convertUnitPrice`). Exige unidad base de tipo peso (o sin base: permitido por KB 05 (b) pero con advertencia).
  - `price` (fábrica) → `subtotal = importe de la etiqueta` (el cliente paga lo que dice la etiqueta), `quantity = round(importe / precio_kg, 3)` en kg, y el precio unitario de la línea se ajusta con `unitPriceFromSubtotal` para que `quantity × unitPrice = importe` exacto (spec units-of-measure L187: precio por unidad de línea sin redondear). Si el precio de la balanza y el del SaaS difieren, la cantidad derivada es aproximada — se muestra en la línea para que el cajero la vea; la exportación de PLU (D6) es lo que mantiene los precios alineados.
  - `unit` → cantidad = valor si `quantity`, o `round(importe / precio)` si `price` y divide exacto, si no 1 con subtotal = importe.
  - Errores tipados (mensaje accionable): PLU sin producto ("el PLU 509 no está asignado — asignalo en /productos"), producto padre con variantes, sin precio, sin unidad de peso.
  - Cada escaneo = **una línea nueva** (cada etiqueta es una pesada distinta; anular una es trivial). OQ para el PO si prefiere acumular.

### D5 — POS con lector
- Montar `BarcodeScannerInput` + el resolver en `ventas/pos/page.tsx`; un escaneo que no es de balanza cae al lookup por `barcode` exacto (hoy inexistente en el POS — se suma gratis) y después por SKU; badge `error` cableado de verdad (hoy nunca se dispara). Desactivar el listener mientras un diálogo modal está abierto (cobro) para no inyectar en sus inputs.
- `sale-form.tsx`: `handleBarcodeScan` prueba primero el decodificador de balanza (si `enabled`) y sólo después el barcode plano — **misma función compartida**.

### D6 — Exportación del catálogo para la balanza
- Archivo generado **en el navegador** desde `lib/scale-export.ts` (función pura testeada: filtra productos con `scale_plu`, sección = categoría, descripción ≤ 18 chars **transliterada al charset Systel y sin `;`**, precio con coma, `p`/`u` según tipo de la unidad base, vencimiento 0, Código ERP = `sku`), botón en la pestaña Balanza. Formato v1 = **el que documente el anexo A**; si no hay documentación del "formato Systel" de la Neo, el CSV de Qendra (2.4) con OQ de validación contra el equipo. Alternativa (OQ): 7º `ExportType` en la Edge Function `generate-export` con `export_logs` — más consistente con `/exportaciones` pero más pesado y con gating de plan; el orquestador recomienda cliente porque es un archivo de configuración de un dispositivo, no un reporte.

### D7 — Non-goals declarados
Hablar con la balanza (FTP/SFTP hosting, Suite Neo, DB remota por 5432, Systel ONE), peso en vivo (opción B / Web Serial / agente local), prefijo "Varios" 22, impresión de etiquetas desde el SaaS, listas de precios múltiples, tara/lote/ingredientes/nutricional en el export, backfill de PLU (0 productos lo tienen; el comercio los asigna), compras/gastos (sólo venta).

### D8 — Candidatos que deja (a CHANGES.md, no a CLAUDE.md)
`balanza-sync-sftp` (endpoint SFTP administrado para que la balanza importe sola), `balanza-varios-22` (ticket multi-artículo como línea genérica), lookup server-side por barcode/PLU (`search_by_barcode` muerto), peso en vivo para Clipse/Croma vía Web Serial.

### OQs sugeridas para el PO (con recomendación)
1. Valor embebido por defecto en el SaaS: `importe` (fábrica, sin tocar la balanza; el cliente paga la etiqueta) — recomendado — vs `peso` (el SaaS calcula con su lista; stock en kg exacto). Ambos soportados; sólo cambia el default y la guía de configuración.
2. Decimales del importe: 2 (default) vs 0 — se confirma con la primera etiqueta real en el probador; documentar en la guía.
3. Una línea por escaneo (recomendado) vs acumular cantidades por producto.
4. Exportación en el navegador (recomendado) vs 7º ExportType con `export_logs`.
5. Formato del archivo: Qendra CSV vs "formato Systel" Neo (según anexo A) — y si el comercio lo valida con Neo Basic Tools o por FTP local.
6. Columna `plu` en el importador de productos: incluir (recomendado, la verdulería carga cientos de productos por planilla) vs diferir.

## 5. Reglas duras que el propose y el apply deben respetar (resumen; el detalle vive en CLAUDE.md que los sub-agentes ya reciben)
- Superficie frontend planificada en el propose (ruta + menú + tasks) y verificada en desktop/móvil y claro/oscuro.
- Reutilización antes que repetición: extender `barcode-utils.ts`, `use-barcode-scanner.ts`, `cart-utils.ts`, `unit-utils.ts`; nada de un segundo lector ni una segunda matemática de carrito. Lo nuevo reusable nace en `lib/` y `hooks/`.
- NUNCA `any`; PascalCase en componentes; sin `as import(...)`.
- Backend 3 capas, Pydantic v2, tri-estado por `model_fields_set`; nunca `service_role`.
- Migración con nombre `20261066000001_balanza_etiquetas_pos.sql`, idempotente, con gate SQL propio en `supabase/tests/` cableado a `KPI_Validation.yml`; toda RPC nueva con gate que la ejecute (acá no hay RPC nueva: mejor).
- TDD estricto en el apply (RED → GREEN → TRIANGULATE → REFACTOR con evidencia).
- Todo commit vía rama + PR; nunca a `main`. Conventional commits; `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`.
- Editar `CLAUDE.md` sólo para reglas; candidatos y observaciones a `CHANGES.md`; correr `python scripts/ci/check_docs_sync.py --fix` si se toca `CLAUDE.md`.
- `openspec` CLI es la fuente de verdad del estado del change (`openspec new change`, `openspec status`, `openspec validate --strict`).

## Anexo A — Formato de importación "Systel" de la línea Neo (VERIFICADO, fuente oficial)

Fuente: `https://soporte.systel-global.com/downloads/Instructivos/Cuora-NEO/Formato-CSV-Systel-Suite-NEO.zip` (misma carpeta de soporte que el instructivo de instalación de Suite Neo; contiene `Systel Cuora NEO.txt` + `Systel Cuora NEO Mixto.csv`). Copia local extraída: `...\scratchpad\systel\formato-csv-neo\`. Es el formato que consume el **Importador** de Systel Suite Neo / Neo Basic Tools; que sea exactamente el mismo que la balanza baja por FTP con "Formato de archivo: Systel" es una inferencia fuerte (mismo producto, misma carpeta) que el comercio valida con el primer archivo real → **OQ-5 queda acotada a esa validación**, no al formato.

**Reglas (texto oficial resumido):** archivo `.csv`, campos separados por `;`, **sin encabezados**, codificación observada **Windows-1252** (el ejemplo trae `ó` como byte 0xF3 — el SaaS debe exportar en Windows-1252 o, más seguro, transliterar a ASCII sin tildes). El importador detecta el formato **por la cantidad de campos de cada línea** (9 = Formato 1, 26 = Formato 2, 31 = Formato 3; pueden mezclarse); los campos faltantes se toman como nulos.

**Formato 1 (9 campos) — el que exporta el SaaS:**

| # | Campo | Regla oficial | Origen en el SaaS |
|---|---|---|---|
| 1 | Nombre de sección | alfanumérico ≤ 56 | nombre de la categoría (`product_categories.name`) |
| 2 | Código de PLU | numérico, 1–sin límite (recomendable ≤ 9.999.999) — **es el que va en el código de barras** *(inferencia: la frase es de Qendra; ver la nota de vigencia)* | `products.scale_plu` |
| 3 | Nombre | alfanumérico ≤ 56 | `products.name` (transliterado, sin `;`) |
| 4 | Código ERP | alfanumérico ≤ 25 | `products.sku` (o el id corto si no hay SKU) |
| 5 | Precio Lista 1 | numérico con **2 decimales**, punto o coma indistinto, sin `$` ni separador de miles | `products.price` (por kg si pesable, por unidad si unitario) |
| 6 | Precio Lista 2 | ídem (mayorista; `0,00` si no aplica) | `0.00` |
| 7 | Tipo de venta | `unidad`/`u` o `peso`/`p`, no sensible a mayúsculas | `p` si la unidad base efectiva es de tipo peso, `u` en otro caso |
| 8 | Vencimiento (días) | 0–9999; 0 anula la impresión de vencimiento; se toma días−1 | `0` |
| 9 | Campo extra 1 | alfanumérico ≤ 2000 | vacío (o descripción del producto) |

Ejemplo oficial: `Carniceria;9002;PLU 9 campos;3;9002;75;PESO;10;Pollo de chacra;;;;;;;;;;;;;;;;;;;;;;` (la línea puede terminar con `;` vacíos hasta 31 campos: el importador la procesa igual). Con `\r\n` como fin de línea en el ejemplo oficial.

**Compatibilidad con el CSV de Qendra (Cuora clásica, sección 2.4):** mismas 9 posiciones salvo la 4ª (Qendra: "Número de PLU" 1–8000, Neo: "Código ERP") y límites más cortos (18 chars, PLU ≤ 999.999). Si el SaaS escribe `scale_plu` también en la 4ª posición cuando no hay SKU… NO: la 4ª es "Código ERP" en la Neo; para la verdulería (Neo) se exporta el formato Neo. Un selector "modelo de balanza: Cuora Neo | Cuora / Cuora Max (Qendra)" es un candidato, no v1.

**Charset (Qendra, aplica por prudencia también a la Neo):** sólo `` !"#$%&´()*+,-./0-9:;<=>?@A-Z[\]º_`a-z{|}ñÑ ``; Systel recomienda además **evitar `ñ`** en descripciones, nunca `;`, nunca valores en blanco en numéricos (poner 0), no repetir descripciones (versiones viejas), un solo separador decimal en todo el archivo.

**Semántica del importe en el código de barras (verificado por el sub-agente en el manual de la Cuora clásica, idéntico al de la Neo):** *(superado: caso sintético sin fuente adjunta, ver la nota de vigencia)* ejemplo oficial *precio/kg $4,80 × 2,840 kg = $13,63* imprime `2 0 0261 001363 8` → PLU **261**, importe **001363 = $13,63** (**2 decimales implícitos** con la precisión de moneda de fábrica). Consecuencia operativa a documentar en la guía de la pestaña Balanza: con 6 dígitos y 2 decimales el importe máximo por etiqueta es **$9.999,99** — a precios argentinos de 2026 (p. ej. 3 kg × $4.500 = $13.500) **desborda**; el comercio debe (a) bajar "Precisión precios" de la moneda a 0 decimales en la balanza, o (b) redistribuir dígitos (PLU 3 + importe 7, o cabecera de 1 dígito). Por eso el SaaS guarda `value_decimals` y `value_digits` por layout y el probador de etiquetas confirma la lectura. Letras de campo documentadas en la clásica: S (sección), P (PLU), I (importe), B (nº de balanza), **C (cantidad en kg o unidades)** → la variante "peso embebido" existe como campo *Cantidad*; su cantidad de decimales no está fijada en el manual (asumir 3 para kg y confirmar con el probador).

**MGV**: es el formato de texto de ancho fijo de Toledo do Brasil (ITENSMGV.TXT); Systel lo ofrece por interoperabilidad. No se documenta en Systel; **fuera de alcance**.

**Precedentes**: POSBerry y STEC documentan vinculación de Systel en línea de caja; Quant Retail documenta importación de catálogo por CSV/FTPS con el mismo patrón que el menú FTP de la Neo. Ningún SaaS argentino anuncia "la balanza baja los precios por FTP" — candidato diferenciador `balanza-sync-sftp` para después.
