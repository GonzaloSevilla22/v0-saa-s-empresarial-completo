> **Governance MEDIA** (lógica del mostrador: una etiqueta mal leída cobra un importe equivocado) con tramos **LOW** (columna de producto, tabla de configuración, exportación). Ningún camino de dinero ni RPC de venta cambia. **TDD estricto**: cada grupo abre con su RED (test que falla por la razón correcta) antes de escribir producción, con evidencia en la tabla del final. Todo commit vía rama + PR, nunca a `main`. Las tareas marcadas **[PO]** requieren OK explícito del PO.

## 0. Sign-off y checkpoints previos (sólo lectura)

- [ ] 0.1 **[PO]** Sign-off de OQ-1..OQ-9 (`design.md` §Open Questions). Registrar la respuesta textual en `design.md` §"Sign-off del PO" antes de escribir producción; si el PO elige una alternativa, actualizar D-correspondiente, specs y estas tareas en el mismo PR.
- [ ] 0.2 Confirmar que `20261066000001` sigue libre (`ls supabase/migrations`, PRs abiertos, `list_migrations` de prod); renumerar si no.
- [ ] 0.3 Releer de prod, INMEDIATAMENTE antes de escribir la migración: `pg_get_functiondef('public.rpc_bulk_upsert_products(jsonb, uuid)'::regprocedure)` + su `obj_description` + ACL, y `pg_get_viewdef('public.v_products_with_stock')`; compararlos (sin `\r`) contra `20261044000001` y `20261062000001` L2989. Si difieren, partir del vivo y anotar el desvío. Registrar cómo `rpc_import_products` convierte un `23505` en error de fila (define D14).
- [ ] 0.4 Confirmar en prod (SELECT) el punto de partida: 0 filas con `scale_plu` (la columna no existe), tabla `scale_settings` inexistente, cantidad de productos con unidad base de tipo peso (referencia para el humo).
- [ ] 0.5 SAFETY NET — correr y registrar el baseline de: `backend/tests` de productos (`test_products*`, import), `frontend/__tests__/components/sale-form-*.test.tsx`, `product-form-*.test.tsx`, los tests del POS, `lib/import` y `token-contrast-aa`. Un fallo preexistente se reporta, no se arregla.

## 1. DB: migración `20261066000001_balanza_etiquetas_pos.sql` + gate

- [ ] 1.1 RED — gate nuevo `supabase/tests/test_balanza_etiquetas_pos.sql` con fixtures propios (dos cuentas, owner y seller reales) y cleanup asertado: (a) `scale_plu` duplicado en la cuenta falla por `idx_products_scale_plu_account_unique`, en otra cuenta pasa, soft-deleted se reutiliza; (b) CHECK: 0 y 1.000.000 fallan; (c) `scale_plu` es la **última** columna de `v_products_with_stock`; (d) `scale_settings`: seller no inserta ni actualiza (`P0401`), owner sí, miembro de otra cuenta no ve la fila, `anon` sin privilegios, sin política de DELETE; (e) **ejecuta** `rpc_import_products` como owner (`SET LOCAL ROLE authenticated` + claims): asigna PLU, celda vacía conserva, PLU de otro producto rechaza el lote sin escritura parcial y con el error en su fila. Verlo fallar contra el esquema actual.
- [ ] 1.2 GREEN — migración idempotente: verificación defensiva de colisiones (molde `20261031000001` §1); `ADD COLUMN IF NOT EXISTS scale_plu integer`; CHECK `products_scale_plu_range` con guarda; índice único parcial `IF NOT EXISTS`; `COMMENT ON COLUMN`.
- [ ] 1.3 GREEN — `CREATE OR REPLACE VIEW v_products_with_stock` desde la definición viva de 0.3 + `p.scale_plu` al final; conservar `security_invoker`, `COMMENT`s y ACLs vivas.
- [ ] 1.4 GREEN — `scale_settings` (D3): tabla, `CHECK` de forma de `layouts`, RLS (SELECT miembros; INSERT/UPDATE `is_account_writer`), función + disparador `trg_scale_settings_guard_owner_admin` (`SECURITY DEFINER`, `P0401`, `REVOKE EXECUTE … FROM PUBLIC, anon, authenticated`), `REVOKE ALL … FROM anon`, `COMMENT`s.
- [ ] 1.5 GREEN — `CREATE OR REPLACE rpc_bulk_upsert_products` desde el cuerpo vivo de 0.3 con el ÚNICO cambio de `scale_plu` (D14: `COALESCE(NULLIF(…,'')::int, scale_plu)` en el UPDATE, valor o NULL en el INSERT) y, si 0.3 muestra que hace falta, la traducción del `23505` del índice nuevo a error de fila; conservar `COMMENT` y ACLs (revocada de `authenticated`).
- [ ] 1.6 Bloque `DO` de introspección al final (sólo catálogo): columna, CHECK, índice, última columna de la vista, tabla, RLS activa, 3 políticas, disparador, ACLs sin `anon`, la RPC contiene `scale_plu`.
- [ ] 1.7 Cablear el gate en `.github/workflows/KPI_Validation.yml` (en el orden real del workflow) y sumar `20261066000001` a la cadena de reaplicación de idempotencia; comprobar dos aplicaciones seguidas sin error y schema idéntico.
- [ ] 1.8 TRIANGULATE — siguen verdes `test_function_acl_gate.sql`, `test_products_barcode_account_scope.sql`, los gates del importador (`importador-productos-fastapi`, `importador-gate-plan`) y `test_ventas_unidades_conversion.sql`. (Coordinar el turno del stack local antes de `supabase db reset`.)

## 2. Backend: `scale_plu` en productos

- [ ] 2.1 RED — tests de schemas/service/router de productos: alta con `scale_plu`; `ge=1, le=999999` (422); tri-estado en `PUT` (ausente conserva, valor asigna, `null` desasigna — `scale_plu_provided` desde `model_fields_set`); `23505` de `idx_products_scale_plu_account_unique` → 409 con el número; 422 al asignar a un `variant_only`; `ProductOut` sin la clave deserializa (`None`).
- [ ] 2.2 GREEN — `schemas/products.py` (`ProductCreate`, `ProductUpdate`, `ProductOut`, `ProductImportRowIn`), `services/products.py` (`_SCALE_PLU_UNIQUE_INDEX` en `_translate_unique_violation`, tri-estado, guard `variant_only`), `routers/products.py` (sólo el `*_provided`, sin lógica).
- [ ] 2.3 TRIANGULATE — el import con `scale_plu` llega a la RPC (payload) y un error de fila del PLU vuelve con `row` y mensaje.

## 3. Backend: `scale_settings` (3 capas)

- [ ] 3.1 RED — `backend/tests/test_scale_settings.py`: schema con las reglas D4 (casos compartidos en `backend/tests/fixtures/scale_layout_cases.json`, el mismo archivo que usa vitest en 4.1); `GET` sin fila → defaults deshabilitados; `GET` con fila; `PUT` owner → upsert filtrado por `account_id`; `PUT` member/seller → 403 sin escribir; `PUT` inválido → 422 con formato y campo.
- [ ] 3.2 GREEN — `schemas/scale_settings.py` (Pydantic v2, defaults de fábrica en una constante), `repositories/scale_settings_repository.py` (`get`, `upsert` con `ON CONFLICT (account_id)`), `services/scale_settings.py` (`require_account_role(conn, auth, CAN_CONFIGURE)` en el PUT), `routers/scale_settings.py` y registro en la app.
- [ ] 3.3 REFACTOR + coverage: `pytest` completo del backend, coverage ≥ 87 %.

## 4. Frontend: funciones puras (TDD estricto)

- [ ] 4.1 RED → GREEN — `lib/scale-layout.ts`: tipos, esquema zod (D4), `FACTORY_SCALE_SETTINGS`, `layoutResultPattern(layout)` (`20BBBBCCCCCCX`), `maxRepresentableAmount(layout)`; test de contrato que lee `backend/tests/fixtures/scale_layout_cases.json` y coincide con pytest caso por caso.
- [ ] 4.2 RED → GREEN — `lib/scale-barcode.ts` → `decodeScaleBarcode` con la tabla completa de D5 (ejemplo oficial `2002610013638`, verificador inválido, 0 decimales, peso embebido, unidad, Varios, PLU 0, no-balanza, deshabilitada) y un caso con los campos en otro orden (código antes que la cabecera no se admite; importe antes que código sí).
- [ ] 4.3 RED → GREEN — `lib/scale-cart.ts` → `resolveScaleScan` con la tabla de D7 (importe con base kg y con base g, peso embebido, unidad con importe y con cantidad, precio desincronizado) y los cinco errores; verificar que `unitPrice × quantity` redondeado al centavo es exactamente el importe de la etiqueta en cada caso de importe.
- [ ] 4.4 RED → GREEN — `lib/scan-resolution.ts` → `resolveScan`: orden D6 (código exacto antes que balanza, con un `barcode` que empieza con `20`), SKU case-insensitive, padres excluidos, error de no encontrado, etiqueta inválida que no cae al SKU.
- [ ] 4.5 RED → GREEN — `lib/scale-export.ts` → `buildScaleCsv` con la tabla de D12: línea exacta de "Zanahoria orgánica", precio por kg desde base g, `u`/`p`, `;` en el nombre, truncados a 56/25, omitidos (sin precio, padre, PLU más largo que el campo) y avisos (nombre repetido, SKU truncado), `\r\n`, ningún carácter fuera de ASCII imprimible.
- [ ] 4.6 REFACTOR — ninguna de las cinco importa React ni `python-client`; reutilizan `validateEAN13`, `unitPriceFromSubtotal`, `calcSaleSubtotal`, `toBaseQuantity`, `convertUnitPrice`, `resolveUnit`, `unitInputStep/Min` (grep: ninguna reimplementa esa matemática).

## 5. Frontend: lector e indicador

- [ ] 5.1 RED — tests del hook: `onScan` que devuelve feedback; `scopeRef` con un diálogo modal abierto que no lo contiene → ignora; que lo contiene → lee; `restoreFocusedInput` restaura el valor de un input controlado y dispara `input`; sin la opción, `product-form` sigue recibiendo el código en su campo.
- [ ] 5.2 GREEN — extender `hooks/use-barcode-scanner.ts` (retrocompatible) y `components/shared/barcode-scanner-input.tsx` (estados `success`/`error` desde el feedback, tokens semánticos, sin `emerald-*`/`red-*`).
- [ ] 5.3 TRIANGULATE — siguen verdes los tests de `purchase-form` y `product-form`; `token-contrast-aa` verde.

## 6. Frontend: datos de configuración

- [ ] 6.1 RED → GREEN — `hooks/data/use-scale-settings.ts`: `useScaleSettings()` (GET, mapea a `ScaleSettings`, respuesta inválida → `FACTORY` deshabilitada sin romper) y `useUpdateScaleSettings()` (PUT, invalida la query); `queryKeys.scaleSettings`.
- [ ] 6.2 `lib/types.ts` y `hooks/data/use-products.ts`: `Product.scalePlu?: number | null` (mapeo de lectura y escritura con la misma regla tri-estado).

## 7. POS (`/ventas/pos`)

- [ ] 7.1 RED — tests del POS: etiqueta válida agrega una línea con el subtotal de la etiqueta; dos etiquetas del mismo PLU → dos líneas; código de barras común y SKU agregan como alta; PLU sin asignar, modo incompatible y Varios muestran el error y no agregan; stock insuficiente → mismo mensaje que el alta manual; con la hoja de cuenta bancaria abierta, mientras `submitting` y sin permiso de escritura no se agrega nada; el foco en "Cantidad" no queda con el código escrito; el payload de `quick-sale` lleva `price` y `subtotal` de la línea de balanza sin cambios de contrato.
- [ ] 7.2 GREEN — montar `BarcodeScannerInput` junto a `ProductPicker` con `resolveScan`, `restoreFocusedInput` y `scopeRef`; sin lógica de etiquetas en la página.

## 8. Formulario de venta

- [ ] 8.1 RED — tests de `sale-form`: etiqueta dentro del diálogo "Nueva venta" agrega la línea; código común conserva el +1 sobre la línea existente; diálogo anidado abierto suspende; foco en un campo no queda con el código; edición de una venta con línea de balanza conserva su subtotal.
- [ ] 8.2 GREEN — `handleBarcodeScan` delega en `resolveScan`; la rama `product` conserva el alta actual.

## 9. Configuración → pestaña "Balanza"

- [ ] 9.1 RED — tests de `components/settings/ScaleSettings.tsx`: interruptor; editor por formato con "Resultado" en vivo; errores D4 en línea y botón guardar deshabilitado; restaurar fábrica; importe máximo y aviso de desborde con un producto de $12.000/kg; probador contra la configuración en edición (0 decimales → 13.500) mostrando PLU, valor, producto y línea, y los errores de D5/D7; seller en sólo lectura con probador y exportación habilitados; guardar llama al PUT y muestra el error del backend.
- [ ] 9.2 GREEN — componente (PascalCase, tokens semánticos, sin `any`), guía con los pasos de la balanza (págs. 97-98, 134-135) y la advertencia de "Reemplazar PLU por el número" (pág. 80: si se usa, ese número es el que va en Aliadata), y `TAB_VALUES` + trigger + contenido `"balanza"` en `configuracion/page.tsx` (`?tab=balanza`).
- [ ] 9.3 RED → GREEN — botón "Exportar catálogo para la balanza": descarga `balanza-aliadata-AAAA-MM-DD.csv` con `buildScaleCsv` y muestra el resumen (exportados, omitidos con motivo, avisos); no llama a `generate-export` ni toca la cuota.

## 10. Producto: formulario e importador

- [ ] 10.1 RED → GREEN — `product-form.tsx`: campo "Código de balanza (PLU)" (numérico, opcional, oculto para `variant_only`), 409 mostrado junto al campo, aviso no bloqueante si el PLU tiene más dígitos que el campo código del formato habilitado, envío tri-estado (vaciar el campo manda `null`).
- [ ] 10.2 RED → GREEN — `lib/import/types.ts`, `parser.ts`, `validator.ts` (entero 1–999.999, duplicados en el archivo como error de fila, vacío = ausente), `importer.ts` (mapea `scale_plu`), `template.ts` (columna en las dos plantillas).
- [ ] 10.3 TRIANGULATE — el listado de `/productos` busca también por PLU exacto si el buscador ya filtra por código (sin agregar columnas a la tabla: reutilizar el `searchKey` existente).

## 11. Verificación

- [ ] 11.1 Suites completas: backend (`pytest`, coverage ≥ 87 %) y frontend (`pnpm vitest run`), `tsc --noEmit` sin errores nuevos, `token-contrast-aa` verde.
- [ ] 11.2 Pasada visual con el stack local (coordinando el turno), Playwright tipeando los códigos a ráfaga: POS (etiqueta de peso, de unidad, Varios, PLU sin asignar), formulario de venta, pestaña Balanza con el probador y la exportación, formulario e importador de producto — en **desktop y 375 px, tema claro y oscuro** (4 combinaciones). Sin desborde horizontal; indicador, errores y "Resultado" legibles.
- [ ] 11.3 Humo local de punta a punta: con la configuración de fábrica, vender por el POS `2002610013638` para un producto de $4,80/kg con PLU 261 → `sales_order_items.subtotal = 13.63`, `quantity = 2.84`, stock −2,84 kg; abrir el CSV exportado y verificar la línea byte a byte (ASCII, `;`, `\r\n`).
- [ ] 11.4 Red-team antes de abrir el PR: escritura directa de `scale_settings` por PostgREST con un seller; `scale_plu` de otra cuenta en el import; código con verificador inválido; cabecera superpuesta; nombre con `;`, comillas y emoji en la exportación; lector con el foco en cada input del POS.

## 12. Documentación

- [ ] 12.1 `CHANGES.md`: ficha del change (pedido, decisiones, migración, verificación) y candidatos que deja: `balanza-sync-sftp` (endpoint SFTP administrado para que la balanza importe sola, págs. 118-119), `balanza-varios-22`, lookup de código en el servidor (`search_by_barcode` sin endpoint), peso en vivo para Clipse/Croma vía Web Serial, selector de modelo de balanza (Qendra/MGV), configuración por sucursal, formatos 2/3 del archivo (tara, "Activo" para dar de baja PLUs de productos borrados), `generateEAN13` sin cabeceras 20–29.
- [ ] 12.2 KB: RN nueva en `knowledge-base/05_reglas_de_negocio.md` (dominio productos/ventas): "una etiqueta de balanza con importe cobra exactamente la etiqueta; la cantidad se deriva" y el orden de resolución de un escaneo; `06_funcionalidades.md` (módulo POS). No se toca `CLAUDE.md` (no hay regla nueva de agente); si se tocara, `python scripts/ci/check_docs_sync.py --fix` en el mismo PR.
- [ ] 12.3 Guía para el comercio (texto de la pestaña Balanza, versionado con el componente): configurar el código de barras y la precisión de precios en la balanza, asignar PLUs, exportar e importar con Neo Basic Tools, probar la primera etiqueta.

## 13. Post-merge (prod, sólo lectura salvo pedido explícito)

- [ ] 13.1 Verificar en prod: `MAX(version) = 20261066000001` (o el número final), columna/CHECK/índice, última columna de la vista, tabla + RLS + políticas + disparador + ACLs sin `anon`, cuerpo vivo de `rpc_bulk_upsert_products` con `scale_plu` y su `COMMENT`, 0 productos con PLU, 0 filas en `scale_settings`; y que Render desplegó (`GET /deploys`).
- [ ] 13.2 **[PO]** Humo real en la verdulería con la Cuora Neo: configurar la pestaña copiando la pantalla de la balanza, probar una etiqueta real en el probador (confirma OQ-2: decimales y qué pasa con un importe grande), importar el CSV con Neo Basic Tools (confirma OQ-5) y vender dos etiquetas por el POS.

## TDD Cycle Evidence

| Task | Test File | Layer | Safety Net | RED | GREEN | TRIANGULATE | REFACTOR |
|------|-----------|-------|------------|-----|-------|-------------|----------|
| | | | | | | | |
