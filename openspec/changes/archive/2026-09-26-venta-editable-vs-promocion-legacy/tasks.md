## 1. Safety net y medición

- [x] 1.1 Re-medir en prod (sólo `SELECT`) los md5 de los 4 cuerpos vivos + helper #582, sus COMMENT y ACLs, `max(version)` y los datos de §Context del design (2026-09-23 y de nuevo 2026-09-24: sin cambios)
- [x] 1.2 Baseline local: `supabase db reset` + gates que tocan las 4 RPCs, race de #582, pytest, vitest y tsc (fallas preexistentes anotadas: `banco-conciliacion-import-warnings` en vitest, 8 errores de tsc en tests)

## 2. N2 — la promoción ejecuta (gate SQL que la corre de verdad)

- [x] 2.1 RED: `supabase/tests/test_facturar_venta_manual.sql` bloque (1) llama `rpc_promote_legacy_sale_to_order` sobre una venta real → `42883 function min(uuid) does not exist`
- [x] 2.2 GREEN mínimo: cabecera por primera fila; TRIANGULATE (1b) sin sucursal → `c26_default_branch`, (1c) sin cliente → `client_id NULL`
- [x] 2.3 RED (2)-(6): heterogéneas sin `P0422`, fila ajena sin `P0404`, `sale_items` duplicados → total 2000
- [x] 2.4 GREEN: helper `_sales_order_sync_from_operation` + promoción que lo usa (homogeneidad, total por cabecera, snapshots de un `sale_item`)

## 3. N3 — la edición recalcula la orden re-apuntada

- [x] 3.1 RED (7)/(10): la orden re-apuntada queda en $1000 y la re-emisión tras anular/rechazar sale por el importe viejo
- [x] 3.2 GREEN: la edición re-apunta con `RETURNING` y llama al helper; (9) borrado después de promover → `canceled` + `P0400` al emitir

## 4. D6 — la emisión rechaza una orden desincronizada

- [x] 4.1 RED (8a): una orden con otro total se emite igual
- [x] 4.2 GREEN: bloque "1-bis" de `rpc_emit_sale_invoice` (`P0409 sales_order_out_of_sync`); TRIANGULATE (8b) otro cliente, sin operación, orden sana; (8c) el replay de la promoción resincroniza; (11) replay con comprobante vivo no toca la orden; (0) introspección (helper INVOKER cerrado, firma que resuelve, una definición viva, md5 de los COMMENT)

## 5. N1 — exclusión por las filas de la operación

- [x] 5.1 RED: `supabase/tests/test_facturar_venta_manual_race.sh` (dos conexiones) sin los locks → R1/R2 no esperan, R3/R4 con DAÑO (`pending_cae` sobre una venta editada/borrada)
- [x] 5.2 GREEN: lock `FOR UPDATE` ordenado en promoción, edición (E2 + recuento) y borrado (D1 + recálculo del conjunto) → R1, R1b, R2, R3, R4, R5 20/20, 0 deadlocks, 0 comprobantes dañados
- [x] 5.3 R6 doble "Guardar": la segunda edición espera a la primera y da `P0404` sin duplicar la operación ni mover stock dos veces (RED con el mutante sin lock temprano, GREEN 20/20)
- [x] 5.4 Mutantes (m1-m10): todos muertos por el gate SQL o por el arnés de carrera

## 6. Backend

- [x] 6.1 `POST /sales/{operation_id}/promote-to-order` valida el id como `uuid` (422 sin tocar la base)
- [x] 6.2 Un sqlstate sin mapear deja de filtrar texto de Postgres (500 problem+json `internal_error`); `operation_inconsistent` → 409; `sales_order_out_of_sync` → 409 con el token
- [x] 6.3 Integración real (`-m integration`, Postgres local): `SalesRepository.promote_to_order` RED `UndefinedFunctionError` (42883) → GREEN; tenencia `P0404`

## 7. Frontend (`/ventas`)

- [x] 7.1 `translatePromoteError` / `translateEmitInvoiceError` exportadas, con los tokens nuevos y sin devolver nunca el texto crudo del servidor
- [x] 7.2 "Facturar" → "Emitir comprobante" (`EmitInvoiceButton.label`, default intacto en `/ventas/ordenes`); la fila vuelve a "Facturar" si la emisión falla (`onEmitFailed`)
- [x] 7.3 La fila pasa sola a "En trámite" (invalidación de `sales`) y a "Autorizado" (`FiscalDocumentBadge.onStatusChange` en un `useRef`)
- [x] 7.4 Arnés `/dev-harness/facturar-venta` y pasada visual de los rechazos en 1366×768 y 375×812, claro y oscuro
- [x] 7.5 e2e real `e2e/facturar-venta-manual.spec.ts` contra el stack local y el backend con `WSFEStubAdapter` verificado: Facturar → Emitir → En trámite → relay → Autorizado, en las 4 combinaciones
- [x] 7.6 El 500 sin mapear de la emisión ("Error de base de datos: …", `services/sales_orders.py`) tampoco llega al toast: `translateEmitInvoiceError` lo cambia por un texto genérico (RED visto, GREEN; hallado en la revisión de cierre del 2026-09-24)

## 8. CI y cierre local

- [x] 8.1 `KPI_Validation.yml`: pasos del gate SQL y del arnés de carrera (`ITER=20`); `E2E_Tests.yml`: `RELAY_SECRET` descartable; `test_function_acl_gate.sql` cierra el helper nuevo (chequeo 3)
- [x] 8.2 `supabase db reset` limpio + la migración aplicada dos veces más con md5, ACL y COMMENT idénticos
- [x] 8.3 Todos los pasos de `KPI_Validation.yml` en el orden real del workflow, incluido el de reaplicación
- [x] 8.4 pytest completo con cobertura (≥ 87 %), vitest completo, `tsc --noEmit` sin errores nuevos
- [x] 8.5 Specs (`sales-order`, `operation-edit-context`, `afip-fiscal-document`), `CHANGES.md` y `CLAUDE.md`/`AGENTS.md` en sincronía

## 9. Cierre del red team (2026-09-24)

- [x] 9.0 Rebase sobre `origin/main` (`f5740fe0`, #583 — `delegacion_autorizada`), sin conflictos; `test_c27_fiscal_profile_repository.py` en verde
- [x] 9.1 M1 — (0L) en `test_facturar_venta_manual.sql`: orden global de locks sobre el cuerpo vivo en cada PR (el DO de la migración corre una vez). RED: el gate de HEAD dejaba vivos n6/n7/n8/n9/n10/n13; GREEN: los seis muertos (más n1/n2/n17)
- [x] 9.2 M1 — arnés de carrera: R7 (edición frenada → borrado: `false`, sin `SaleOperationDeleted`) y R8 (orden frenada → promoción en replay → edición: sin `40P01`). RED: n10 muere sólo en R7 y n6 sólo en R8 (`EDIT_ERR 40P01`); GREEN 20/20
- [x] 9.3 MINOR D3b — el replay de la promoción filtra por la cuenta del caller y una orden ajena es `P0404` también en el handler de `unique_violation`. RED bloque (12): B recibía el `sales_order_id` de A (facturada) o un P0404 que lo nombraba (sin facturar); GREEN
- [x] 9.4 NIT D2 — Σ líneas = total también con filas de más de 2 decimales (residuo en la última). RED (6c) 0,335 × 3 → 1,02; GREEN (±)
- [x] 9.5 NIT — `services/sales_orders.py` re-lanza el sqlstate sin mapear (500 problem+json `internal_error`, sin texto del motor). Verificado que ningún token del POS viaja por ese fallback (todos con P0400/P0401/P0404/P0409/P0422, mapeados antes)
- [x] 9.6 Regresión completa sobre `supabase db reset` limpio (sin mutantes de otra sesión instalados) — ver `CHANGES.md`

## 10. Post-merge (prod, sólo lectura)

- [x] 10.1 Re-verificado en prod 2026-09-26 (SELECT-only, más fresco que la medición del 09-24): `max(version) = 20261062000001` (309 migraciones, ⩾ `20261061000001` — el PR #584 ya mergeó encima); una sola definición viva de cada una de las 5 funciones (`rpc_promote_legacy_sale_to_order`, `rpc_atomic_update_sale_operation`, `rpc_delete_sale_operation`, `rpc_emit_sale_invoice`, `_sales_order_sync_from_operation`), sin overload; `_sales_order_sync_from_operation` es `SECURITY INVOKER` con ACL exacta `{postgres, service_role}`; las 4 RPCs son `SECURITY DEFINER` con ACL `{postgres, authenticated, service_role}` (sin `anon`); el cuerpo vivo de `rpc_promote_legacy_sale_to_order` no contiene ningún `MIN(uuid)` funcional — el único match de "min(uuid)" es texto de comentario explicando por qué se evitó.
- [x] 10.2 Invariante re-medido 2026-09-26: 0 `sales_orders` no canceladas cuyo total no cuadre con la suma de `sales.total` de su operación (`sale_operation_id`).
- [ ] 10.3 Logs de Render (0 500 en `POST /sales/*/promote-to-order`, 0 sqlstate no mapeado) — NO verificado en esta sesión de archive (sin acceso a la API de Render en este contexto); queda como chequeo de rutina, no bloqueante.
- [x] 10.4 Humo real del PO (2026-09-25, ver `CHANGES.md`/engram `sumar-primera-factura-delegacion-arca`): venta manual en la cuenta Sumar → Facturar → Emitir comprobante → Autorizado (Factura C 0003-00000501, CAE, autorizada por ARCA en 1 s, constatada por el PO en el portal de ARCA). NO ejercitado: editar una venta preparada antes de emitir (el humo del PO cubrió el camino de emisión de punta a punta, no el de edición previa a la emisión).
