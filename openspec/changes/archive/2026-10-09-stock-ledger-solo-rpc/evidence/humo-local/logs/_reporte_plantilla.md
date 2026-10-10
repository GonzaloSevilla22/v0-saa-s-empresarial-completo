# Humo local de `stock-ledger-solo-rpc` (pasos 14.4 y 5.4, en el stack de prueba local)

| | |
|---|---|
| Fecha | 2026-10-09 (corrida limpia final 22:10-22:14 ART; los logs llevan hora UTC) |
| Commit probado | `b57e6068` (`origin/main`: tandas A y B + archive del change) |
| Rama de la evidencia | `docs/stock-ledger-humo-local` (un commit, sin push ni PR) |
| Alcance | **Entorno local únicamente.** Prod no se tocó. No sustituye el humo del PO en prod (14.4 y 5.4 siguen abiertas). |
| Resultado | **36 de 36 sub-pasos PASS** (los 8 pasos del pedido más 3 verificaciones extra de 375 px y 5 comprobaciones extra de API e importador) |

## Cómo se levantó el stack

- **Supabase local** (CLI `2.120.0`, Docker): `supabase db reset` desde la raíz del worktree justo antes de la corrida final, que deja **321 migraciones, última `20261074000001`** (= `main`; ver `logs/00_db_reset.log` y `logs/40_estado_final_bd.log`).
- **FastAPI**: `backend/.venv` con `uvicorn backend.main:app --host 127.0.0.1 --port 8000`, con `BACKEND_ALLOWED_ORIGIN=http://localhost:3000`, `REDIS_URL` vacío, `WSFE_ADAPTER_MODE=stub` y `AUTH_ALLOW_HS256_FALLBACK=true` (mismo arranque que `E2E_Tests.yml`). Log: `logs/01_backend_uvicorn.log`.
- **Next dev**: `pnpm dev` (`next dev --turbo`) en `frontend/`, con `NEXT_PUBLIC_SUPABASE_URL` y `ANON_KEY` del Supabase local, `NEXT_PUBLIC_BACKEND_URL=http://localhost:8000` y `NEXT_PUBLIC_PLAYWRIGHT_LOCAL=true`. Log: `logs/02_next_dev.log`.
- **Playwright** (`@playwright/test` de `frontend/`, Chromium sin cabeza): 1280 px de escritorio y 375 px sólo para el modal de ajuste con motivo vacío, el formulario de producto en edición y `/stock` del seller. Tema claro.
- **Arnés**: copiado y adaptado desde `evidence/scripts/` de la tanda B (que no se tocó) a `evidence/humo-local/scripts/`. La corrida completa se reproduce con `bash scripts/run_all.sh` (con Next dev levantado por `start-next.sh`; el script hace el `db reset`, reinicia el backend, siembra, inicia sesión y corre los pasos 21 a 29). Las contraseñas de los usuarios locales salen del entorno de `env.sh` y no se transcriben acá.

**Usuarios locales** (dominio `@local.test`, sembrados por `seed.mjs`; ver `logs/03_seed.log`):

| Rol | Usuario | Uso en el humo |
|---|---|---|
| owner | `qa.e2e@local.test` | pasos 1 a 6, 8 y 9a/9b (rol con permiso de ajuste) |
| seller | `qa.seller@local.test` (miembro con rol `seller`) | paso 7 y 9c |
| stock | `qa.stock@local.test` (miembro con rol `stock`) | sólo se inició sesión; **no se ejerció** (ver Desvíos) |

**Datos sembrados** (una cuenta Pro, dos sucursales `Casa Central` y `Sucursal Norte QA`): `Tomate perita` (8), `Alfajor artesanal` (100 + 10 en la segunda sucursal), `Producto escaso QA` (1), `Aceite QA` (20), `Remera con variantes QA`, más un cliente y un proveedor de prueba. El `db reset` previo deja el libro de movimientos vacío: **todos** los movimientos del libro final salen de lo que hizo la UI o la API durante el humo.

## Resultados (generados desde `logs/10_resultados.jsonl`)

Correspondencia con el pedido: paso 1 = 1a-1c, paso 2 = 2a-2e, paso 3 = 3a-3d, paso 4 = 4, paso 5 = 5a-5d, paso 6 = 6a-6b, paso 7 = 7a-7h (7a-7c por UI, 7d-7f y 7h por API, 7g estado), paso 8 = 8a-8f, extra de 375 px = 9a-9c.

{{TABLA}}

### Capturas adicionales (sin sub-paso propio)

- `paso1-00-stock-owner.png` (punto de partida de `/stock`) y `paso2-01-importador-paso1.png` (importador en el paso 1).
- `paso5-venta-confirmar-borrado.png` y `paso5-compra-confirmar-borrado.png`: los diálogos de confirmación del borrado (el de la compra explica que se revertirá el ingreso de stock); sus textos están en `logs/20_dialogos_borrado.log`.
- `paso3-01b-edicion-stock-actual-completa.png` y `paso7-03b-edicion-seller-completa.png`: el diálogo de edición desplazado al final (las capturas `paso3-01` y `paso7-03` cortan el texto de ayuda de la sección Stock). Se tomaron al final de la corrida, por eso muestran el saldo 18 y no el 16 de 3a.

### Estado final de la base local (`logs/40_estado_final_bd.log`)

- **ACL**: `rpc_reverse_stock_movement` sin `EXECUTE` para `authenticated` y `anon` (sólo `service_role`); `rpc_stock_adjustment`, `rpc_adjust_branch_stock`, `rpc_transfer_stock` y `rpc_apply_product_stock_delta` con `EXECUTE` para `authenticated` y sin él para `anon`. `authenticated` sólo tiene `SELECT` sobre `stock_movements` y `branch_stock` (sin `INSERT`, `UPDATE` ni `DELETE`).
- **CHECK** `stock_movements_manual_needs_reason` presente y `convalidated = false` (`NOT VALID` por diseño: no se reescribe el histórico).
- **Invariantes**: 0 movimientos manuales sin motivo, cuenta, sucursal o autor; 0 movimientos con `after <> before + delta`.
- **Libro** (12 movimientos): los manuales (`adjustment`/`loss`) con motivo, el alta con `Stock inicial`, la venta y su `sale_reversal`, la compra y su `purchase_reversal`, el par `transfer_out`/`transfer_in` y el ajuste parcial del importador. Los saldos finales cierran con las operaciones: `Producto humo local` vuelve a 7 tras borrar venta y compra, y `Alfajor artesanal` queda 93 + 15.

## Desvíos (lo que no se pudo ejecutar o se hizo distinto al pedido)

1. **Es el entorno local, no prod.** Los pasos 14.4 y 5.4 del `tasks.md` (humo del PO en prod) siguen abiertos; esto los ensaya pero no los cierra.
2. **Sólo tema claro.** Se verificó escritorio 1280 px y 375 px, no el tema oscuro (el pedido no lo incluía; la tanda B ya cubrió las 4 combinaciones visuales).
3. **El rol `stock` no se ejerció.** Se sembró e inició sesión con `qa.stock@local.test`, pero la parte "con permiso" se probó con `owner`, como pedía el humo. Que `stock` y `admin` ajustan está cubierto por el gate SQL de la tanda B, no por este humo.
4. **Venta y compra por el formulario, no por el POS** (el pedido admitía "POS o formulario"), ambas con "Sin sucursal (general)" y sin forma de pago.
5. **La importación del paso 2 se hizo en archivos separados** para ver cada comportamiento por su lado: 2a (mixto, sólo vista previa), 2b (una sola fila bloqueada) y 2c (corregido, se aplica). Después 2e aplica un CSV mixto aparte. Tipos de movimiento ejercidos en el importador: `Ajuste entrada` y `Pérdida`.
6. **La semántica de "confirmación deshabilitada" difiere del pedido** (ver Hallazgo 1): el botón sólo se deshabilita cuando no queda ninguna fila válida; con filas bloqueadas y otras válidas queda habilitado y omite las bloqueadas. Es lo que dice el escenario de la spec ("esa fila queda marcada como error bloqueante con el texto 'Falta el motivo' y no se aplica"); el brief pedía "deshabilitada mientras haya errores bloqueantes", que no es lo que implementa la UI.
7. **Ajustes de la siembra (no de la aplicación)**: los productos QA se insertan por SQL sin `category_id` y el formulario exige categoría para guardar ("Completá nombre y categoría"), así que `seed.mjs` les asigna `Alimentos`; y la venta exige cliente, así que se sembró uno. Sin eso el paso 3d (guardar la edición) y el 5a no podían ejecutarse. En una cuenta real todos los productos ya tienen categoría.
8. Durante el desarrollo de los scripts hubo corridas de iteración (selectores, siembra). La evidencia de este directorio es **sólo la de la corrida limpia final** (`db reset`, siembra y pasos 21 a 29 sobre una base vacía); las capturas y los resultados de las iteraciones se sobrescribieron o vaciaron. No se modificó ningún archivo de la aplicación.

## Hallazgos (aunque el paso pase)

1. **Importador: resultado parcial confuso (PASS funcional, UX mejorable).** Con un CSV mixto (una fila válida y una sin motivo), el botón dice "Aplicar 1 ajuste" y queda habilitado, y la fila bloqueada **no** toca el stock (2e: `Producto escaso QA` sigue en 1, 0 movimientos). Pero el panel de resultado muestra "1 OK · 1 con error", la etiqueta "1 errores" y un encabezado **"Detalle de errores" vacío** (el listado filtra `status !== "error"`, que es justo la fila omitida), mientras el toast dice "1 ajuste registrado correctamente". Es contradictorio para el usuario; ver `paso2e-01-resultado-parcial.png`. Origen: `frontend/components/stock/stock-import-adjustment-dialog.tsx` (cálculo de `err` del toast frente a `appliedErr` del panel).
2. **Pluralización en castellano del importador**: "1 filas · Archivo: ajustes.csv" y "Se aplicarán las 1 filas válidas" (`paso2-02`, `paso2-03`). Cosmético.
3. **Los rechazos deliberados de la base llegan como HTTP 500 en PostgREST** (cuerpo con `code: P0403` o `P0400` y mensaje claro) en `rpc_stock_adjustment`, `rpc_adjust_branch_stock` y `rpc_apply_product_stock_delta` (7d, 7f, 8a, 8e); los accesos directos a tablas y a la RPC revocada sí devuelven 403 con `42501` (7e, 8b, 8c, 8d). Es la convención `P04xx` del proyecto (la UI los traduce con `humanizeOperationError`), pero cualquier monitoreo que cuente los 5xx de PostgREST los verá como errores del servidor.
4. **Los movimientos de venta y compra (y sus reversas) quedan con `branch_id` nulo** cuando la operación se carga con "Sin sucursal (general)" (movimientos 8 a 11 del libro final; cuenta y autor sí quedan). El stock se mueve igual en `Casa Central` y vuelve bien al borrar. El invariante nuevo sólo cubre los movimientos **manuales**, así que no es una violación; no se verificó contra una versión anterior si ya era así.
5. **"Stock inicial" se registra como `adjustment` con motivo "Stock inicial"** (decisión D9 del diseño): en el historial la etiqueta del tipo dice "Ajuste" y "Stock inicial" aparece en la línea del motivo (`paso4-03`), no como etiqueta de tipo `initial`.
6. **Ruido de consola, no atribuible a este change (no se comparó contra el estado previo):** `Warning: Missing Description or aria-describedby={undefined} for {DialogContent}` en los diálogos de producto, de venta y compra y de transferencia (no en el modal de ajuste ni en el importador, que sí tienen descripción), y un `GET /fiscal/profile` con 404 en `/ventas` para una cuenta sin perfil fiscal. No hubo ningún `pageerror` ni 5xx de FastAPI en toda la corrida; los 4xx del backend son sólo esos dos 404 y el 403 esperado del paso 7h (`logs/01_backend_uvicorn.log`).
7. **Detalle cosmético del libro**: `transfer_out` y `transfer_in` guardan `quantity_delta` sin escala (`-5`, `5`) mientras el resto sale con cuatro decimales (`-2.0000`); la UI lo formatea igual.
8. Sin hallazgos de foco ni de desborde horizontal: los 3 casos de 375 px miden 0 px de desborde de documento, y el modal con motivo vacío mantiene `aria-invalid` y el mensaje visible.
9. Ruido de entorno (no de la app): el arranque de Next avisa que infirió la raíz del workspace por haber varios `lockfile`.

## Archivos de la evidencia

- `scripts/`: arnés y pasos (`run_all.sh`, `seed.mjs`, `10_login.mjs`, `21_paso1.mjs` a `29_importador_parcial.mjs`, `estado_final.sql`, `build_report.py`).
- `screenshots/`: 39 capturas (nombre = paso + descripción).
- `logs/`: `00_db_reset`, `01_backend_uvicorn`, `02_next_dev`, `03_seed`, `04_login`, `05_*` (salida de cada paso), `06_run_all_consola`, `10_resultados.jsonl` (fuente de la tabla), `20_*` (consola del navegador, requests del producto, diálogos de borrado), `30_api_paso7_8.log` (request y respuesta completas de la API de los pasos 7 y 8) y `40_estado_final_bd.log`.
