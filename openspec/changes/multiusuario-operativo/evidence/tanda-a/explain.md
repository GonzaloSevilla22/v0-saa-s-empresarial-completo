# 2.5 — Costo de `current_account_ids()` antes / después

**Qué se midió.** Base local (Postgres 17, `supabase_db_v0-saa-s-empresarial-completo`), dentro de `BEGIN..ROLLBACK`
(residuo cero). Fixture: un usuario de **una** cuenta (el caso de los 41 de producción) con 20.000 ventas, 10.000 compras
y 5.000 gastos. Cada consulta corre 40 veces como `authenticated` (con RLS: la policy de `sales` llama a
`current_account_ids()`), y se informa la mediana y el p95 en milisegundos.

- **antes**: el cuerpo previo de `current_account_ids()` (`SELECT account_id FROM account_members WHERE user_id = auth.uid()`),
  reinstalado dentro de la transacción (es el rollback documentado en `cuerpos-previos/current_account_ids.sql`).
- **después, con claim**: la función nueva con `app_metadata.account_id` en `request.jwt.claims`. **Es el camino de producción**:
  el hook emite el claim en cada token, y `get_db_conn` lo empuja a SQL.
- **después, sin claim**: la función nueva con un token que no trae el claim (emitido antes del deploy: vive a lo sumo 15
  minutos). Resuelve con `resolve_active_account` (lee `profiles` y `account_members`).

| Consulta | antes (mediana / p95) | después, con claim | después, sin claim |
|---|---|---|---|
| `current_account_ids()` sola | 0,130 / 0,298 | **0,070 / 0,087** | 0,601 / 1,064 |
| `SELECT … FROM sales ORDER BY date DESC LIMIT 50` (RLS) | 7,354 / 9,741 | 7,836 / 9,080 | 9,783 / 14,657 |
| `SELECT count(*) FROM sales` (RLS) | 5,582 / 7,176 | 5,420 / 7,152 | 7,667 / 13,110 |
| `get_dashboard_financials(30 días)` | 24,956 / 27,887 | 25,051 / 30,290 | 29,992 / 39,363 |

**Lectura.**
- Con claim (el camino de producción) **no hay regresión medible**: la función pasa de 0,13 ms a 0,07 ms (una búsqueda por
  el índice único `(account_id, user_id)` en vez de recorrer las membresías del usuario) y las consultas de negocio quedan
  dentro del ruido (±0,5 ms sobre 5-25 ms).
- Sin claim la función cuesta ~0,5 ms más por sentencia (lee `profiles` además de `account_members`). La fila "sin claim" corrió
  **primero** en cada repetición, así que arrastra además efecto de caché fría: el sobrecosto de las consultas de negocio
  (+2 a +5 ms) es una cota superior, no el costo de la función. Ese camino sólo lo recorre un token emitido antes del deploy.
- Los planes son **idénticos** antes y después: `current_account_ids()` se evalúa **una vez por sentencia**
  (`hashed SubPlan 1`, `loops=1`), no por fila. Ver los `EXPLAIN (ANALYZE, BUFFERS)` completos en `explain.out.txt`.

Reproducir: `psql -f explain.sql` (en esta misma carpeta, sobre la base local).
