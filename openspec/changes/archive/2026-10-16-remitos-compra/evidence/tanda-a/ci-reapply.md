# Cadena de reaplicación de KPI_Validation.yml — simulación local (tarea 1.9)

Fecha: 2026-10-03. Stack local de Supabase (Postgres 17 en Docker), desde el
worktree de la rama `opsx/remitos-compra-apply-a`.

1. `npx supabase db reset` limpio: aplica la historia completa hasta
   `20261071000001` sin error (introspección OK). Duración: 1 min 50 s.
2. `schema_snapshot()` (el mismo de `KPI_Validation.yml`) antes de la cola.
3. Reapply de `20261063000001`..`20261068000001`: OK. Después,
   `_quote_validate_items` queda con el cuerpo viejo de `20261067000001`
   (`f` en el chequeo `RV_BODIES`): es lo que restauraba el paso retirado.
4. Control del retiro: reaplicar `20261069000001` en ese estado aborta con
   `check constraint "document_status_transitions_document_type_check" ... is
   violated by some row` (23514), y además deja dos CHECK ya re-angostados sin
   `delivery_note_purchase` (la migración no es transaccional). Es la razón
   del retiro (design.md D16).
5. `supabase db reset` de reconvergencia: schema IDÉNTICO al del paso 2.
   Costo: ~1 min 47 s.
6. Reapply de `20261070000001`: introspección OK, schema IDÉNTICO.
7. Reapply de `20261071000001`: introspección OK, schema IDÉNTICO,
   `RV_BODIES = true`, `RC_BODIES = true`.
8. Control del orden: reaplicar `20261070000001` DESPUÉS del de compra deja
   `_delivery_note_payload` sin `supplier_name` (`RC_BODIES = false`) y el diff
   de schema NO lo detecta (compara constraints, firmas y ACLs, no cuerpos).
   Por eso el paso de compra va último y re-consulta los cuerpos. Reaplicar
   `20261071000001` lo restaura (`RC_BODIES = true`).
9. Reaplicar `20261071000001` sobre un estado con un valor extra en dos de los
   CHECK (`zz_extra_futuro`): el valor extra se conserva (CHECK por agregado).
