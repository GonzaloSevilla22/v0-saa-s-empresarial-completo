# Design — cuentas-billetera-tipo

## Contexto verificado (no asumido)

**Producción (`gxdhpxvdjjkmxhdkkwyb`), solo SELECTs:**

- `MAX(version)` en `supabase_migrations.schema_migrations` = **`20261006000001`** (256 migraciones). La migración nueva debe numerarse por encima.
- `public.bank_accounts` tiene 13 columnas: `id, account_id, name, bank_name, cbu, alias, currency, opening_balance, opening_date, is_active, created_at, deleted_at, deleted_by`. **No existe** ninguna columna de tipo/categoría.
- **8 filas, 4 activas — y las 4 son billeteras:**

| `name` | `bank_name` | `cbu` | `alias` | `is_active` | Clasificación propuesta |
|---|---|---|---|---|---|
| `MP` | `NULL` | `NULL` | `luzmin.mp` | ✅ | **wallet** |
| `Mercado Pago` | `mercado pago` | `NULL` | `luzmin.mp` | ✅ | **wallet** |
| `Naranja X` | `NULL` | `NULL` | `Sumar. Naranja` | ✅ | **wallet** |
| `UALA` | `NULL` | `NULL` | `NULL` | ✅ | **wallet** |
| `Mercado Pago` × 4 | — | `NULL` | `luzmin.mp` | ❌ soft-deleted 2026-08-20 | **wallet** |

  Ningún banco real. **Cero filas con `cbu` cargado** — el campo CBU nunca se usó, mientras que `alias` sí. Esto confirma el diagnóstico del PO desde los datos: el formulario pide lo que las billeteras no tienen.

- `rpc_create_bank_account` vive con la firma de **7 argumentos** `(text,text,text,text,text,numeric,date)`, `SECURITY DEFINER`, `SET search_path TO 'public'`. Valida `sin_cuenta_activa` (`P0403`), `unauthorized` (`P0401`), `cbu_invalido` (`P0411`), `name_required` (`P0400`).
- El repository la invoca **posicionalmente**: `SELECT rpc_create_bank_account($1, $2, $3, $4, $5, $6, $7) AS result`, seguido de un re-`SELECT` por id.
- Base vigente: `main` en `8e892e5` — el hotfix de tenancy (#446) ya está incorporado y agregó el filtro explícito `WHERE account_id = $1` en `list_active`. La migración y los cambios de repository parten de ahí.

## Decisiones

### D1 — `account_kind` es una columna nueva con dominio cerrado, no un booleano

**Decisión:** `account_kind TEXT NOT NULL DEFAULT 'bank'` + `CHECK (account_kind IN ('bank','wallet'))`.

**Por qué no `is_wallet BOOLEAN`:** el dominio no es binario a futuro (una caja de ahorro en dólares, una cuenta de un broker o una pasarela podrían ser tipos propios). Un `TEXT` con `CHECK` admite un tercer valor con una migración de una línea; un booleano obligaría a migrar datos. Es además el patrón que el proyecto ya usa en `payment_methods.kind` (dominio cerrado por `CHECK`), así que no introduce una convención nueva.

**Por qué `DEFAULT 'bank'`:** hace la columna retrocompatible con todo escritor que la ignore — incluida la llamada posicional de 7 argumentos existente. Ningún camino de escritura se rompe mientras se despliega.

### D2 — La heurística de backfill prioriza el falso negativo sobre el falso positivo

**Decisión:** marcar `'wallet'` solo ante coincidencia con una lista cerrada de marcas; **todo lo demás queda `'bank'`**.

**Por qué:** clasificar un banco como billetera es un error visible y confuso para el usuario; dejar una billetera como banco es el estado actual, que ya es el statu quo. El default seguro es no adivinar.

**Lista cerrada** (sobre `lower(name)` y `lower(bank_name)`):

| Coincidencia por **subcadena** | Coincidencia por **token completo** |
|---|---|
| `mercado pago`, `mercadopago`, `mercado libre`, `uala`, `ualá`, `naranja x`, `naranjax`, `naranja`, `personal pay`, `brubank`, `cuenta dni`, `bna+`, `bna mas` | `mp`, `modo`, `belo`, `prex`, `lemon` |

**Por qué la columna derecha existe:** las siglas y palabras cortas producen falsos positivos por subcadena. El caso testigo es **`modo` dentro de "Banco Co**modo**ro"** — un `LIKE '%modo%'` lo clasificaría como billetera. Lo mismo con `mp`, que aparece dentro de cualquier nombre que contenga esas dos letras seguidas. Para esos términos se usa una frontera de token, p. ej. `lower(name) ~ '(^|[^a-z0-9])mp([^a-z0-9]|$)'`, que sí captura la fila real `MP` de producción.

**Sin dependencia de `unaccent`:** las variantes acentuadas se enumeran explícitamente (`uala` y `ualá`) en vez de exigir la extensión, que no está garantizada en el proyecto.

**Idempotencia:** el `UPDATE` de backfill se acota a las filas que siguen en el default (`WHERE account_kind = 'bank' AND <heurística>`), de modo que reaplicar la migración no pisa una corrección manual posterior. El `ADD COLUMN` usa `IF NOT EXISTS`; el `CHECK` se agrega con guarda por `pg_constraint`. Esto importa porque el auto-apply de Supabase GitHub puede reejecutar el archivo.

**Alcance del backfill:** incluye las filas con `deleted_at` no nulo. Son las mismas billeteras duplicadas y dejarlas sin clasificar produciría inconsistencias si alguna se restaura.

### D3 — Una billetera necesita los mismos campos que un banco: solo cambian las etiquetas

**Decisión:** ninguna columna nueva, ningún campo oculto. Cuando `kind = 'wallet'`, `bank_name` se rotula **"Billetera"** y `cbu` se rotula **"CVU"**.

**Por qué —** esta era la pregunta abierta del pedido, y la investigación la resuelve:

1. **El CVU tiene 22 dígitos, igual que el CBU.** Comparten formato exacto. Reusar la columna `cbu` mantiene intactos el `CHECK` de tabla, el `P0411` de la RPC, el `pattern` de Pydantic y el regex de Zod. Crear una columna `cvu` paralela duplicaría cuatro validaciones idénticas para expresar la misma cosa — exactamente lo que la regla de reutilización del proyecto prohíbe.
2. **`bank_name` ya funciona como "emisor".** Una fila real de producción tiene `bank_name = "mercado pago"`: el usuario ya lo usaba así. Solo faltaba que la etiqueta lo dijera.
3. **Ocultar campos sería peor.** Una billetera puede tener CVU y el usuario puede querer registrarlo. Esconder el campo por tipo le quita una capacidad sin darle nada a cambio.

El costo de esta decisión es que `cbu` queda con un nombre de columna que no describe los dos usos. Es aceptable: renombrarla obligaría a tocar RPCs, repositories, schemas y specs para un beneficio puramente nominal, y el diccionario de datos lo documenta.

### D4 — La firma de la RPC cambia con `DROP` explícito, no con `CREATE OR REPLACE`

**Decisión:** `DROP FUNCTION IF EXISTS public.rpc_create_bank_account(text,text,text,text,text,numeric,date);` seguido de `CREATE FUNCTION` con 8 parámetros, `p_account_kind text DEFAULT 'bank'` **en último lugar**.

**Por qué el `DROP`:** `CREATE OR REPLACE` con una firma distinta no reemplaza — **crea un overload**. Con dos versiones vivas y parámetros con default, una llamada de 7 argumentos se vuelve ambigua y Postgres devuelve `42725 (ambiguous function)`. El proyecto ya se quemó con esto; el `DROP` explícito de la firma exacta es la única forma de evitarlo.

**Por qué el parámetro va último:** preserva la llamada posicional de 7 argumentos durante la ventana de despliegue. La migración puede aplicarse antes de que el backend nuevo esté arriba sin romper el alta.

**Privilegios:** `DROP`+`CREATE` **resetea las ACLs**. La migración debe cerrar con `REVOKE ALL ON FUNCTION ... FROM PUBLIC, anon;` y `GRANT EXECUTE ON FUNCTION ... TO authenticated;` **en el mismo archivo**, o la función queda ejecutable por `PUBLIC` y reabre el hallazgo del advisor 0028. El gate `test_function_acl_gate.sql` debe pasar.

**Cadena de reapply:** si `rpc_create_bank_account` figura en la cadena de reapply de `KPI_Validation.yml`, la referencia debe actualizarse a la firma de 8 argumentos, o el workflow fallará al reaplicarla.

**Validación del nuevo parámetro:** `IF COALESCE(p_account_kind,'bank') NOT IN ('bank','wallet') THEN RAISE ... USING ERRCODE = 'P0412'`. Se elige `P0412` por continuidad con el `P0411` vecino del mismo dominio. El ERRCODE nuevo debe sumarse al mapa `BANK_ACCOUNT_CREATE_ERRCODE_STATUS` → 422 y al gate de ERRCODEs del proyecto.

### D5 — La presentación del tipo vive en un módulo canónico, no repetida por pantalla

**Decisión:** crear `frontend/lib/bank-account-kind.ts` como fuente única de etiqueta, ícono y variante de badge; los consumidores lo importan.

**Por qué:** hoy `PaymentMethodManager` renderiza un `Landmark` **hardcodeado** junto a la cuenta-default (línea 185-186), y hay al menos cinco superficies que listan cuentas (`/banco`, `PaymentMethodManager`, `PaymentMethodSelect`, `RegisterPaymentForm`, `RegisterPaymentMadeForm`). Sin un módulo canónico, el mapeo tipo→ícono se copiaría cinco veces y divergiría — el patrón exacto que llevó a canonizar `lib/product-stock.ts` después de que la criticidad de stock se reescribiera en cinco lugares.

Íconos: `Landmark` (banco) y `Wallet` (billetera), ambos de `lucide-react`, ya presente. Los colores salen de tokens semánticos del design system: nada literal que evada el gate de contraste AA.

### D6 — Editar el tipo de una cuenta queda fuera de alcance

**Decisión:** `rpc_update_bank_account` no se toca en este change.

**Por qué:** `/banco` **no tiene hoy ninguna UI de edición de cuenta** — el único diálogo montado es el de alta. Agregar el parámetro a la RPC de update sin superficie que lo invoque sería backend sin puerta de entrada, precisamente lo que la regla de superficie frontend del proyecto declara change incompleto. Queda registrado como **OQ-1**, con la mitigación de que el backfill nunca clasifica mal por diseño (D2) y de que el alta ya obliga a elegir el tipo.

## Riesgos

| Riesgo | Mitigación |
|---|---|
| El overload `42725` deja el alta rota | `DROP` de la firma exacta de 7 args antes del `CREATE`; test que verifica que existe **una sola** firma de `rpc_create_bank_account` |
| `DROP`+`CREATE` deja `EXECUTE` a `PUBLIC` | `REVOKE`/`GRANT` en el mismo archivo; gate `test_function_acl_gate.sql` |
| La heurística clasifica mal un banco | Lista cerrada + token completo para siglas; caso "Banco Comodoro" cubierto por test |
| Reaplicación por auto-apply de Supabase pisa correcciones | `UPDATE` acotado a `account_kind = 'bank'`; `ADD COLUMN IF NOT EXISTS`; `CHECK` con guarda |
| La ventana de despliegue rompe el alta | Parámetro nuevo en último lugar con `DEFAULT` — la llamada de 7 args sigue válida |

## Fuera de alcance

- Editar el tipo de una cuenta existente (OQ-1).
- Renombrar la columna `cbu` a algo neutro respecto de CBU/CVU (D3).
- Limpiar la fila con `currency = 'pesos'` en lugar de `'ARS'` — dato sucio preexistente, ajeno a este change (**OQ-2**).
- Deduplicar los 4 "Mercado Pago" soft-deleted.
- Cualquier cambio de tratamiento contable: `account_kind` es descriptivo.
