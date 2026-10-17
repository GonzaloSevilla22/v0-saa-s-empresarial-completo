# 03 — Actores y Roles

## Actores del Sistema

### 1. Emprendedor (Usuario Final)
- Microemprendedor de Mendoza, Argentina
- Puede tener plan `free` o plan `pro`
- Durante la beta: todos los usuarios tienen plan `pro` automáticamente
- Accede a las rutas de `(dashboard)` excepto las de `/admin/*`
- Gestiona sus propios datos (ventas, compras, gastos, productos, clientes)

### 2. Admin (Operador de la Plataforma)
- Operador interno de EmprendeSmart
- Tiene acceso total a todas las rutas incluyendo `/admin/*`
- Puede leer datos de todos los usuarios (via `auth.uid()` sin restricción de RLS en tablas admin)
- Gestiona: cursos, reuniones, pools de compra, landing, seguros, analytics de plataforma
- No puede leer datos financieros de usuarios en tablas con RLS (solo via RPC agregadas)

### 3. Sistema (sin actor humano)
- Supabase Webhooks y Triggers automáticos
- Dispara: alertas de stock bajo, emails de bienvenida, notificaciones de reuniones/pools
- Actúa con `service_role` (bypasa RLS)

---

## Tabla RBAC

| Recurso / Acción | Emprendedor Free | Emprendedor Pro | Admin |
|---|---|---|---|
| **Ventas** — CRUD propias | ✅ | ✅ | Solo lectura agregada |
| **Compras** — CRUD propias | ✅ | ✅ | Solo lectura agregada |
| **Gastos** — CRUD propias | ✅ | ✅ | Solo lectura agregada |
| **Productos** — CRUD (hasta 20) | ✅ (máx 20) | ✅ (ilimitado) | — |
| **Clientes** — CRUD (hasta 100) | ✅ (máx 100) | ✅ (ilimitado) | — |
| **Stock** — consulta e inventario | ✅ | ✅ | — |
| **Insights IA** | ✅ (máx 5/período) | ✅ (ilimitado) | Ver métricas uso |
| **Copiloto IA** | ✅ | ✅ | — |
| **Simulador IA** | Limitado | ✅ completo | — |
| **Fair Advisor** | ✅ | ✅ | Ver métricas |
| **OCR Facturas** | ✅ | ✅ | — |
| **Cursos** — ver | Solo básicos | Todos | CRUD completo |
| **Comunidad** — leer | ✅ | ✅ | ✅ + moderar |
| **Comunidad** — publicar | ❌ | ✅ | ✅ |
| **Reuniones** — ver | ✅ | ✅ | CRUD |
| **Pools de compra** — ver | ✅ | ✅ | CRUD |
| **Configuración** — perfil propio | ✅ | ✅ | — |
| **Admin métricas** | ❌ | ❌ | ✅ |
| **Admin cursos** | ❌ | ❌ | ✅ |
| **Admin landing** | ❌ | ❌ | ✅ |
| **Email logs** — leer | ❌ | ❌ | ✅ |

> **Nota**: Durante la beta actual (junio 2026), todos los emprendedores tienen plan `pro`. Las restricciones del plan `free` están definidas en `lib/constants.ts` pero aún no hay billing que habilite el downgrade.

---

## Campos de Rol y Plan en `profiles`

```sql
role  TEXT  DEFAULT 'user'   -- valores: 'user' | 'admin'
plan  TEXT  DEFAULT 'pro'    -- valores: 'free' | 'pro'
                              -- (default fue 'free', migration 20260424000001 lo cambió a 'pro' para beta)
```

## Cuenta activa (multiusuario-operativo, tanda A — 2026-10-16)

Un usuario puede pertenecer a **más de una cuenta**: su cuenta personal (la crea `handle_new_user` al registrarse) y los negocios a los que lo invitan. **Opera siempre sobre UNA — la cuenta activa — y es la misma en la base, en el token, en FastAPI, en las Edge Functions y en el frontend.**

- **Cómo se resuelve** (un único criterio, en la base: `current_account_ids()` → `resolve_active_account`): 1) la cuenta que declara el token (`app_metadata.account_id`), siempre que el usuario siga siendo miembro; 2) si el token no declara ninguna, la que el usuario eligió (`profiles.active_account_id`), mientras siga siendo una membresía; 3) si no, la membresía más antigua por `created_at` (a igual instante, la cuenta propia; luego `id`). **Un token que declara una cuenta de la que el usuario ya no es miembro NO cae en silencio a otra: no hay cuenta activa** (403 "No active account found").
- **Cómo se cambia**: selector en el encabezado del menú lateral (escritorio y drawer móvil), visible sólo con dos o más cuentas; muestra el nombre del negocio (la cascada de los documentos comerciales) y el rol propio en cada uno. Cambiar persiste la elección (`rpc_set_active_account`), renueva el token **ante el proveedor** (`refreshSessionAction`: releer el token vigente no alcanza, porque el hook sólo emite el claim al emitir; el hook emite `account_id`, roles y plan de la cuenta nueva), descarta la caché y lleva al Tablero. Las demás pestañas abiertas se resincronizan solas (señal `account:switched` del bus de sesión, sin token en el mensaje).
- **Pestaña desfasada**: el cliente declara en cada request a FastAPI la cuenta que muestra (`X-Account-Id`); si no coincide con la del token, `409 account_switched` y la pantalla se resincroniza — una escritura sin entidad (un gasto, una venta de servicio) nunca cae en la cuenta equivocada en silencio.
- **Lo que NO cambia para quien tiene una sola cuenta** (los 41 de hoy): el resultado es idéntico; el selector no se muestra.
- **Quién puede operar (tanda B, 2026-10-17)**: ver la sección siguiente. **Pendiente de este change**: la invitación de punta a punta (tanda C).

## Quién puede vender, comprar, editar y borrar (multiusuario-operativo, tanda B — 2026-10-17)

Las ocho operaciones del camino del dinero de ventas y compras (alta, edición y borrado de una venta y de una compra) se autorizan por **pertenencia a la cuenta activa y por rol**, nunca por quién cargó el producto o el documento. Hasta la tanda B un invitado no podía vender ni comprar un producto que cargó el dueño, y el dueño no podía corregir la venta del vendedor; y un observador con un producto propio vendía, compraba y borraba, porque las ocho no tenían ningún guard de rol en la base.

| Operación | Quién | Rechazo |
|---|---|---|
| Alta de una **venta** por formulario | `CAN_SELL`: dueño, administrador, vendedor, cajero | observador: `P0401`; contador, depósito, compras: `P0403 insufficient_role` |
| Alta de una **compra** con factura | `CAN_PURCHASE`: dueño, administrador, compras | observador: `P0401`; vendedor, cajero, **depósito** (recibe mercadería por remito), contador: `P0403` |
| **Editar o borrar** una venta / una compra **propia** | la capacidad del dominio (`CAN_SELL` / `CAN_PURCHASE`) | — |
| **Editar o borrar** una venta / una compra **de otro miembro** | sólo **dueño y administrador** (`CAN_MODIFY_ANY_DOCUMENT`) | el resto: `P0403 insufficient_role` |
| Un producto o un documento **de otra cuenta** (o de la cuenta no activa) | nadie | `P0404`, **indistinguible** de un id inexistente (no revela que existe en otra cuenta); borrar un documento ajeno responde `false`, como uno inexistente |

- **La base es la autoridad.** Cada RPC verifica la cuenta dentro de su propio `SELECT … FOR UPDATE` y el rol con `_account_assert_capability` antes de cualquier escritura; FastAPI repite la capacidad (`require_account_role`) y la interfaz oculta lo que el rol no habilita (la acción no se ofrece, no queda deshabilitada). Los conjuntos de roles se declaran una vez por capa y un test falla si divergen (`CAN_SELL`, `CAN_PURCHASE`, `CAN_MODIFY_ANY_DOCUMENT`).
- **La autoría se conserva.** `sales.user_id` / `purchases.user_id` se siguen escribiendo y **no se usan para autorizar**. Cuando el dueño o un administrador corrige lo que cargó otro miembro, las filas nuevas llevan al autor original (la edición reemplaza las líneas): el vendedor no pierde su venta.
- **Fuera de alcance de esta tanda**: el POS, los gastos, los cobros y pagos, el banco y el stock siguen con `is_account_writer` (su capacidad fina es un candidato: `pos-capacidad-venta`).

## Planes Comerciales (4 planes — fuente: tabla_resumen_planes_aliadata.docx)

| Límite | Gratis | Inicial | Avanzado ⭐ | PRO |
|---|---|---|---|---|
| Precio/mes | $0 | $24.900+IVA | $34.900+IVA | $69.900+IVA |
| Usuarios | 1 | 2 | 5 | 10 |
| Productos | 100 | 500 | 1.500 | 5.000 |
| Clientes | 50 | 250 | 1.000 | 3.000 |
| Proveedores | 20 | 100 | 300 | 1.000 |
| Operaciones/mes | 100 | 500 | 2.000 | 6.000 |
| Historial | 30 días | 12 meses | 24 meses | 5 años |
| Exportaciones/mes | 0 | 3 | 15 | 50 |
| Consultas IA/mes | 5 | 30 | 120 | 300 |
| Consejos IA/mes | 3 | 15 | 60 | 150 |
| Rentabilidad por producto | ❌ | ❌ | ✅ | ✅ |
| Reportes comparativos | ❌ | ❌ | ✅ | ✅ |
| Roles internos ⁽¹⁾ | Todos | Todos | Todos | Todos |
| Sucursales (módulo) | ❌ | ❌ | ❌ | ✅ |
| Sesión análisis mensual | ❌ | ❌ | ❌ | ✅ |

> ⭐ Plan recomendado en la propuesta comercial.
>
> ⁽¹⁾ **Roles internos** — v3-rbac-multirole Parte C (D17, sign-off del PO 2026-09-11, pregunta 6.2): el catálogo completo de 8 roles (`owner`, `admin`, `seller`, `cashier`, `stock`, `purchases`, `accountant`, `viewer`) está disponible en **todos** los planes. Esta fila decía antes "❌ / ❌ / Básicos / Avanzados" — esa restricción por plan quedó derogada; el único límite comercial que sigue vigente es la **cantidad de usuarios** (fila "Usuarios" arriba, `plan_limits.max_users`), no qué rol se les puede asignar.

> **Nota sobre el schema actual**: `profiles.plan` solo tiene `'free'` y `'pro'`. Deberá migrarse a los 4 valores reales al implementar billing. Los valores actuales de `lib/constants.ts` (maxProducts: 20 para free, Infinity para pro) serán reemplazados por la tabla anterior.

## Tracking de Uso IA (en `profiles`)

```sql
insights_used       INTEGER    DEFAULT 0        -- conteo acumulado de insights generados
insights_reset_at   TIMESTAMP  DEFAULT NOW()    -- última vez que se reseteó el contador
```

## RLS (Row Level Security) — Resumen por Tabla

| Tabla | Lectura | Escritura | Borrado |
|---|---|---|---|
| `profiles` | Propio o admin | Propio | No |
| `products` | Propio | Propio | Propio |
| `sales` | Propio | Propio (via RPC) | Propio |
| `purchases` | Propio | Propio (via RPC) | Propio |
| `expenses` | Propio | Propio | Propio |
| `clients` | Propio | Propio | Propio |
| `stock_movements` | Propio | Solo via RPC `SECURITY DEFINER` (grants de escritura revocados a `anon`/`authenticated`, sin policy de escritura — `stock-ledger-solo-rpc` 2026-10-09) | No |
| `branch_stock` | Propio | Solo via RPC `SECURITY DEFINER` (ídem); ajuste manual sólo `owner`/`admin`/`stock`, con motivo obligatorio | No |
| `ai_insights` | Propio | Propio | Propio |
| `ai_conversations` | Propio | Propio | Propio |
| `fair_recommendations` | Propio | Sistema | No |
| `posts` | Público | Auth | Propio o admin |
| `replies` | Público | Auth | Propio o admin |
| `courses` | Público | Admin | Admin |
| `course_progress` | Propio | Propio | No |
| `meetings` | Público | Admin | Admin |
| `purchase_pools` | Público | Admin | Admin |
| `analytics_events` | Admin | Auth (propio) | No |
| `email_logs` | Admin | Sistema | No |
| `invoice_documents` | Propio | Propio | Propio |
| `operation_idempotency` | Propio | Solo via RPC | No |

## Rutas Públicas (sin autenticación)

- `/` — Landing page
- `/landing` — Versión alternativa de landing
- `/auth/login`
- `/auth/register`
- `/auth/forgot-password`
- `/auth/reset-password`
- `/auth/verify-email`

## Middleware de Autenticación

`middleware.ts` corre en todas las rutas excepto:
- `/_next/static/*`
- `/_next/image/*`
- `/favicon.ico`
- Archivos de media

Llama a `updateSession()` para refrescar el token JWT de Supabase en cada request.

## Futuros Roles (Planificados, no implementados)

Según el usuario, se planean más roles en el futuro (pendiente de documentación — ver `10_preguntas_abiertas.md`).
