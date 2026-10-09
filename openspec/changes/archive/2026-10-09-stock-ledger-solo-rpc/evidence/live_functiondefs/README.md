# Cuerpos vivos de partida de la tanda B (task 6.2)

Capturado 2026-10-09 con `MAX(version) = 20261073000001` (320 migraciones) tanto en prod como en el stack local.

`md5(pg_get_functiondef(oid))` de prod (MCP `execute_sql`, solo lectura) comparado contra el del stack local
con los CR eliminados (`replace(def, E'\r', '')`):

| Funcion | md5 prod | md5 local sin CR | md5 local crudo (CRLF del checkout) |
|---|---|---|---|
| rpc_apply_product_stock_delta | 6d8dcab9c533aab375ea8622d1b011d5 | 6d8dcab9c533aab375ea8622d1b011d5 | 128ae954f1668452e2c838e235df9d15 |
| rpc_reverse_stock_movement | 2885cd488052620a1a6309595348d54c | 2885cd488052620a1a6309595348d54c | 2d3e6b0024723b2ce996523b5ed1b5b1 |
| rpc_adjust_branch_stock | 9d8fe0a559cca11cf8d4cc38662e87ad | 9d8fe0a559cca11cf8d4cc38662e87ad | 196780252e3d0c6bfbac52d7f819f361 |
| rpc_stock_adjustment | 2eca2849e6747c775b1a97b7d56ec5b0 | 2eca2849e6747c775b1a97b7d56ec5b0 | 2eca2849e6747c775b1a97b7d56ec5b0 |
| rpc_transfer_stock | 3de807fb783c1efd52104ee110121b68 | 3de807fb783c1efd52104ee110121b68 | da080e13944a7689fb148fea6c034b17 |
| c21_apply_branch_stock_delta (ref.) | 8d98227d6d6556e3a2f3f545dae2b231 | 8d98227d6d6556e3a2f3f545dae2b231 | b5ccdb07b91cb017f19499d21a9e51da |
| _quote_assert_can_write (molde) | 2191ea754d8ed30d3c1d6895e4b5939d | 2191ea754d8ed30d3c1d6895e4b5939d | f7011f72a0da19c3f545f92331033106 |

Los cinco md5 de prod coinciden con los del Anexo A del design (2026-10-08): sin divergencia. La diferencia de
los md5 crudos locales es solo CRLF del checkout (`core.autocrlf=true`), no de contenido.

Los archivos `*.sql` de este directorio son los cuerpos vivos (sin CR) de los que parte la reescritura.

## COMMENT ON FUNCTION vivos (prod = local)

- `rpc_apply_product_stock_delta`: "C-21 checkpoint #2: aplica un delta de stock sobre branch_stock ... Usado por el backend Python para stock inicial, edicion de stock y reversa de compras borradas. Solo productos de la cuenta del caller."
- `rpc_reverse_stock_movement`: comentario largo de v31-tenancy-pool-rls (contramovimiento, ledger append-only) — se conserva y se extiende.
- `rpc_transfer_stock`: "C-26 + v3-document-status-history + v3-notifications-realtime: transferencia atomica ..." — se conserva.
- `rpc_adjust_branch_stock`, `rpc_stock_adjustment`: sin comentario.
