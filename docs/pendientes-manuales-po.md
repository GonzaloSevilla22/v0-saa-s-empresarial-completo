# Pendientes manuales del PO

> Documento vivo. Lo mantiene el orquestador: cada change que se mergea agrega acá lo que **sólo vos** podés hacer (demos reales en prod, decisiones de negocio, configuración en paneles de terceros). Lo que el agente puede verificar solo, no está acá.
>
> Convención: una sección por change o tema, con los pasos concretos y qué esperar en cada uno. Cuando lo hagas, marcá `[x]` o decime «pasó» / «falló en el paso N» y lo cierro.
>
> Última actualización: 2026-11-06.

---

## 1. `multiusuario-operativo` — demo real con un segundo usuario (task 18.4)

En prod desde el 2026-10-17 (PRs #651, #652, #653, #654; archivado en #655). Nadie usó todavía una invitación real: hoy hay 0 invitaciones y 0 emails de invitación en la historia. Necesitás un **segundo email propio** (el de tu familiar), distinto del tuyo.

- [x] 1. Desde tu cuenta: **Organización → Invitar miembro**, cargá el email y elegí los roles. Tiene que llegarle un email «Te invitaron a sumarte a un equipo» con el botón **Ver la invitación**.
- [x] 2. Que abra el link **sin sesión** (ventana de incógnito): tiene que ver un mensaje genérico, sin el nombre del negocio, con «Ingresar» y «Crear cuenta».
- [x] 3. Que elija «Crear cuenta» y se registre **con ese mismo email**. Al verificar el email vuelve solo a la invitación.
- [x] 4. Con sesión ve la vista previa (tu negocio, quién invita, roles, vencimiento). Al **Aceptar** cae en el Tablero de tu negocio y el selector de cuentas del menú muestra las dos (la suya y la tuya).
  - Nota (2026-11-06): el fix de cuenta cacheada al cambiar de negocio está en `main` desde #682 (Ventas y Stock mostraban la cuenta anterior). Repetí este paso estando parado en **Ventas** o **Productos** y también con «Nueva venta» abierta (2ª ronda #685: sucursal y caja), **recargando la página primero**.
- [x] 5. Que registre una **venta de prueba**: tiene que quedar en tu negocio, no en su cuenta personal. Después borrala.
- [x] 6. De vuelta en tu cuenta, en **Organización → Invitar miembro**: creá otra invitación a un email cualquiera, probá **Reenviar** (el link del primer email deja de servir) y **Revocar** (el link queda «no disponible»).
- [x] 7. Si todo pasó: decidí cuándo activar **«Enforce single session per user»** en el Dashboard de Supabase (Authentication → Settings). Con eso cada persona tiene que usar su propio usuario: dos dispositivos con el mismo login se desconectan entre sí.

**✅ DEMO REAL PASÓ (PO, 2026-11-06)**: los 7 pasos confirmados. El paso 4 falló dos veces en el camino (Ventas/Stock de la cuenta anterior → #682; «Sin sucursal disponible» y caja cerrada → #685) y pasó tras recargar con #685 desplegado. El paso 7 quedó hecho: **«Enforce single session per user» = ON** en el Dashboard de Supabase (Authentication → Sessions), con «Time-box user sessions» y «Inactivity timeout» en 0 (nunca). Desde ahora, dos dispositivos con el mismo login se desconectan entre sí: cada persona usa su propio usuario.

## 2. Humos reales pendientes de changes ya en prod

Cada uno es un chequeo de dos minutos. Son changes verificados en la base, pero sin tu prueba de uso real. **2026-11-06: los seis PASARON** (el sexto tras el fix #688) (sucursal por defecto en ventas, compras y gastos; marca en PDFs; saldo según libro; líneas de servicio).

- [x] **`ventas-sucursal-por-defecto`** (PR #627, 2026-10-10): hacé una venta por el formulario **sin elegir sucursal** → en el detalle tiene que figurar tu sucursal principal (nunca «sin sucursal»).
- [x] **`stock-movimientos-sucursal-origen`** (PR #631, 2026-10-11): abrí **Stock → Movimientos** y mirá un movimiento viejo de una venta o compra: tiene que mostrar la sucursal de origen.
  - **Falló el 2026-11-06 («no veo la sucursal en los movimientos»)**: no era una regresión — el change completó la sucursal en la base pero declaró «sin superficie frontend» y el panel nunca la mostró; el humo estaba mal redactado. Fix ad-hoc `stock-movimientos-sucursal-visible` (PR #688): cada movimiento muestra su sucursal (o «Sin sucursal» cuando el ledger no la registra) y el CSV gana la columna. **Repetí este chequeo con el fix desplegado (recargá primero).** → **PASÓ el 2026-11-06** con el fix #688 (`cda6bbfb`) desplegado.
- [x] **`compras-gastos-sucursal-por-defecto`** (PR #635, 2026-10-12): cargá una compra y un gasto **sin elegir sucursal** → los dos quedan en la principal.
- [x] **`documentos-marca-empresa`** (PRs #636/#638, 2026-10-11): configurá logo y datos de marca en Configuración y descargá un PDF (recibo, presupuesto o remito): tiene que salir con tu marca.
- [x] **`banco-saldo-segun-libro`** (PR #673, 2026-11-05): en **Banco**, elegí una cuenta real y comparé el **Saldo según libro** con el saldo de tu home banking (la diferencia debería ser sólo lo que todavía no cargaste o conciliaste).
- [x] **`v31-document-lines-consistency`** (PR #675): cargá una venta y una compra de **servicio** (sin producto) y verificá que aparecen normales en los listados y en Estadísticas; en `/clientes` el total de un cliente con ventas viejas de variantes ya no cuenta doble.

Ya probados por vos y cerrados: `balanza-etiquetas-pos`, `presupuestos-modulo`, `remitos-venta`, `remitos-compra` (2026-10-16).

## 3. Decisiones de negocio abiertas

- [x] **Cuenta `danielsevilla64`**: su plan Pro venció el 2026-10-09 y pasó a gratis por la regla general. Decidí si le das una cortesía (se configura desde `/admin`, exención o plan con vencimiento) o si queda en gratis.
  - **Decidido 2026-11-06: queda en gratis** («dejalo así»), sin cortesía.
- [x] **Candidatos de seguridad que dejó `multiusuario-operativo`** (ninguno es urgente; decidí si querés que los haga en un change chico): el token de invitación se guarda en claro en dos tablas; el dueño puede escribir invitaciones por PostgREST saltando la RPC (sólo en su propia cuenta); el token viaja en el path de la API; la lista no muestra entregas de email fallidas.
  - **Decidido 2026-11-06: hacerlo** («dale hacelo») → change `invitaciones-hardening` (propose en revisión; governance CRÍTICO, los cuatro candidatos en una sola tanda).

## 4. Externos (paneles de terceros)

- [x] **ARCA — homologación de la facturación electrónica** con el certificado real de producción (prerequisito para facturar de verdad a todos los clientes; hoy sólo Sumar factura real). (confirmado por el PO 2026-11-06)
- [x] **Supabase Auth — verificación de email**: revisar que «Confirm email» esté como lo querés en Authentication → Providers → Email (pendiente desde hace meses). (confirmado por el PO 2026-11-06)
- [x] **MercadoPago — cobro de noviembre** de la suscripción `fa624f9b-…` (tubecoventas6): la cuota de octubre se reparó a mano el 2026-10-14; la de noviembre debería acreditarse sola. Si no aparece en `/admin/pagos` la primera semana de noviembre, avisame y lo investigo. (confirmado por el PO 2026-11-06)

---

## 5. `edicion-operaciones-con-dinero` — humo real en prod (task 17.4)

Las tres tandas (#659 cimientos, #660 edición con dinero, #661 superficie) deshabilitaron el bloqueo por dinero: ahora se puede **editar** una venta, compra o gasto con cuenta corriente, caja o banco, y antes de guardar la pantalla muestra **qué se va a ajustar en cada libro**. Esto sólo lo podés probar vos, con datos reales. Usá operaciones **tuyas de prueba** (después las borrás) y mirá siempre tres cosas en cada caso: el **plan** del diálogo, los **libros** resultantes (Caja, Banco, cuenta corriente del cliente o proveedor) y el **«Historial de cambios»** del detalle de la operación.

- [x] 1. **Venta a crédito, subir el total y cambiar el vencimiento.** Cargá una venta a una cuenta corriente de un cliente de prueba, abrila con el lápiz, subí el total y cambiá el vencimiento. Al guardar tiene que aparecer el diálogo: «se revertirá el cargo de $X» + «se registrará un cargo de $Y, con vencimiento el …» + el saldo antes → después. Confirmá: el saldo del cliente queda en el total nuevo, el vencimiento es el elegido, y el historial muestra «Total $X → $Y».
- [x] 2. **Venta en efectivo del día.** Con la caja abierta, cargá una venta en efectivo tildando «Registrar en caja», editala (cambiá el importe): el diálogo dice que **salen** $X de la caja y **entran** $Y. En `/caja` el arqueo de hoy tiene que reflejar el cambio. Probá también destildar «Registrado en caja»: el efectivo sale de la caja y la venta queda sin movimiento de caja.
- [x] 3. **Compra por transferencia.** Cargá una compra por transferencia con cuenta bancaria, editala (cambiá el importe): el diálogo muestra el **egreso** nuevo y el movimiento inverso, ambos «pendientes de conciliar». En `/banco` tienen que aparecer los dos.
- [x] 4. **Gasto en efectivo de una sesión ya cerrada, con la caja de hoy abierta.** Elegí un gasto en efectivo de un día cuya caja ya cerraste, editá su importe: el diálogo tiene que decir que la corrección se asienta en la **sesión abierta de hoy** (no toca la cerrada). Cerrá la caja de hoy, repetí la edición y verificá que el diálogo **bloquea** con «Abrí la caja para poder corregir esta operación» y el botón de confirmar deshabilitado.
- [x] 5. **Rol.** Si tenés un usuario vendedor o cajero de prueba: sobre una operación con dinero registrado, el lápiz tiene que aparecer deshabilitado con «Solo el dueño o un administrador pueden corregir dinero ya registrado».

Si algo falla o el diálogo muestra algo que no coincide con los libros, decime el número de paso.

**✅ PASÓ (PO, 2026-11-06)**, los cinco casos con operaciones reales de prueba.

---

## 6. `v31-ia-ratelimit-budget` — límites de la lectura de facturas con IA (valores por defecto: aplican salvo que objetes)

Este change pone un tope a la lectura de facturas con IA (`/compras` → «Subir factura IA»). Hoy no tiene ninguno: cualquier usuario, incluso del plan gratis, puede dispararla sin límite, y es la llamada de IA más cara. Uso real: 2 facturas leídas en toda la historia y ninguna en los últimos 90 días, así que nadie se va a cruzar con estos límites.

- [x] **Lecturas de factura por mes y por usuario**: gratis **5** · inicial **30** · avanzado **120** · pro **300**, el mismo número que las consultas IA. Si querés otros números, decímelo; se cambian sin deploy (es una fila de `plan_limits`).
- [x] **Ráfaga**: como máximo **3 lecturas por minuto** por usuario. Una lectura que falla del lado de OpenAI **cuenta igual**, porque OpenAI la cobra igual.
- [x] **Tope de gasto en OpenAI** (recomendado, sólo lo podés hacer vos): en el panel de OpenAI → *Settings → Limits* del proyecto que usa la app, fijá un **tope mensual de gasto**. Te sugiero unos US$20 hoy, y lo ajustás cuando crezca el uso. Es la red de último recurso si algo se escapa. No bloquea el change.
- [ ] **Humo real del OCR con clave real de OpenAI** (sólo se hizo humo local con clave dummy): en `/compras` → «Subir factura IA», ver «Te quedan N lecturas…», leer una factura y verificar que el contador baja de N a N-1. Opcional: 4 lecturas en un minuto → aviso «Esperá N segundos». (pendiente: el PO no tiene una factura para probar (2026-11-06); queda abierto sin bloquear)

---

## 7. `v31-money-integration-tests` — volver obligatorio el check de CI (sólo lo podés hacer vos)

Este change hace que los tests contra una base real y los gates de dinero corran en cada PR y no puedan pasar en verde «salteándose». Hoy `main` no tiene ninguna regla de protección (medido el 2026-11-05), así que «obligatorio» depende de que se mergee sólo con la CI en verde.

- [ ] **Cuando el apply esté mergeado**: en GitHub → *Settings → Branches* (o *Rules → Rulesets*), creá una regla para `main` que exija el check **`validate-kpis`** (workflow «KPI Validation») antes de mergear. No marques `pytest` (Backend Tests) como obligatorio mientras tenga filtro de rutas: en los PRs que no tocan el backend quedaría «esperando» para siempre y bloquearía el merge. No bloquea el change.

---

## 8. `mp-cuota-acreditacion-resiliente` — cobro mensual de la suscripción (propose PR #677, apply PR #678)

- [x] **Antes del apply**: OK dado el 2026-11-05 («apague la pc asi que continua y avanza con todo lo recomendado») — las cinco OQs por la recomendada.
- [x] **Verificado post-merge en prod (orquestador, sólo lectura, 2026-11-05 22:13 UTC)**: migración `20261092000001` viva, job `subscription-reconcile-charges` activo y primera corrida real `succeeded` con respuesta 200. No hizo falta configurar nada: reutiliza los secretos del relay fiscal.
- [ ] **Humo real el 2026-12-04 (o al día siguiente)**: entrá a `/admin/pagos/ambiguas` → "Suscripciones recientes" y fijate en la fila de Aliadata Perfumes: **"Último cobro acreditado"** debe mostrar una fecha de diciembre y **"Plan vence"** ≈ 14/01/2027, **sin** que toques "Replicar cuotas". Anotá por qué camino se acreditó (barrido horario, notificación de la cuota o webhook `payment`). Si a las ~2 h del cobro no entró, tocá "Replicar cuotas" y avisame. Próximo cobro: 2026-12-04.

---

## 9. `productos-padre-variantes` — humo real de la tanda B (frontend; propose #679, tanda A #681, tanda B PR #683)

La tanda A (padre sin precio/costo, relabel de unidad, precios en lote) ya está en prod y verificada; la tanda B es la pantalla. Cuando el PR esté mergeado y desplegado, en `/productos` con la cuenta de un negocio real (dueño o administrador):

- [x] **Crear un producto con variantes**: «Nuevo producto» → «Producto con variantes» → completá nombre, categoría y unidad (por ejemplo kg) → «Crear y agregar variantes». Tiene que pasar solo a «Agregar la primera variante» con el padre ya fijado; el formulario del padre **no** debe mostrar precio, costo, stock, SKU, código de barras ni código de balanza. Cargá una variante con su precio y costo.
- [x] **Sugerencia × 1,5**: en esa variante (o en un producto simple) escribí un costo de 1.000 → el precio tiene que completarse con 1.500. Cambiá el precio a mano (1.700) y volvé a cambiar el costo: el precio **no** se pisa.
- [x] **Corregir la unidad de una familia con historia**: editá un padre cuyas variantes tengan stock → en lugar del selector de unidad tiene que aparecer «Corregir unidad». Elegí la unidad nueva: antes de confirmar tienen que verse las variantes, los productos con stock, los movimientos y un ejemplo con una cantidad real («12 u pasarán a leerse 12 kg»). Confirmá y revisá que el padre **y todas sus variantes** muestren la unidad nueva y que el stock siga igual (no se convierte ninguna cantidad). Con una familia que tenga ventas en otra unidad, el diálogo tiene que explicar el conflicto y no dejar confirmar.
- [x] **Aumentar precios de una selección**: tildá 3 o 4 productos (con un padre entre ellos) → «Modificar precios» → Aumentar, Porcentaje, 10 → «Ver vista previa» (revisá antes → después y el aviso de que el padre se omite) → «Aplicar cambio de precios». Los precios del listado tienen que cambiar y el padre debe seguir mostrando «desde $X» con el mínimo de sus variantes. Probá también que con un usuario que **no** sea dueño ni administrador la acción «Modificar precios» no aparezca.

---

**✅ PASÓ (PO, 2026-11-06)**: los cuatro pasos («funciona bien» en cada uno).

## Registro de la corrida autónoma del 2026-11-04 (lo que hizo el agente)

Se completa a medida que se mergea cada PR. Orden pactado: changes de a uno, siempre con la opción recomendada en cada OQ.

| Hora (UTC) | Qué | PR | Estado |
|---|---|---|---|
| 17:48 | Propose `edicion-operaciones-con-dinero` mergeado (las 6 OQs se resuelven por su opción recomendada, según tu indicación) | #644 | mergeado |
| 18:25 | Pin de la CLI de Supabase a 2.105.0 (la 3.0.0 rechaza `[inbucket]` y rompió playwright y el deploy) | #658 | mergeado |
| 18:25 | Este documento vivo de pendientes manuales | #657 | mergeado |
| 18:35 | Fix: el temporizador de descarga de `lib/excel.ts` no sobrevive a jsdom (flake de vitest en la CI de #654) | #656 | mergeado |
| 18:43 | `fix/importador-productos-stock-apertura`: el stock del archivo es de apertura, no pisa el saldo vivo (R1 de la auditoría de stock; migración `20261086000001`) | #645 | mergeado |
| 18:58 | `fix/stock-edicion-sucursal-y-piso`: editar valida el stock por sucursal, el piso deja un solo movimiento (R2/R4/R5; migración `20261087000001`; va antes del change por diseño) | #646 | mergeado |
| 19:40 | `edicion-operaciones-con-dinero` tanda A (huella neta, aging, consumidor contable; migración `20261088000001`; sin superficie: nada que probar a mano) | #659 | mergeado |
| 02:20 (5-nov) | `edicion-operaciones-con-dinero` tanda B (edición con dinero; migración `20261089000001`; sin superficie nueva: la ve la tanda C) | #660 | mergeado |
| 04:17 (5-nov) | `edicion-operaciones-con-dinero` tanda C (superficie: formularios de edición con dinero, diálogo del plan, historial de cambios; sin migración) | #661 | mergeado |
| 04:33 (5-nov) | Archive `edicion-operaciones-con-dinero` (specs sincronizadas, change cerrado) | #662 | mergeado |
| 04:52 (5-nov) | Propose v31-ia-ratelimit-budget (H-11: cuota y techo de costo del OCR) | #663 | mergeado |
| 06:04 (5-nov) | Apply v31-ia-ratelimit-budget (cuota mensual + ráfaga + techo por llamada del OCR; migración 20261090000001) | #664 | mergeado (07:00, 5-nov) |
| 07:05 (5-nov) | Archive v31-ia-ratelimit-budget (specs sincronizadas, change cerrado) | #665 | en revisión |
| 14:30 UTC (5-nov) | Fix: el temporizador del lector de código de barras no sobrevive al desmontaje (flake de vitest, chip del 17-10) | #670 | en revisión |
| 15:10 UTC (5-nov) | Fix: fecha real en el historial de compras del cliente (doble corrimiento de zona) + enlace a la venta | #674 (reemplaza al #672) | en revisión |
| 07:17 (5-nov) | Propose v31-money-integration-tests (H-34: tier de integración real contra Postgres en CI; todas las OQs por la recomendada) | #666 | en revisión |
| 08:20 UTC (5-nov) | Apply v31-money-integration-tests (tier de integración real contra Postgres en KPI_Validation + 33 gates de dinero estrictos; sin migración) | #667 | mergeado 08:41 |
| 08:52 UTC (5-nov) | Archive v31-money-integration-tests (spec integration-test-tier sincronizada, change cerrado) | #669 | en revisión |
| 14:48 UTC (5-nov) | Propose v31-document-lines-consistency (H-15: retiro del flag y la rama legacy, backfill de 6 documentos sin línea, invariante de líneas; OQs por la recomendada) | #671 | mergeado |
| 15:20 UTC (5-nov) | Feature: saldo según libro al elegir una cuenta en /banco (saldo inicial + movimientos, como caja) | #673 | en revisión |
| 16:30 UTC (5-nov) | Apply v31-document-lines-consistency (retiro del flag y la rama legacy, línea de servicio, backfill de 6 documentos y 79 líneas, name_snapshot NOT NULL, fix doble conteo en clientes; migración 20261091000001) | #675 | mergeado 16:20 |
| 16:45 UTC (5-nov) | Archive v31-document-lines-consistency (spec sale-line-items sincronizada, change cerrado) | #676 | en revisión |
| 16:55 UTC (5-nov) | Propose mp-cuota-acreditacion-resiliente (cobro mensual de suscripción sin depender de la notificación de la cuota: barrido horario + acelerador en el webhook `payment`; OQs por la recomendada, apply bloqueado a sign-off — governance CRÍTICO) | #677 | mergeado |
| 18:45 UTC (5-nov) | Apply mp-cuota-acreditacion-resiliente (núcleo único de reconciliación, barrido horario `pg_cron` + endpoint de máquina, acelerador en el webhook `payment`, lock por preapproval, logging INFO, dos columnas en `/admin/pagos/ambiguas`; migración 20261092000001; sign-off del PO 5-nov) | #678 | mergeado 22:10 UTC |
| 5-nov (tras #678) | Archive mp-cuota-acreditacion-resiliente (specs `payment-webhook` y `subscription-lifecycle` sincronizadas, change cerrado; humo real del cobro 2026-12-04 pendiente, §8) | #680 | en revisión |
| 22:25 UTC (5-nov) | Propose productos-padre-variantes (alta diferenciada padre/simple, padre sin precio/costo con CHECK, corrección de unidad de la familia sin convertir, precios en lote con vista previa, sugerencia costo × 1,5; migración reservada 20261093000001; OQs por la recomendada) | #679 | en revisión |
| 00:25 UTC (6-nov) | Apply tanda A productos-padre-variantes (padre sin precio/costo con CHECK, corrección de unidad de la familia sin convertir, precios en lote con vista previa; DB + backend, sin cambio visible; migración 20261093000001) | #681 | mergeado |
| 23:10 ART (5-nov) | Apply tanda B productos-padre-variantes (frontend: paso «¿Qué querés crear?», formularios de padre / simple / variante, sugerencia costo × 1,5, «Corregir unidad» con vista previa, «Modificar precios» en lote; sin migración; pasada visual en 4 combinaciones) | #683 | mergeado |
| 23:30 ART (5-nov) | Fix ad-hoc: al cambiar de negocio, Ventas y Stock mostraban la cuenta anterior (cache cargada con el token viejo; resincroniza antes de descartar; sin migración) | #682 | mergeado |
| 23:59 ART (5-nov) | Archive productos-padre-variantes (specs `product-variants` y `product-bulk-pricing` nuevas; `units-of-measure`, `product-sku`, `product-category` modificadas; change cerrado) | #684 | mergeado |
| 00:45 ART (6-nov) | Fix ad-hoc, 2ª ronda: «Sin sucursal disponible» y caja cerrada al cambiar de negocio (el descarte de caché corría antes del commit de React; ahora va en un efecto; sin migración). Recargar la página antes de probar | #685 | mergeado |
| 01:15 ART (6-nov) | Demo real de `multiusuario-operativo` PASÓ (7/7, segundo usuario real; `Enforce single session per user` activado por el PO) — sólo docs | PR de docs | mergeado |
| 01:40 ART (6-nov) | Humos §2: 5/6 PASARON; `stock-movimientos-sucursal-origen` falló por panel sin sucursal → fix ad-hoc `stock-movimientos-sucursal-visible` (sucursal por movimiento + columna CSV; sin migración) | #688 | en revisión |
| 12:21 ART (6-nov) | Propose invitaciones-hardening (token de invitación sólo como hash, `account_invitations` sólo por RPC, token fuera del path de la API (la URL pública se conserva por decisión del PO), estado de entrega del email en `/organizacion/invitar`; migración reservada 20261094000001; OQs por la recomendada, sign-off del PO «dale hacelo»). Docs: §3 decisiones del PO (danielsevilla64 queda en gratis; candidatos de seguridad → este change), §4 externos confirmados por el PO, §5 humo de `edicion-operaciones-con-dinero` PASÓ 5/5, §2 `stock-movimientos-sucursal-origen` PASÓ tras #688 | PR propose | en revisión |
| 13:05 ART (6-nov) | Explore `mejora-ia`: inventario de las funciones de IA, causas de por qué el Copilot exige preguntas específicas, opciones de modelo con costo y plan en 3 changes (`openspec/explore/2026-11-06-mejora-ia.md`; sólo análisis) | #690 | en revisión |
| 13:30 ART (6-nov) | Propose tablero-explicable (Tablero: gráfico de ventas con rango 7/30/90/personalizado y comparación desde la fuente canónica; las 9 tarjetas KPI abren «de dónde sale» con cruz; campana con descartar / ir a la alerta / cierre solo / marcar todas; Resumen IA con carga visible, error legible y sin gastar cuota por visita —el fix del campo va en el PR ad-hoc del orquestador—; 100 % frontend, sin migración; OQs por la recomendada) | PR propose | en revisión |
| 17:10 ART (6-nov) | Humo real de `productos-padre-variantes` (§9) PASÓ 4/4 — sólo docs | PR de docs | mergeado |
