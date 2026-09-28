## Context

**Pedido del PO (2026-09-28):** *"quiero implementar integraciones con balanzas porque me lo están pidiendo para una verdulería"* + *"igual haz tu propia investigación si es necesaria para dejarlo todo bien"*. Equipo: **Systel Cuora Neo Black 15 kg, mástil, ETH + Wi-Fi** (etiquetadora con impresor de ticket y de etiqueta). Dirección adoptada de la sesión cloud del PO: **opción A** — Aliadata lee la etiqueta que imprime la balanza con el lector USB común; no se conecta a la balanza.

Toda la investigación está en `research/` (dossier del orquestador + los dos archivos oficiales del formato CSV de Systel Suite Neo). Las afirmaciones sobre el hardware citan la página del manual oficial `CUORA-NEO-manual_ESP.pdf` (texto extraído verificado para este propose).

### Lo que dice el hardware (verificado)

| Hecho | Fuente |
|---|---|
| Cada ticket y etiqueta imprime un **EAN-13**; se configura "el campo, la posición y la cantidad de dígitos … (12 dígitos en total)" | manual pág. 133 |
| Tres clases de fábrica: **peso** `2 0 PPPP IIIIII X`, **unidad** `2 1 PPPP IIIIII X`, **varios** `2 2 AA IIIIIIII X` (sin PLU, ticket de varios artículos); "se aconseja utilizar una cabecera … de números fijos diferentes para cada configuración" | manual pág. 134 |
| Pantalla "Formato de código de barras": `Tipo: Pesable`, campos **A/B/C/D** con tipo (desplegable) y dígitos; fábrica `A = Número Fijo 2 "20"`, `B = Código 4`, `C = Importe 6`, `D = Tara 0`, `Resultado: 20BBBBCCCCCCX` | manual pág. 135 (captura) |
| Los decimales del precio salen de "Precisión precios" de la moneda | manual págs. 97-98 |
| Ejemplo oficial: $4,80/kg × 2,840 kg = $13,63 → `2 0 0261 001363 8` (2 decimales implícitos) | manual de la Cuora clásica, citado en el dossier Anexo A |
| El PLU tiene **Código** (lo que va al código de barras) y **Código ERP** ("propio de cada empresa"); modos de venta Pesable/Unitario | manual págs. 70-71 |
| Importación periódica desde **servidor FTP/SFTP** (la balanza es cliente), formato "Systel" o "MGV" | manual págs. 113, 118-119 |
| Formato de importación de Suite Neo: CSV `;` sin encabezados; **Formato 1 = 9 campos**; el importador detecta el formato por la cantidad de campos | `research/Systel Cuora NEO.txt` |
| El ejemplo oficial viene en Windows-1252 (`ó` = 0xF3) con fin de línea `\r\n` | `research/Systel Cuora NEO Mixto.csv` (bytes verificados) |

### Lo que ya existe en el repo (verificado en `main` `1181071e`)

- **Lector**: `frontend/hooks/use-barcode-scanner.ts` (ráfaga < 50 ms por tecla, terminador Enter/Tab, listener en `document` con `capture: true`) + indicador `components/shared/barcode-scanner-input.tsx`, cuyo estado `error` **nunca se dispara** (el `onScan` no devuelve nada) y usa colores de paleta literales (`emerald-400`, `red-400`). Consumidores: `sale-form.tsx` (L350-411 y L1059, busca `barcode` exacto y suma 1), `purchase-form.tsx`, `product-form.tsx` (modo "escanear para completar el código"). **`/ventas/pos` no lo monta**: el alta es sólo por `ProductPicker`.
- **Utilería EAN**: `lib/barcode-utils.ts` (`validateEAN13`, `generateEAN13` — que genera 12 dígitos **al azar**, así que puede producir un código que empieza con 20–29).
- **Carrito**: `lib/cart-utils.ts` (`calcSaleSubtotal`, `unitPriceFromSubtotal`, `roundUnitPrice` a 15 dígitos significativos); `lib/unit-utils.ts` (`toBaseQuantity`, `convertUnitPrice`, `resolveUnit`, `compatibleUnits`). El POS envía por línea `price` y `subtotal` (`pos/page.tsx` L528-534) y el servidor cobra `round(Σ amount × quantity, 2)` (spec `units-of-measure`, "El precio de una línea es por unidad de la línea y se guarda sin redondear").
- **Producto**: `products.barcode` único por cuenta (`idx_products_barcode_account_unique`, migración `20261031000001`, molde del índice nuevo); `sku` único por cuenta case-insensitive; `base_unit_id` efectiva expuesta en `v_products_with_stock` (última definición `20261062000001` L2989, columnas aditivas al final). Tri-estado por `model_fields_set` en `PUT /products` (`routers/products.py` L155-164). `_translate_unique_violation` en `services/products.py` L43.
- **Importador**: parseo en el cliente (`lib/import/parser.ts`, `types.ts` con los encabezados, `validator.ts`, `template.ts`), `POST /products/import` → `rpc_import_products` → `rpc_bulk_upsert_products(jsonb, uuid)` (última redefinición: `20261044000001`; `20261046000001` la dejó intacta).
- **Configuración**: `app/(dashboard)/configuracion/page.tsx`, `TAB_VALUES` L42-45 (10 pestañas, `?tab=` ya soportado). No existe ningún concepto de dispositivo ni de integración de hardware.
- **Guard de rol en la base**: `points_of_sale_guard_default_owner_admin()` (`20261063000001` L103-146) — disparador `SECURITY DEFINER` que rechaza con `P0401` si el actor no es owner/admin, porque la RLS con `is_account_writer` habilita a los 7 roles escritores. Es el molde para `scale_settings`.
- Migración más reciente: `20261065000001` → la de este change es **`20261066000001_balanza_etiquetas_pos.sql`**. `openspec list` estaba vacío.

## Goals / Non-Goals

**Goals:**
- Que la cajera de la verdulería pase la etiqueta por el lector y la línea aparezca en el carrito del POS (y del formulario de venta) con el producto correcto y **el importe de la etiqueta**, sin tocar el mouse.
- Que el comercio configure en Aliadata el formato de etiqueta **copiando lo que ve en la pantalla de su balanza**, y lo confirme con una etiqueta real en un probador antes de vender.
- Que Aliadata sea la fuente de verdad de precios y le entregue a la balanza el archivo que su importador oficial lee.
- Una sola implementación de cada pieza (decodificador, resolución a línea, orden de resolución de un escaneo, exportación), pura y en `lib/`.
- No tocar ninguna RPC de venta, caja, banco, cuenta corriente, asiento ni fiscal.

**Non-Goals:**
- **Hablar con la balanza**: servidor FTP/SFTP administrado por la plataforma, Systel Suite Neo, base remota por TCP 5432, Systel ONE. (Candidato `balanza-sync-sftp`.)
- **Peso en vivo** (opción B): Web Serial, agente local, protocolo RS-232 — la Cuora Neo no lo tiene.
- **Ticket "Varios"** (cabecera 22): no trae PLU. Se reconoce para explicarlo, no se carga. (Candidato `balanza-varios-22`.)
- **Imprimir etiquetas** desde Aliadata.
- Listas de precios múltiples, tara, lote, ingredientes, tabla nutricional, vencimiento y "Activo" en la exportación (Formatos 2 y 3 del archivo oficial).
- Formatos de archivo MGV (Toledo) o Qendra (Cuora clásica). (Candidato: selector de modelo de balanza.)
- Backfill de PLU (0 productos lo tienen; los asigna el comercio).
- Compras y gastos (sólo venta).
- Configuración por sucursal (una balanza configurada distinto por local). (Candidato.)
- Lookup de código en el servidor (`ProductRepository.search_by_barcode` sigue sin endpoint).

## Decisions

### D1 — Opción A: leer la etiqueta, no conectarse a la balanza

La balanza ya resolvió el problema difícil (pesar, calcular el importe e imprimirlo con el PLU); el lector keyboard-wedge ya funciona en el navegador sin drivers. Conectarse a la Cuora Neo exigiría infraestructura que Aliadata no tiene (la balanza es **cliente** FTP/SFTP, págs. 118-119; Suite Neo es software Windows local con PostgreSQL) y ningún precedente relevado lo hace desde el navegador.

*Alternativas descartadas:* (b) peso en vivo por serie/Web Serial — la Cuora Neo no tiene el protocolo; sólo serviría si la verdulería no etiquetara. (c) Endpoint SFTP administrado — es la mejor forma de sincronizar precios **después** (candidato), pero es infraestructura nueva (credenciales por comercio, hosting fuera de Vercel/Render) que no hace falta para vender el primer día.

### D2 — `products.scale_plu`: un tercer código del producto, no `sku` ni `barcode`

`scale_plu integer NULL`, `CHECK (scale_plu IS NULL OR scale_plu BETWEEN 1 AND 999999)`, índice único parcial `idx_products_scale_plu_account_unique ON products (account_id, scale_plu) WHERE scale_plu IS NOT NULL AND deleted_at IS NULL` (molde exacto de `20261031000001` L84-91, con su verificación defensiva previa de colisiones). Expuesta como **última** columna de `v_products_with_stock` (`CREATE OR REPLACE VIEW` que agrega al final, mismo criterio que `category_id` y `base_unit_id`; ningún lector cambia de posición). En la API: `ProductCreate.scale_plu: int | None` (`ge=1, le=999999`), `ProductUpdate.scale_plu` **tri-estado** por `model_fields_set` (`scale_plu_provided`), `ProductOut.scale_plu: int | None = None` (default para que una base sin la migración siga deserializando). El `23505` del índice se traduce a `409` legible en `_translate_unique_violation` ("El código de balanza 509 ya lo usa otro producto de tu cuenta"). Un producto `variant_only` (padre con variantes) no admite PLU → `422` en el service (se vende a través de sus variantes).

*Por qué entero y no texto:* el PLU es numérico en la balanza ("Código de PLU: Numérico", archivo oficial) y en el código de barras se lee sin ceros a la izquierda (`0261` → 261); guardarlo como texto obligaría a normalizar ceros en cada comparación.

*Por qué tope 999.999:* el PLU tiene que caber en el campo "Código" del EAN-13; con 12 dígitos, una cabecera de al menos 1 y un valor de al menos 5, el máximo es 6 dígitos. El archivo oficial admite PLUs más grandes, pero no se podrían imprimir en la etiqueta.

*Alternativas descartadas:* reutilizar `sku` (alfanumérico, libre, el comercio ya lo usa para otra cosa y además va al "Código ERP" de la balanza) o `barcode` (el EAN de la etiqueta cambia con cada pesada; no identifica al producto).

### D3 — Configuración por cuenta en `scale_settings`, con los formatos descritos **como los muestra la balanza** (desvío del dossier)

Tabla `public.scale_settings (account_id uuid PRIMARY KEY REFERENCES accounts ON DELETE CASCADE, enabled boolean NOT NULL DEFAULT false, layouts jsonb NOT NULL, updated_at timestamptz NOT NULL DEFAULT now(), updated_by uuid NULL)`. Sin fila = balanza desactivada con los formatos de fábrica (el `GET` devuelve los defaults; el primer `PUT` inserta). `CHECK (jsonb_typeof(layouts) = 'array' AND jsonb_array_length(layouts) = 3)` como red; la validación completa vive en un **único esquema** duplicado deliberadamente en dos lenguajes (Pydantic v2 en el backend, zod en `lib/scale-layout.ts`), con un test de contrato que corre los mismos casos contra los dos.

**Desvío respecto del dossier.** El dossier proponía describir cada formato con `prefix`/`plu_digits`/`value_digits`/`value_decimals`. Se reemplaza por **una lista ordenada de hasta cuatro campos A–D** `{ field, digits, value?, decimals? }` porque la balanza **deja elegir el orden** de los campos (pág. 135: "seleccione la opción que desea ubicar en ese orden") y tiene campos que el modelo del dossier no representa (Tara con dígitos > 0, el "AA" del formato Varios). Con el modelo de campos el comercio **copia la pantalla de la balanza campo por campo** y Aliadata dibuja la misma línea "Resultado" (`20BBBBCCCCCCX`) para comparar a ojo. El costo es mínimo (el decodificador recorre los campos en vez de cortar en posiciones fijas).

```ts
type ScaleField = "fixed" | "plu" | "amount" | "weight" | "quantity" | "ignored"
interface ScaleSegment { field: ScaleField; digits: number; value?: string; decimals?: number }
interface ScaleLayout  { kind: "weighed" | "unit" | "multi"; enabled: boolean; segments: ScaleSegment[] }
interface ScaleSettings { enabled: boolean; layouts: [ScaleLayout, ScaleLayout, ScaleLayout] } // weighed, unit, multi
```

Etiquetas en la UI: "Número fijo", "Código (PLU)", "Importe", "Peso", "Cantidad", "Otro (se ignora: tara, sección, n.º de balanza)".

Valores de fábrica (manual pág. 134-135):

| Formato | A | B | C | D | Resultado |
|---|---|---|---|---|---|
| Venta por peso (`weighed`) | Número fijo 2 = `20` | Código 4 | Importe 6, 2 decimales | — (Tara 0) | `20BBBBCCCCCCX` |
| Venta por unidad (`unit`) | Número fijo 2 = `21` | Código 4 | Importe 6, 2 decimales | — | `21BBBBCCCCCCX` |
| Varios (`multi`) | Número fijo 2 = `22` | Otro 2 | Importe 8, 2 decimales | — | `22BBCCCCCCCCX` |

**RLS y escritura**: `SELECT` para miembros (`account_id IN (SELECT current_account_ids())`); `INSERT`/`UPDATE` con `is_account_writer(account_id)`; sin `DELETE`; disparador `BEFORE INSERT OR UPDATE` `trg_scale_settings_guard_owner_admin` (`SECURITY DEFINER`, cuerpo espejo de `points_of_sale_guard_default_owner_admin`, `P0401` si el actor no es owner/admin; `REVOKE EXECUTE` de `PUBLIC, anon, authenticated` para no caer en el chequeo (1) de `test_function_acl_gate.sql`); `REVOKE ALL ON scale_settings FROM anon`. El backend además exige `require_account_role(conn, auth, CAN_CONFIGURE)` (defensa en dos capas: el service da el `403` legible, la base impide el atajo por PostgREST). **No** va en `accounts` (columnas de privilegio con allow-list, gate `test_accounts_privilege_columns.sql`).

*Alternativas descartadas:* N columnas tipadas por formato (3 formatos × 4 campos × 4 atributos = 48 columnas para un dato que se lee y escribe entero); guardar en `localStorage` (la configuración es de la cuenta, no del navegador: el POS de la caja y la PC del dueño deben ver lo mismo).

### D4 — Reglas de validación de un formato (una sola definición, dos lenguajes)

Un formato **habilitado** es válido si y sólo si:
1. Tiene 1 a 4 campos con `digits` entero ≥ 0; la suma de `digits` es **exactamente 12** (un campo con 0 dígitos se ignora, como la Tara 0 de fábrica).
2. El campo **A** es `fixed`, con `value` de 1 a 3 dígitos, `value.length === digits`, y `value` **empieza con `2`**. La cabecera identifica la etiqueta (pág. 134) y el rango 20–29 del EAN-13 es de circulación restringida: una cabecera que no empiece con 2 chocaría con los códigos de productos envasados (779… en Argentina).
3. `weighed` y `unit`: exactamente un `plu` (1–6 dígitos) y exactamente un campo de valor — `weighed`: `amount` o `weight`; `unit`: `amount` o `quantity`. `multi`: sin `plu`, un `amount` (sólo se usa la cabecera).
4. `decimals` entero 0–3 en el campo de valor (defaults: importe 2, peso 3, cantidad 0).
5. Entre los formatos habilitados, **ninguna cabecera es prefijo de otra** (`20` y `2` no pueden convivir; `20` y `21` sí).

La interfaz además muestra, sin bloquear, el **importe máximo representable** del formato con importe (`(10^digits − 1) / 10^decimals` → $9.999,99 con 6 y 2) y avisa cuando algún producto con PLU tiene un precio por kg mayor que ese máximo (una etiqueta de 1 kg ya desbordaría).

### D5 — Decodificador puro `lib/scale-barcode.ts`

```ts
type ScaleDecodeResult =
  | { status: "not_scale" }                                   // balanza desactivada, no son 13 dígitos, o ninguna cabecera habilitada coincide
  | { status: "invalid"; reason: "check_digit" | "plu_zero" }
  | { status: "unsupported"; reason: "multi_item" }
  | { status: "ok"; layout: "weighed" | "unit"; plu: number;
      value: { kind: "amount" | "weight" | "quantity"; amount: number } }

decodeScaleBarcode(code: string, settings: ScaleSettings): ScaleDecodeResult
```

Algoritmo: `enabled` falso → `not_scale`; no `/^\d{13}$/` → `not_scale`; buscar el formato habilitado cuya cabecera coincide con el inicio del código (D4.5 garantiza a lo sumo uno) → ninguno: `not_scale`; `validateEAN13` (el existente, reutilizado) falso → `invalid/check_digit`; `multi` → `unsupported/multi_item`; recorrer los campos en orden acumulando la posición; PLU = `parseInt` del tramo (sin ceros a la izquierda), 0 → `invalid/plu_zero`; valor = `parseInt(tramo) / 10^decimals`.

*Desvío respecto del dossier:* devuelve una unión discriminada en vez de `null` — la pantalla necesita distinguir "no es de balanza, seguí buscando" de "es de balanza y está mal leída" para no caer en silencio a otra búsqueda con un código de balanza dañado.

Ejemplos (verificador calculado; son los casos del RED):

| Código | Configuración | Resultado |
|---|---|---|
| `2002610013638` | fábrica | `ok`, peso, PLU **261**, importe **13,63** (ejemplo oficial de Systel) |
| `2002610013639` | fábrica | `invalid/check_digit` |
| `2002610135002` | peso con importe de **0** decimales | `ok`, PLU 261, importe **13.500** |
| `2005090012504` | peso con **Peso** 6 dígitos, 3 decimales | `ok`, PLU 509, peso **1,250** kg |
| `2101000009005` | fábrica | `ok`, unidad, PLU 100, importe 9,00 |
| `2200000045003` | fábrica | `unsupported/multi_item` |
| `2000000012346` | fábrica | `invalid/plu_zero` |
| `7791234567898` (EAN de un envasado) / `ABC-12` | cualquiera | `not_scale` |
| `2002610013638` | `enabled = false` | `not_scale` |

### D6 — Orden de resolución de un escaneo: código exacto → balanza → SKU (desvío del dossier)

`lib/scan-resolution.ts` exporta `resolveScan(code, ctx)`, **la única** función que decide qué hacer con un código leído, usada por el POS y por el formulario de venta:

1. **Código de barras exacto** (`product.barcode`, case-insensitive como hoy, excluyendo padres con variantes) → `{ kind: "product" }`; cada pantalla aplica su alta vigente (suma el mínimo de la unidad base, como `sale-form` hoy).
2. **Etiqueta de balanza** (`decodeScaleBarcode`): `ok` → `resolveScaleScan` (D7); `invalid`/`unsupported` → `{ kind: "error" }` con mensaje; `not_scale` → paso 3.
3. **SKU exacto** (case-insensitive, excluyendo padres) → `{ kind: "product" }`.
4. Nada → `{ kind: "error", message: 'Código "…" no encontrado' }`.

*Por qué el código exacto va antes que la balanza (el dossier proponía lo contrario):* `generateEAN13()` — el botón "Generar EAN-13 válido" del formulario de producto — genera 12 dígitos al azar, así que ~10 % de los códigos generados empieza con 2 y ~1 % con `20`; y la balanza permite fijarle a un PLU un "Código de barras fijo" (pág. 80) que el comercio carga también en Aliadata. Si un producto **declara** ese código, es ese producto. Un código de balanza real (con importe variable) nunca coincide con un `barcode` guardado, así que el orden no le cuesta nada a las etiquetas. (Candidato aparte: que `generateEAN13` no genere cabeceras 20–29.)

### D7 — Resolución de una etiqueta a una línea: `resolveScaleScan` en `lib/scale-cart.ts`

```ts
resolveScaleScan(scan: ScaleScanOk, ctx: { products: Product[]; units: UnitOfMeasure[]; unitsById: Map<string, UnitOfMeasure> })
  : { ok: true; line: ScaleCartLine } | { ok: false; error: ScaleLineError; message: string }

type ScaleCartLine = Pick<SaleCartItem, "productId" | "productName" | "unitPrice" | "quantity" | "discount" |
                           "subtotal" | "unitId" | "unitSymbol" | "quantityBase" | "step" | "minQty">
type ScaleLineError = "plu_not_assigned" | "product_is_parent" | "product_without_price"
                    | "sale_mode_mismatch" | "quantity_below_precision"
```

Reglas (el producto se busca por `scale_plu` entre los productos vivos de la cuenta que la pantalla ya tiene en memoria):

- **Sin producto** → `plu_not_assigned`: *"El PLU 509 no está asignado a ningún producto. Asignalo en Productos → Código de balanza."*
- **Padre con variantes** → `product_is_parent`. **Precio ≤ 0** → `product_without_price`.
- **Modo de venta**: formato `weighed` exige que la unidad base **efectiva** del producto sea de tipo `weight`; formato `unit` exige que **no** lo sea. Si no → `sale_mode_mismatch`: *"La etiqueta es de venta por peso pero «Lechuga» se vende por unidad en Aliadata. Revisá el modo de venta del PLU en la balanza o la unidad del producto."* (Ver OQ-7 para el producto pesable sin unidad base.)
- La línea se expresa **en la unidad base del producto** (Kilogramo, o Gramo si esa es su base) con `toBaseQuantity`/`convertUnitPrice`, así el stock baja exactamente lo derivado.
- **Importe embebido** (fábrica): `subtotal = importe de la etiqueta` (el cliente paga lo que dice la etiqueta); `kg = round(importe / precio_por_kg, 3)`; si `kg < 0.001` → `quantity_below_precision`; cantidad = `kg` expresado en la base; `unitPrice = unitPriceFromSubtotal(importe, cantidad)`, así `unitPrice × cantidad = importe` hasta el ruido binario y el servidor cobra `round(Σ, 2) = importe` (contrato vigente de `units-of-measure`, sin cambiarlo).
- **Peso embebido**: cantidad = peso (kg) expresado en la base; `unitPrice` = precio del catálogo en esa unidad; `subtotal = calcSaleSubtotal(unitPrice, cantidad, 0)`.
- **Formato por unidad**: con `quantity` embebida → cantidad = valor, precio del catálogo; con `amount` → `cantidad = max(1, round(importe / precio))`, `subtotal = importe`, `unitPrice = unitPriceFromSubtotal`.
- `discount = 0`; `step`/`minQty` de la unidad de la línea (`unitInputStep`/`unitInputMin`), igual que un alta manual, para que la línea se pueda editar después.
- El **stock** no lo decide esta función: la pantalla aplica a `quantityBase` el mismo chequeo de stock que a un alta manual (ver OQ-9).

Ejemplos (casos del RED):

| Producto | Etiqueta | Línea |
|---|---|---|
| Tomate, base kg, $4,80/kg | `2002610013638` (importe 13,63) | 2,840 kg · $4,79929577464789/kg · subtotal **13,63** |
| Tomate, base kg, $4.500/kg | `2002610135002` con 0 decimales (importe 13.500) | 3,000 kg · $4.500/kg · subtotal 13.500 |
| Tomate, base **g**, $4,5/g | `2002610135002` con 0 decimales | 3000 g · $4,5/g · subtotal 13.500 |
| Papa, base kg, $1.800/kg | `2005090012504` con Peso 3 dec. (1,250 kg) | 1,250 kg · $1.800/kg · subtotal 2.250 |
| Lechuga, base u, $4,50 | `2101000009005` (importe 9,00) | 2 u · $4,50 · subtotal 9,00 |
| Tomate con precio $5,00/kg en Aliadata y $4,80 en la balanza | `2002610013638` | 2,726 kg · subtotal **13,63** (cobra la etiqueta; la cantidad es aproximada — por eso la exportación de D12) |

### D8 — Una línea por etiqueta; los códigos comunes conservan su comportamiento

Cada etiqueta de balanza agrega **una línea nueva**, nunca se suma a una existente: cada etiqueta es una pesada distinta con su propio importe, y anular una sola es quitar su línea. Los códigos de barras comunes y los SKU conservan lo que `sale-form` hace hoy (suman el mínimo de la unidad a la línea del mismo producto y unidad); el POS adopta ese mismo comportamiento para ellos. OQ-3.

### D9 — Lector: tres extensiones al hook y al indicador (reutilización, no un segundo lector)

- **Resultado visible**: `onScan` puede devolver `ScanFeedback | void` (`{ ok: boolean; label: string }`); `BarcodeScannerInput` muestra `success` con el nombre del producto o `error` con el motivo (hoy el error nunca se dispara). Retrocompatible con `purchase-form`/`product-form`.
- **Suspensión por diálogo**: opción `scopeRef` en el hook; con un diálogo modal abierto (`[role="dialog"][aria-modal="true"]`, el que renderizan `ResponsiveModal`/Radix) que **no contiene** al elemento del indicador, el escaneo se ignora. Cubre el POS (la hoja de cuenta bancaria o cualquier diálogo futuro suspende el lector) y el formulario de venta, que vive **dentro** del diálogo "Nueva venta" (`ventas/page.tsx` L104-113) y debe seguir leyendo — pero no si se abre un diálogo anidado. El POS además lo suspende mientras `submitting` y sin permiso de escritura.
- **Foco en un campo**: opción `restoreFocusedInput` (opt-in; la activan el POS y el formulario de venta). El lector tipea en el elemento con foco; el hook recuerda el valor del `input`/`textarea` enfocado al empezar una ráfaga y, si la ráfaga resulta ser un escaneo, lo restaura con el setter nativo + evento `input` (compatible con inputs controlados de React). Sin esto, escanear con el foco en "Cantidad" deja `2002610013638` escrito en la cantidad. El formulario de producto **no** lo activa (ahí el escaneo sí debe escribir en el campo del código).
- El indicador pasa a tokens semánticos (`success`/`destructive`/`primary`) y queda cubierto por el gate `token-contrast-aa`.

### D10 — POS y formulario de venta: misma función, alta propia de cada pantalla

- **POS** (`ventas/pos/page.tsx`): monta `BarcodeScannerInput` en la cabecera del bloque "Agregar producto" (junto a `ProductPicker`), con `onScan = resolveScan(...)`: `scale_line` → valida stock con el mismo mensaje que `handleAddToCart` (`formatStock` con el símbolo de la base) y agrega la línea; `product` → mismo alta que un código común del formulario de venta; `error` → `toast.error` + indicador en error. La configuración llega por `useScaleSettings()` (React Query, `staleTime` largo; la lee cualquier miembro).
- **Formulario de venta**: `handleBarcodeScan` pasa a delegar en `resolveScan`; el camino de código exacto conserva su alta actual (misma lógica, movida a la rama `product`).
- Ninguna de las dos pantallas calcula nada de la etiqueta por su cuenta. Compras no se tocan (Non-Goal).

### D11 — Pestaña "Balanza" en `/configuracion`

11ª pestaña (`TAB_VALUES` gana `"balanza"`, enlazable con `?tab=balanza`), componente `components/settings/ScaleSettings.tsx` con cuatro bloques:
1. **Interruptor** "Leer etiquetas de balanza en el POS y en ventas".
2. **Formatos** (peso, unidad, varios): por cada uno, habilitado + los campos A–D (tipo + dígitos + valor fijo/decimales) + la línea **"Resultado"** en monoespaciada (`20BBBBCCCCCCX`), errores de D4 en línea, y el importe máximo representable con su aviso. Botón "Restaurar valores de fábrica".
3. **Probador**: un campo de texto con su propio envío (Enter o botón "Probar") — el lector escribe ahí como en cualquier campo; el lector global **no** se monta en esta página. Muestra: formato detectado, PLU, valor decodificado con su unidad, producto resuelto y la línea que se agregaría (cantidad, precio, subtotal), o el error de D5/D7. Prueba contra la configuración **en edición** (sin guardar), para confirmar antes de guardar.
4. **Guía y exportación**: pasos para configurar la balanza (Configuración → Códigos de barra, pág. 134-135; Precisión precios, pág. 98; si en la solapa "Cód. barras" del PLU se usa "Reemplazar PLU por el número", pág. 80, ese número es el que va como código de balanza en Aliadata), la advertencia del desborde, el botón "Exportar catálogo para la balanza" con su resumen (D12) y cómo importarlo (Neo Basic Tools / Suite Neo → Importador).

Owner/admin editan; el resto de los miembros ve la configuración en sólo lectura y puede usar el probador y exportar. Estados de carga y error visibles. Desktop + 375 px, claro + oscuro, tokens semánticos.

### D12 — Exportación en el navegador, Formato 1 oficial de Systel Suite Neo

`lib/scale-export.ts` → `buildScaleCsv(products, categoriesById, units): { csv: string; included: number; skipped: ScaleExportSkip[] }`, pura; la pestaña la descarga como `balanza-aliadata-AAAA-MM-DD.csv`. Una línea por producto con `scale_plu`, **exactamente 9 campos** separados por `;`, sin encabezado, `\r\n`:

| # | Campo oficial | Valor |
|---|---|---|
| 1 | Nombre de sección (≤ 56) | nombre de la categoría (`Otros` si no tiene) |
| 2 | Código de PLU | `scale_plu` |
| 3 | Nombre (≤ 56) | nombre canónico del producto (con la variante) |
| 4 | Código ERP (≤ 25) | `sku`; vacío si no hay o si excede 25 (se informa) |
| 5 | Precio Lista 1 | precio de la unidad base re-expresado **por kg** si es de peso, por unidad si no; **2 decimales, coma decimal, sin miles ni símbolo** |
| 6 | Precio Lista 2 | `0,00` |
| 7 | Tipo de venta | `p` si la unidad base efectiva es de tipo peso; `u` si no |
| 8 | Vencimiento | `0` (no imprime vencimiento) |
| 9 | Campo extra 1 | vacío |

Texto: se **translitera a ASCII imprimible** (NFD + quitar diacríticos; `ñ`→`n`, porque Systel recomienda evitarla; `;` → `,`; controles y saltos de línea → espacio; recorte y truncado a la longitud máxima). Así el archivo es idéntico en Windows-1252 y UTF-8 y se evita elegir codificación en el navegador (que sólo codifica UTF-8 de forma nativa). Se **omiten** e informan: productos sin precio, padres con variantes, y PLUs con más dígitos que el campo Código del formato de peso/unidad habilitado (no se podrían imprimir). Se **avisan** sin omitir: nombres repetidos (Systel lo desaconseja para versiones viejas) y SKU truncado.

*Por qué en el navegador y no como 7º `ExportType` de `generate-export`:* es un archivo de configuración de un dispositivo, no un reporte; no debe consumir la cuota de exportaciones del plan ni quedar en `export_logs`; los datos ya están en memoria (`useProducts`, categorías, unidades); y no requiere ampliar el `CHECK` de `export_logs` ni la lista `EXPORT_TYPES`. OQ-4.

*Por qué Formato 1 y no 26/31 campos:* es el mínimo que el importador acepta ("los datos que faltan se toman como nulos"); tara, nutricional y "Activo" son Non-Goals. El ejemplo oficial rellena con `;` hasta 31 campos; el texto oficial dice que el formato se detecta por la cantidad de campos, así que 9 exactos es lo correcto — se confirma con el primer archivo real (OQ-5).

### D13 — Backend: 3 capas, sin lógica en el router

- `routers/scale_settings.py`: `GET /scale-settings` (cualquier miembro; devuelve la fila o los defaults) y `PUT /scale-settings` (payload completo `ScaleSettingsIn`).
- `services/scale_settings.py`: `require_account_role(conn, auth, CAN_CONFIGURE)` en el `PUT`; validación D4 en Pydantic (422 con el mensaje por campo).
- `repositories/scale_settings_repository.py`: `get(account_id)` y `upsert(account_id, enabled, layouts, user_id)` con `INSERT … ON CONFLICT (account_id) DO UPDATE`, filtrado explícito por `account_id` (regla dura de tenencia: la RLS es red, no guard).
- Productos: sólo `schemas`/`services`/`routers` existentes (D2). Ningún endpoint de venta cambia.

### D14 — Importador: columna "Código balanza" opcional

- `lib/import/types.ts`: encabezado nuevo `Código balanza` (clave `codigo_balanza`, alias aceptados `PLU` y `codigo balanza`); `validator.ts`: entero 1–999.999 (error de fila si no), vacío = ausente (spec `product-import`: la ausencia viaja como ausencia); duplicados **dentro del archivo** marcados como error de fila (mismo patrón que `flagDuplicateSkus`); `template.ts`: la columna en la plantilla y en la plantilla desde el catálogo.
- `ProductImportRowIn.scale_plu: int | None` (`ge=1, le=999999`).
- `rpc_bulk_upsert_products` se reescribe **partiendo del `pg_get_functiondef` vivo de prod** (regla del proyecto) con el único cambio de leer `v_row->>'scale_plu'`: en el `UPDATE`, `COALESCE(NULLIF(v_row->>'scale_plu','')::int, scale_plu)` (ausente conserva, igual que `barcode` hoy — el importador no desasigna); en el `INSERT`, el valor o `NULL`. Un PLU que ya usa **otro** producto del catálogo viola el índice: el lote es todo o nada (requirement vigente) y el `23505` de `idx_products_scale_plu_account_unique` se informa como **error de su fila** con el PLU (si el cuerpo vivo no traduce ya las violaciones únicas a error de fila, se agrega la traducción para este índice). Misma firma → `CREATE OR REPLACE` sin overload; se conservan `COMMENT` y ACLs vivas (revocada de `authenticated`).

### D15 — Migración, gates y verificación

- **Migración** `20261066000001_balanza_etiquetas_pos.sql`, idempotente (`ADD COLUMN IF NOT EXISTS`, CHECK e índice con guardas, `CREATE TABLE IF NOT EXISTS`, `DROP POLICY/TRIGGER IF EXISTS`), con bloque `DO` final de introspección (columna, CHECK, índice, columna al final de la vista, tabla, RLS activa, 3 políticas, disparador, ACLs sin `anon`, la RPC de upsert contiene `scale_plu`).
- **Gate SQL** `supabase/tests/test_balanza_etiquetas_pos.sql` (cableado en `KPI_Validation.yml` y sumado a la cadena de reaplicación de idempotencia): unicidad por cuenta (duplicado en la cuenta falla, otra cuenta pasa, soft-deleted se puede recrear), CHECK (0 y 1.000.000 fallan), la vista expone `scale_plu` como última columna, `scale_settings` — un `seller` no puede insertar/actualizar (`P0401`), un owner sí, un miembro de otra cuenta no ve la fila, `anon` sin privilegios —, y **ejecuta** `rpc_import_products`/`rpc_bulk_upsert_products` como un owner real (`SET LOCAL ROLE authenticated` + claims): asigna PLU, conserva el PLU cuando la celda viene vacía, y un PLU ajeno se rechaza sin escritura parcial con el error en su fila. Cleanup asertado.
- **vitest**: `scale-layout` (reglas D4 + test de contrato con los casos compartidos con pytest), `scale-barcode` (tabla de D5), `scale-cart` (tabla de D7 + los 5 errores), `scan-resolution` (orden D6, incluido un `barcode` generado que empieza con `20`), `scale-export` (tabla de D12 + transliteración + omitidos), hook (feedback, `scopeRef`, `restoreFocusedInput`), indicador, POS, formulario de venta, pestaña, formulario de producto, importador.
- **pytest**: schemas (D4 + contrato), service (guard 403 para `member`/`seller`, 422 por formato inválido), router (`GET` con y sin fila, `PUT` upsert filtrado por cuenta), productos (`scale_plu` en alta, tri-estado en edición, 409 del índice, 422 en `variant_only`, `ProductOut` sin la columna deserializa). Coverage ≥ 87 %.
- **Verificación visual** con el stack local: POS escaneando (simulado con `keyboard.type` a ráfaga en Playwright) una etiqueta de peso, una de unidad, una de Varios y un PLU sin asignar; formulario de venta; pestaña Balanza con el probador; formulario e importador de producto — en **desktop y 375 px, tema claro y oscuro**. Sin desborde horizontal; indicador y errores legibles.

### D16 — Sin gating de plan y sin cambios en ventas del servidor

La lectura de etiquetas y la exportación están disponibles en todos los planes (es lo mínimo para operar un mostrador con balanza; el pedido viene de un comercio que todavía no es cliente). `rpc_quick_sale`, `_c29_confirm_order_core`, `rpc_create_sale_operation_v2`, los ledgers y el relay fiscal no cambian: la línea que arma D7 es indistinguible de una cargada a mano con el subtotal editado, camino que ya existe y está cubierto por la spec `units-of-measure`.

## Risks / Trade-offs

- **[Desborde del importe: 6 dígitos con 2 decimales tope $9.999,99]** → la guía de la pestaña recomienda configurar la balanza con **0 decimales** en "Precisión precios" (pág. 98; tope $999.999) o redistribuir dígitos (PLU 3 + Importe 7, o cabecera de 1 dígito) y copiar eso en Aliadata; la pestaña muestra el tope y avisa cuando un precio por kg lo supera. **Qué hace la balanza al desbordar (¿trunca los dígitos altos? ¿se niega a imprimir?) no está documentado**: si trunca, una etiqueta de $13.500 podría leerse como $3.500 sin que Aliadata pueda detectarlo. Se verifica con el equipo real antes de vender (OQ-2) y queda escrito en la guía.
- **[Precios desincronizados entre la balanza y Aliadata]** → con importe embebido el cliente paga la etiqueta (correcto para el cliente) y lo que se desvía es la cantidad descontada del stock; con peso embebido Aliadata cobra su precio y el cliente ve otro en la etiqueta. La exportación (D12) es el mecanismo; la pestaña lo explica. La sincronización automática es el candidato `balanza-sync-sftp`.
- **[Charset de la balanza]** → transliteración a ASCII sin `;` en una función pura con tests (D12); el archivo no depende de la codificación.
- **[El formato del archivo nunca se probó contra un equipo]** → es el formato oficial de Systel, pero que la balanza lo baje igual por FTP con "Formato: Systel" es inferencia; se valida con el Importador de Neo Basic Tools en la primera instalación (OQ-5).
- **[Configuración mal copiada → importes equivocados]** → el probador contra la configuración en edición + la línea "Resultado" idéntica a la de la balanza + el verificador EAN (una lectura dañada nunca decodifica).
- **[Dígitos del lector escritos en el campo con foco]** → `restoreFocusedInput` (D9) con test; verificación manual con un lector real en la pasada visual si hay uno disponible (si no, simulado a ráfaga).
- **[Código generado al azar con cabecera 20–29]** → el código exacto se resuelve antes que la balanza (D6); candidato para que `generateEAN13` evite esas cabeceras.
- **[Catálogo grande en memoria]** → el POS y el formulario ya cargan `useProducts()` completo; la búsqueda por PLU es un `Map` construido una vez por render de la lista (O(1) por escaneo).
- **[Reescritura de `rpc_bulk_upsert_products`]** → partir del cuerpo vivo, diff mínimo, gate que la ejecuta; checkpoint del apply que re-lee el cuerpo inmediatamente antes de escribir.
- **[No hay balanza en el equipo de desarrollo]** → todos los códigos de prueba se generan con el verificador correcto (tabla de D5) y el probador existe justamente para que el comercio confirme con una etiqueta real; el humo real con la verdulería es post-merge (OQ-2/OQ-5).
- **[Número de migración]** → renumerar en el apply si otro PR toma `20261066000001`.

## Migration Plan

1. Merge → CI/CD aplica `20261066000001` y despliega frontend (Vercel) y backend (Render; verificar `GET /deploys`, el auto-deploy no siempre dispara).
2. Sin backfill: `scale_plu` nace `NULL` en todos los productos; `scale_settings` sin filas (todas las cuentas con la balanza desactivada). Ningún comportamiento cambia hasta que un owner/admin active la balanza — salvo que el POS gana el lector de códigos comunes y SKU, y el indicador del formulario de venta pasa a mostrar errores.
3. Verificación post-merge (sólo lectura): `MAX(version)`, columna/CHECK/índice, última columna de la vista, tabla + RLS + políticas + disparador + ACLs, cuerpo vivo de `rpc_bulk_upsert_products` con `scale_plu`, 0 productos con PLU y 0 filas en `scale_settings`.
4. **Rollback**: revertir el PR de frontend/backend es inocuo (columna y tabla quedan sin uso). La RPC de upsert se restaura re-aplicando su cuerpo anterior (archivo `20261044000001`) en una migración nueva.

## Open Questions

- **OQ-1 — Valor embebido recomendado para la verdulería.** Recomendado: **importe** (configuración de fábrica, no hay que tocar la balanza para el formato, el cliente paga exactamente la etiqueta). Alternativa: **peso** (Aliadata cobra con su lista y el stock baja el peso exacto, pero exige reconfigurar el Campo C de la balanza y el cliente puede ver en la etiqueta un precio distinto). Los dos quedan soportados; sólo cambia la guía.
- **OQ-2 — Decimales del importe y desborde.** Recomendado: default **2 decimales** (fábrica) en Aliadata, y la guía indica configurar la balanza en **0 decimales** y copiar 0 en Aliadata; el probador lo confirma con la primera etiqueta real. Pendiente de verificar con el equipo: qué imprime la balanza cuando el importe no entra en los dígitos.
- **OQ-3 — Una línea por etiqueta.** Recomendado: **sí** (D8). Alternativa: acumular las pesadas del mismo producto en una línea (pierde el importe exacto por etiqueta y complica anular una).
- **OQ-4 — Exportación en el navegador vs 7º tipo de `generate-export`.** Recomendado: **navegador** (D12), sin cuota ni `export_logs`.
- **OQ-5 — Validación del archivo con el equipo real.** Recomendado: la primera instalación importa el archivo con el **Importador de Neo Basic Tools** (o Suite Neo) y confirma nombres, precios y tipo de venta en la balanza; si el importador exigiera 31 campos, el cambio es rellenar con `;` en `buildScaleCsv` (una línea y un test).
- **OQ-6 — Columna PLU en el importador de productos.** Recomendado: **incluir** (D14): la verdulería carga cientos de productos por planilla. Alternativa: diferir y evitar tocar `rpc_bulk_upsert_products` en este change.
- **OQ-7 — Producto pesable sin unidad base.** Recomendado: **rechazar** la etiqueta con `sale_mode_mismatch` y el mensaje accionable ("asigná Kilogramo como unidad del producto"): coherente con la exportación (`p`/`u` se decide por la unidad base) y con el stock en kg. Alternativa: aceptarla como línea en Kilogramo (RN-24 (b) lo permite) con un aviso.
- **OQ-8 — Orden de resolución.** Recomendado: **código exacto → balanza → SKU** (D6). Alternativa (la del dossier): balanza primero.
- **OQ-9 — Stock insuficiente en una etiqueta.** Recomendado: **mismo bloqueo que un alta manual** (hoy el POS y el formulario rechazan la línea que supera el disponible), para no abrir una excepción de stock en este change. Alternativa: dejar pasar la etiqueta con un aviso (en una verdulería el stock en kg suele estar desfasado), que sería una decisión de negocio sobre RN-21/RN-24 y merece su propio change.
