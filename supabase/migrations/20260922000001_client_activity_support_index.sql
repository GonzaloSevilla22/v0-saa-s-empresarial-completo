-- clientes-frecuentes-historial — índice de soporte (design.md §5 "Risks /
-- Trade-offs" + "Migration Plan").
--
-- GET /clients/activity resuelve, para cada cliente de la página, un
-- LEFT JOIN LATERAL sobre `sales` filtrado por (account_id, client_id) y
-- ordenado implícitamente por fecha para el cálculo de última compra /
-- ventana de frecuencia. Sin este índice cada agregado cae en
-- idx_sales_client_id (solo client_id) y escanea de más dentro de la
-- cuenta. Con 585 filas en `sales` (2026-08-14) es irrelevante hoy; se
-- agrega igual como índice de soporte, barato y alineado con el patrón de
-- acceso — el propio design.md lo marca como no bloqueante.
--
-- Cambio puramente aditivo del lado de lectura. Sin cambios de esquema ni de
-- datos. Rollback = revertir el PR; ninguna estructura queda huérfana.
--
-- Nota de implementación (desvío documentado de design.md, que pedía
-- CREATE INDEX CONCURRENTLY): la migración tooling de Supabase (CLI
-- `db push` y la integración de GitHub que auto-aplica al mergear) corre
-- cada archivo dentro de una transacción, y CONCURRENTLY no puede ejecutarse
-- dentro de un bloque de transacción — es la misma razón por la que
-- 20260526201027_add_pagination_indexes.sql (precedente directo en este
-- repo) tampoco usa CONCURRENTLY. `IF NOT EXISTS` mantiene la migración
-- idempotente, que es la propiedad que realmente exige la integración de
-- GitHub.
CREATE INDEX IF NOT EXISTS idx_sales_account_client_date
  ON sales (account_id, client_id, date DESC)
  WHERE client_id IS NOT NULL;
