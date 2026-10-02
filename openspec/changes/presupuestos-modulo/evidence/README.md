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

---

# Evidencia de la tanda B (conversión de presupuesto a venta)

Stack local completo (Supabase local + uvicorn + `pnpm dev` con `NEXT_PUBLIC_PLAYWRIGHT_LOCAL`),
usuarios `@local.test` (owner, seller, cashier y un segundo tenant), un cliente con teléfono, un
producto por kg, uno por unidad y uno con 1 unidad de stock, una cuenta bancaria, una caja y un
perfil fiscal de **homologación** con un punto de venta (el stub de WSFE; nunca producción). Todo
contra el host local: los scripts se niegan a correr contra cualquier otro.

## Capturas (`capturas-b/`)

`<pantalla>-<viewport>-<tema>.png`, **desktop 1280 y móvil 375 × claro y oscuro** (44 de la pasada
visual completa) más las del humo funcional en desktop claro.

| Pantalla | Archivos |
|---|---|
| Diálogo "Pasar a venta": sin forma de pago, efectivo, transferencia (con cuenta bancaria), crédito (con saldo) y efectivo con la caja cerrada (confirmar deshabilitado con su motivo) | `conv-dialog-{vacio,efectivo,transferencia,credito,caja-cerrada}-{desktop,mobile}-{light,dark}.png` |
| Error de stock insuficiente (nombra el producto, "Transferir stock") | `conv-error-stock-*` |
| Error `quote_changed` (el resumen recarga el total vigente) | `conv-error-quote-changed-desktop-light.png` |
| Éxito ("Venta registrada", Facturar / Ver en Ventas / Cerrar) y Facturar desde el éxito | `conv-exito-*`, `conv-exito-facturar-*`, `conv-facturar-{dialogo,resultado}-*` |
| Detalle de un presupuesto convertido ("Venta generada") y de uno vencido (Venta deshabilitada, con motivo) | `detalle-convertido-*`, `detalle-vencido-venta-deshabilitada-*` |
| `/ventas`: badge "Desde presupuesto P-…" y línea de servicio con su descripción y "Editar" deshabilitado | `ventas-badge-*`, `ventas-linea-servicio-*` |
| Cajero: detalle sin botón Venta | `detalle-cajero-sin-venta-desktop-light.png` |
| Regresión: formulario de venta y POS | `l-form-venta-*`, `l-pos-*` |

Desborde medido **por elemento** (contra el viewport y contra su card) y consola: 0 desbordes de
documento en las 44 capturas; el único elemento marcado es el contenedor con scroll horizontal
propio del detalle expandido de `/ventas` a 375 px (la tabla de cuatro columnas mide 460 px dentro
de 307: el nombre del producto ya no colapsa y el resto se desplaza dentro del contenedor). La
consola sólo registra los 404/409 esperados de los casos de error (caja cerrada y stock).

## Scripts (`scripts-b/`) y registros (`redteam-b/`)

`fb-setup.mjs` + `seed.sql` siembran, `fb-func.mjs`/`fb-func2.mjs` hacen el humo por la UI real
(a-l de 7.4), `fb-visual.mjs` la pasada de las 4 combinaciones, `fb-redteam.mjs` el red-team; `lib-b.mjs`, `fbh.mjs` y
`pwb-lib.mjs` son los helpers. Las contraseñas se leen de `QA_TEST_USER_PASSWORD`, `RT_PASS_SELLER`,
`RT_PASS_CASHIER` y `RT_PASS_TENANT_B`. Los registros: `humo-funcional-b.log` (42 verificaciones,
0 fallas), `visual-b.log` (36 verificaciones, 44 capturas) y `redteam-b.log` (**49 casos, 0 fallas**).

Qué cubre el red-team de la tanda B: ids ajenos en cada campo del payload (presupuesto de otra
cuenta, sucursal, forma de pago, cuenta bancaria, sesión de caja) → 404/422 y ningún efecto en
stock, caja, banco, órdenes ni eventos; replay con la misma clave (200 `replayed: true`, misma
venta) y clave sobre otro presupuesto (409 `idempotency_key_conflict`); sin `Idempotency-Key` → 422;
`expected_revision` ausente, 0 o vieja; campos extra tipo `skip_stock` ignorados; cajero → 403 y
vendedor → 200; rechazado/ya convertido/vencido → 409; producto dado de baja → 404; `rpc_accept_quote`
y `_quote_accept_core` por PostgREST como `authenticated` → 42501, `rpc_convert_quote_to_sale` como
`anon` → 401, y la firma pública no tiene ningún parámetro de stock; 10 conversiones concurrentes del
mismo presupuesto con claves distintas → exactamente 1 venta (stock −1 vez, un movimiento de caja,
9 × 409 sin 5xx) y con la misma clave → 1 nueva + 9 replays. **El caso "misma clave sobre dos
presupuestos en paralelo" encontró un deadlock real** (ver `CHANGES.md`): corregido y fijado por el
gate `supabase/tests/test_presupuesto_a_venta_race.sh` (4); 3 corridas completas del red-team
posteriores al arreglo, 49/49.
