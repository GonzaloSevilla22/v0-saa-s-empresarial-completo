# sucursal-guard-vaciado-auditoria — Proposal

## Why

El 22-08-2026 una usuaria real (owner de su cuenta) creó dos sucursales nuevas y desactivó la sucursal original desde el botón de papelera de `/sucursales`. Esa sucursal tenía **518 productos / 585 unidades** adentro. El sistema aceptó la baja en silencio: no existe ninguna verificación de que la sucursal esté vacía antes de desactivarla.

El efecto fue inmediato y no lo vio nadie. La sucursal por defecto de la cuenta se resuelve como *la más antigua que esté activa y abierta*; al quedar la original inactiva, todas las ventas pasaron a resolverse contra una sucursal nueva con 13 productos, y el resto del inventario quedó **existente pero inalcanzable**. El módulo de Stock seguía mostrando el total del catálogo, así que la usuaria veía su mercadería en pantalla mientras cada venta fallaba con "no hay stock". Su negocio entero quedó invendible durante dos días. Se reparó a mano el 24-08 (transferencia de las 585 unidades y baja definitiva de la sucursal ya vacía).

Cuando el PO quiso reconstruir qué había pasado, apareció el segundo agujero: **no hay forma de saber quién creó ni quién desactivó una sucursal**. La entidad no guarda autoría de ninguna clase y el registro de auditoría de la plataforma no recibe nada del ciclo de vida de sucursales. La reconstrucción se hizo por inferencia sobre marcas de tiempo.

Y el tercero: la transferencia de stock entre sucursales **ya existe y funciona**, pero vive enterrada tres niveles adentro (Sucursales → una sucursal → Stock → fila del producto). El PO, que conoce el sistema, creyó que la función no existía. Si la usuaria la hubiera encontrado, no habría necesitado desactivar nada.

Pedido textual del PO: *"si el usuario quiere borrar una sucursal debería tener que vaciarla antes de poder borrarla"*.

## What Changes

### G1 — Guard de vaciado (el corazón)

- Una sucursal **no puede darse de baja mientras tenga contenido operativo**: existencias distintas de cero en su inventario, una sesión de caja abierta, o transferencias de stock sin completar. El rechazo aplica a **las tres formas de baja** que hoy existen: la desactivación por comando, el cierre operacional, y el borrado físico de la fila.
- El guard vive en el **punto de paso obligado**: un disparador sobre la propia tabla de sucursales, no dentro de un comando. Hoy conviven cuatro caminos de escritura — el comando de desactivación, el comando de cierre, la actualización directa que hace el backend contra la tabla, y la escritura directa desde el navegador que las políticas de fila habilitan a quien tenga rol de escritura — y **sólo uno de los cuatro verifica algo**. El disparador los cubre a todos, presentes y futuros.
- **BREAKING (de dominio, intencional)**: desactivar una sucursal con existencias deja de ser posible. No hay datos históricos afectados: se verificó en producción que hoy hay **0** sucursales inactivas o cerradas con existencias.
- **El borrado físico de una sucursal queda prohibido de plano**, con contenido o sin él. El inventario por sucursal, las cajas y el historial de transferencias cuelgan de la sucursal **en cascada** y desaparecerían sin dejar rastro, mientras que los pedidos y los movimientos bancarios la referencian sin cascada y harían fallar el borrado con un error de integridad ilegible: hoy el borrado físico es mitad bomba de datos y mitad error críptico. La política de borrado ya adoptada por el proyecto excluye explícitamente a las sucursales del borrado lógico de maestros — la sucursal se desactiva, nunca se borra — pero eso está escrito y **no está aplicado**.
- El error informa **cuánto** contenido bloquea la baja (unidades y productos, sesión de caja, transferencias pendientes) y **nombra la acción que destraba**: transferir el stock. Código de error nuevo, censado libre contra el repositorio y contra las funciones vivas de producción.

### G2 — Autoría de sucursales

- La entidad sucursal gana **autoría de alta y de baja**: quién la creó, y quién y cuándo la desactivó. La FSM operacional (apertura/cierre) ya guarda sus marcas de tiempo pero tampoco guarda autor; se completa con el mismo criterio.
- El **ciclo de vida completo** (alta, edición, desactivación, reactivación, cierre, apertura) se registra además en el log de auditoría de la plataforma, que es lo único capaz de contestar "quién le cambió el nombre y cuándo": una columna de autoría sólo retiene al último.
- **Sin backfill**: las sucursales existentes quedan con autoría nula. No se puede inventar quién creó una fila de hace meses; se declara explícitamente en el modelo y se muestra como "no registrado" en la pantalla.

### G3 — Descubribilidad de la transferencia

- La transferencia de stock entre sucursales se ofrece **desde el módulo de Stock principal**, que es donde el usuario ya está cuando piensa en su inventario, **reutilizando el diálogo de transferencia que ya existe** — no se construye pantalla nueva ni lógica nueva.
- El mensaje de error de venta por falta de stock en la sucursal — que desde el 24-08 ya avisa que "puede haber unidades en otra sucursal" — gana un **camino directo** hacia la transferencia, en vez de dejar al usuario buscándola.
- La confirmación de desactivación de sucursal deja de decir sólo "los registros históricos se conservan" y pasa a mostrar **qué hay adentro** antes de que el usuario confirme.

## Capabilities

### New Capabilities

- `branch-decommission-guard`: precondición de vaciado para dar de baja una sucursal (desactivación, cierre y borrado físico), aplicada en el punto de paso obligado de la tabla; inventario del contenido bloqueante con mensaje accionable; prohibición del borrado físico.

### Modified Capabilities

- `branches`: el requisito de baja lógica gana la precondición de vaciado; la entidad gana autoría de alta y de baja; el ciclo de vida pasa a registrarse en el log de auditoría.
- `branch-stock`: la transferencia entre sucursales deja de estar confinada al inventario de una sucursal y se ofrece desde el módulo de Stock principal y desde el error de venta por falta de stock.

## Impact

**Base de datos** — una migración (número a confirmar contra producción en el momento del apply; el máximo verificado al proponer es `20261013000001`, 262 migraciones): columnas de autoría sobre `branches`, disparador de guard sobre `branches`, redefinición de `rpc_deactivate_branch` (sin cambio de firma) y del comando de cierre para que informen el contenido bloqueante con el mismo vocabulario, y registro de auditoría del ciclo de vida.

**Precondición nueva de esta era** — el Paso 2 de tenencia está encendido en producción desde el 24-08 y el backend corre como rol `authenticated`: toda columna nueva necesita que sus permisos y sus políticas de fila la alcancen, cosa que antes se resolvía sola porque el pool era dueño de las tablas.

**Backend** — `backend/repositories/branch_repository.py` (su actualización directa sobre la tabla pasa a cruzar el disparador), `backend/services/branches.py`, `backend/schemas/branches.py` (el modelo de salida hoy no expone ni el estado de actividad ni la dirección ni autoría), `backend/core/errors.py` (mapeo del código nuevo a su estado HTTP).

**Frontend** — `frontend/hooks/data/use-branches.ts` (traducción del error nuevo), `frontend/components/branches/BranchList.tsx` (confirmación informada y autoría visible), `frontend/app/(dashboard)/stock/page.tsx` con `frontend/components/branches/TransferStockModal.tsx` (descubribilidad, reutilizado sin reescribir), `frontend/lib/operation-errors.ts` (camino directo desde el error de venta).

**Sin impacto en datos históricos** — auditoría corrida en producción al proponer: 40 sucursales, 2 inactivas, **0** con existencias. No hay reparación pendiente.

**Governance**: MEDIUM. Toca inventario y ciclo de vida de sucursal; no toca dinero ni autorización.
