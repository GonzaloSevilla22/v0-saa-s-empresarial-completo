# Evidencia de la tanda A — `multiusuario-operativo`

Todo lo que respalda el PR de la tanda A. Los logs son de la base **local** (nunca de producción); lo único que se leyó de
producción fue de sólo lectura (conteos, `md5` de cuerpos y ACLs).

| Archivo | Qué prueba |
|---|---|
| `cuerpos-previos/*.sql` | El `pg_get_functiondef` **vivo** de las seis funciones que la migración reescribe, con su ACL y su `COMMENT`. Es el **rollback**: restaurarlos y `ALTER TABLE public.profiles DROP COLUMN active_account_id`. Su `md5` de `prosrc` (sin `\r`) coincide con producción (2026-10-16) y es el que exige el preflight de la migración. |
| `red.log` | Gate `test_multiusuario_cuenta_activa.sql` **antes** de la migración: 18 bloques fallan por la razón esperada (R3j `P0409 … disponible 0.0000`, claims ignorados, `profiles.active_account_id` inexistente, funciones con criterio propio). |
| `green.log` | El mismo gate **después** de la migración: `EXIT=0`, todos los bloques `PASS`. |
| `red-backend.log` / `red-frontend.log` | Los tests nuevos de backend y de frontend fallando **antes** de escribir la implementación (18 tests de backend y 10 archivos de frontend). |
| `baseline-gates.txt` | Los pasos 004-094 de `KPI_Validation.yml`, en orden, sobre un `db reset` limpio de `main` antes de tocar nada (la *safety net*). 4 pasos dan rc != 0 (024, 025, 033, 077) por el arnés local —`psql` invocado desde Python y gates que hacen `\i` con ruta relativa, que el arnés resolvió después—, no por `main`. |
| `explain.md`, `explain.out.txt`, `explain.sql` | Costo de `current_account_ids()` antes / después. |
| `deno-check.log` | `deno check` de las Edge Functions tocadas, fuera del monorepo. |
| `tsc.log` | `tsc --noEmit` del frontend: los mismos 8 errores de 5 archivos de test ajenos a este change. |
| `suites.txt` | Resultado de las suites completas: vitest en 6 shards (564 archivos, 6724 tests, 0 fallos), pytest como en CI (4230 passed; 7 failed de `test_invoice_pdf.py`, preexistentes en el entorno local; cobertura 95,38 %) e integración contra la base local (119 passed). |
| `chain-kpi.txt` | La cadena completa de `KPI_Validation.yml` (pasos 004-120) sobre un `db reset` limpio: 117/117 en verde. Tres pasos dieron rc != 0 en la corrida completa (un gate de balanza con un vendedor de dos membresías sin declarar la cuenta y dos carreras por un arnés local que no reenviaba `PGAPPNAME`) y se re-corrieron en verde. |
| `humo.log`, `visual.log`, `*.png` | Humo local con build de producción y backend real (15/15 PASS; la primera corrida falló y destapó que cambiar de cuenta exige renovar el token ante el proveedor) y verificación visual del selector (claro / oscuro, escritorio / móvil, una y dos cuentas; 44 px de alto). |
