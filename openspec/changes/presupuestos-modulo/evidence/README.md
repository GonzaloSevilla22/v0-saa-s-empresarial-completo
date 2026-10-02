# Evidencia de la tanda A

Versionada a pedido de la revisión adversarial del PR #608 (hallazgo F5): la
pasada visual y el red-team vivían sólo en el disco local del autor.

## Capturas (`capturas/`)

Stack local completo (frontend + FastAPI + Supabase), datos sembrados con
usuarios `@local.test`. Selección representativa de la pasada de 103 capturas:
cada pantalla en **móvil 375 px y escritorio, tema claro y oscuro**.

| Pantalla | Archivos |
|---|---|
| Listado `/presupuestos` | `listado-{mobile,desktop}-{light,dark}.png` |
| Detalle de un borrador | `detalle-borrador-{mobile,desktop}-{light,dark}.png` |
| Alta con renglones cargados | `nuevo-lleno-{mobile,desktop}-{light,dark}.png` |
| Detalle de un presupuesto convertido (`accepted`) | `detalle-aceptado-mobile-{light,dark}.png` |
| Edición bloqueada de un `accepted` (P0423) | `editar-aceptado-bloqueado-mobile-{light,dark}.png` |
| Menú compartir (PDF / WhatsApp) | `menu-compartir-mobile-{light,dark}.png` |
| PDF generado, página 1 | `pdf-presupuesto-p1.png` |

## Red-team (`redteam/`)

`redteam.mjs` (70 casos) y `redteam2.mjs` (5 casos de concurrencia) corren
contra el stack **local** (se niegan a correr contra cualquier otro host) y
dejan PASS/FAIL por ítem. `redteam1.log` es la salida de `redteam.mjs`:
**70 casos, 0 fallas**. `redteam2.mjs`: 5 casos, 0 fallas (6 ediciones
concurrentes con la misma revisión → 1 gana y 5 `quote_changed`; 6 `send`
concurrentes sin 5xx y un solo historial; mezcla `send/reject/delete`
concurrente sin 5xx ni líneas huérfanas).

Las contraseñas de los usuarios de prueba locales se leen de `RT_PASS_OWNER`,
`RT_PASS_SELLER`, `RT_PASS_CASHIER` y `RT_PASS_TENANT_B`. Requieren el seed QA
local (cuatro usuarios: dueño, vendedor, cajero y un segundo tenant) y el
backend en `127.0.0.1:8000`.

Qué cubren los 70 casos de `redteam1.log`:

- **Escritura directa por la API de datos**: INSERT/UPDATE/DELETE sobre
  `quotes` y `quote_items` como `authenticated` → 403 `42501`; como `anon` →
  401; el presupuesto queda intacto; los helpers internos
  (`_next_internal_document_number`, `_expire_overdue_quotes`) no son
  ejecutables por `authenticated`.
- **Aislamiento entre cuentas**: GET/PUT/DELETE/transition/PDF de un
  presupuesto ajeno → 404 (el mismo que un id inexistente); alta con producto o
  cliente de otra cuenta → 404 y ningún snapshot ajeno en la base.
- **Versión y estados**: `quote_changed` (409) sin escribir nada; transiciones
  inválidas → 409 `quote_invalid_state`; `accepted` pedido por la API → 422;
  `accepted` inmutable (P0423) y no eliminable; `POST /quotes/{id}/accept`
  retirado.
- **Roles**: cajero crea/edita/envía/elimina → 403 `insufficient_role`, lee
  y descarga el PDF; vendedor no configura la validez; la RPC invocada directo
  por un cajero se rechaza (`P0403`).
- **Numeración**: 15 altas concurrentes por HTTP, todas 201, distintas y
  correlativas, sin duplicados.
- **Entradas hostiles**: validez en el pasado, sin líneas, servicio sin
  descripción, notas de más de 2.000 caracteres, texto con HTML/SQL como dato
  (se guarda y el PDF se genera), id inválido → 422, token inválido o ausente
  → 401.
