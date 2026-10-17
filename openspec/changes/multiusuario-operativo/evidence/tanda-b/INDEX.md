# Evidencia de la tanda B — `multiusuario-operativo`

Todo lo que respalda el PR de la tanda B. Los logs son de la base **local** (nunca de producción); lo único que se leyó de
producción fue de sólo lectura (conteos, `md5` de cuerpos y ACLs).

| Archivo | Qué prueba |
|---|---|
| `cuerpos-previos/*.sql` | El `pg_get_functiondef` **vivo** de las nueve funciones que la migración reescribe (las ocho RPCs y `_purchase_operation_core`), con su ACL, su `COMMENT` y el `md5` de `prosrc` (sin `\r`), que coincide con producción (2026-10-17). Es el **rollback**: `supabase/migrations_bak/rollback_20261083000001_multiusuario_operaciones.sql` los restaura (y CI lo ejecuta en cada corrida). |
| `diffs/*.diff` | El diff de cada función contra su cuerpo vivo: sólo el guard de rol, el filtro de cuenta, la regla de autor y `v_author` (la autoría que se conserva al editar). Nada más cambió. |
| `red.log` | Gate `test_multiusuario_operaciones.sql` **antes** de la migración: 12 bloques fallan por la razón correcta (R3b/R3d/R3f/R3g, el producto de otra cuenta que da `P0403`, el helper inexistente y el observador que vende con un producto propio). |
| `green.log` | El mismo gate **después**: `EXIT=0`, los 12 bloques `PASS`. |
| `mutantes.log` | Cinco mutantes (sin el filtro de cuenta del producto, borrado sin guard de rol, borrado de compra sin regla de autor, núcleo sin filtro de cuenta, edición con el lock por autor): el gate falla en todos. |
| `red-backend.log` / `red-frontend.log` | Los tests nuevos fallando **antes** del guard (backend: 44 failed / 43 passed; frontend: 4 archivos, 43 tests). |
| `baseline-gates.txt` | La *safety net*: 39 pasos de la cadena de `KPI_Validation.yml` que ejecutan o introspeccionan las nueve funciones, sobre `main` y antes de tocar nada: 39/39. |
| `chain-kpi.txt`, `chain-095-rerun.txt` | La cadena completa (pasos 004-121) sobre un `db reset` limpio: 117/118 en la corrida completa; el 095 (carrera de facturar venta manual) falló **por carga** —se corrió en paralelo con vitest— y pasó 20/20 corrido solo (`chain-095-rerun.txt`). |
| `pytest-ci.log` | pytest como en CI: 4319 passed, 7 failed (`test_invoice_pdf.py`, preexistentes en el entorno local), cobertura 95,38 % (umbral 87 %). `pytest-integration.log`: 118 passed + 1 corregido y re-corrido (los 2 archivos de remitos: 36 passed) = 119 passed, 3 skipped. |
| `vitest-shard-*.log`, `vitest-shards-summary.txt` | vitest completo en 6 shards: 568 archivos, 6792 tests, 0 fallos. |
| `tsc.log` | `tsc --noEmit` del frontend: los mismos 8 errores de 5 archivos de test ajenos a este change (idénticos a la tanda A). |
| `humo-api.log` | Humo por la API REAL (GoTrue ES256 local, FastAPI con las dos palancas de tenencia, PostgREST): R3a-R3l, la autoría conservada, observador y depósito rechazados por FastAPI y por PostgREST directo, producto y documento de otra cuenta, cuenta personal activa, claim revocado. 42/42 PASS. |
| `humo-ui.log`, `visual-*.png` | `/ventas` y `/compras` por rol con build de producción: observador, vendedor, compras, depósito y dueño; escritorio y móvil, claro y oscuro (16 capturas). 22/22 PASS. |
| `humo-ui-venta.log`, `humo-ui-*.png` | El vendedor vende un producto del dueño desde el formulario de `/ventas` y el dueño elimina esa venta desde el listado, por la interfaz. 3/3 PASS. |
| `humo-s20-smoke-stock.log` | `smoke_stock.sql` de la auditoría de stock (S20, R3a-R3l) re-corrido contra la base migrada. R3a-R3l **todo OK**; adaptado: el invitado queda con el negocio activo y R3g lo hace el rol compras (el vendedor ya no compra: OQ-3 b; R3g2 lo verifica). Los tres FAIL restantes (S7e, S16b, S16d) son hallazgos de #645 y #646, ajenos a este change. |
| `humo-scripts/` | Los scripts del humo (siembra, API, interfaz, build y arranque del stack local) y el `smoke_stock.sql` adaptado. Los secretos locales se leen de un archivo fuera del repo; nada está embebido. |
