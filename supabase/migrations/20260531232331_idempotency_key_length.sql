-- =============================================================================
-- MIGRATION: idempotency_key_length
--
-- Agrega CHECK (length(idempotency_key) <= 512) a operation_idempotency.
--
-- WHY:
--   La columna era text sin límite. Un usuario autenticado podía enviar
--   una key de megabytes, bloqueando la tabla y su índice UNIQUE con una
--   sola llamada. UUID v4 mide 36 chars; 512 es un techo holgado que
--   cubre cualquier key válida futura sin riesgo de truncado.
--
-- SAFE: todos los valores existentes tienen length = 36 (UUID).
-- =============================================================================

ALTER TABLE public.operation_idempotency
  ADD CONSTRAINT operation_idempotency_key_length
  CHECK (length(idempotency_key) <= 512);
