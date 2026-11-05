# Pendientes manuales del PO

> Documento vivo. Lo mantiene el orquestador: cada change que se mergea agrega acá lo que **sólo vos** podés hacer (demos reales en prod, decisiones de negocio, configuración en paneles de terceros). Lo que el agente puede verificar solo, no está acá.
>
> Convención: una sección por change o tema, con los pasos concretos y qué esperar en cada uno. Cuando lo hagas, marcá `[x]` o decime «pasó» / «falló en el paso N» y lo cierro.
>
> Última actualización: 2026-11-05.

---

## 1. `multiusuario-operativo` — demo real con un segundo usuario (task 18.4)

En prod desde el 2026-10-17 (PRs #651, #652, #653, #654; archivado en #655). Nadie usó todavía una invitación real: hoy hay 0 invitaciones y 0 emails de invitación en la historia. Necesitás un **segundo email propio** (el de tu familiar), distinto del tuyo.

- [ ] 1. Desde tu cuenta: **Organización → Invitar miembro**, cargá el email y elegí los roles. Tiene que llegarle un email «Te invitaron a sumarte a un equipo» con el botón **Ver la invitación**.
- [ ] 2. Que abra el link **sin sesión** (ventana de incógnito): tiene que ver un mensaje genérico, sin el nombre del negocio, con «Ingresar» y «Crear cuenta».
- [ ] 3. Que elija «Crear cuenta» y se registre **con ese mismo email**. Al verificar el email vuelve solo a la invitación.
- [ ] 4. Con sesión ve la vista previa (tu negocio, quién invita, roles, vencimiento). Al **Aceptar** cae en el Tablero de tu negocio y el selector de cuentas del menú muestra las dos (la suya y la tuya).
- [ ] 5. Que registre una **venta de prueba**: tiene que quedar en tu negocio, no en su cuenta personal. Después borrala.
- [ ] 6. De vuelta en tu cuenta, en **Organización → Invitar miembro**: creá otra invitación a un email cualquiera, probá **Reenviar** (el link del primer email deja de servir) y **Revocar** (el link queda «no disponible»).
- [ ] 7. Si todo pasó: decidí cuándo activar **«Enforce single session per user»** en el Dashboard de Supabase (Authentication → Settings). Con eso cada persona tiene que usar su propio usuario: dos dispositivos con el mismo login se desconectan entre sí.

Si algo falla, decime el número de paso: va en un PR de fix aparte.

## 2. Humos reales pendientes de changes ya en prod

Cada uno es un chequeo de dos minutos. Son changes verificados en la base, pero sin tu prueba de uso real.

- [ ] **`ventas-sucursal-por-defecto`** (PR #627, 2026-10-10): hacé una venta por el formulario **sin elegir sucursal** → en el detalle tiene que figurar tu sucursal principal (nunca «sin sucursal»).
- [ ] **`stock-movimientos-sucursal-origen`** (PR #631, 2026-10-11): abrí **Stock → Movimientos** y mirá un movimiento viejo de una venta o compra: tiene que mostrar la sucursal de origen.
- [ ] **`compras-gastos-sucursal-por-defecto`** (PR #635, 2026-10-12): cargá una compra y un gasto **sin elegir sucursal** → los dos quedan en la principal.
- [ ] **`documentos-marca-empresa`** (PRs #636/#638, 2026-10-11): configurá logo y datos de marca en Configuración y descargá un PDF (recibo, presupuesto o remito): tiene que salir con tu marca.

Ya probados por vos y cerrados: `balanza-etiquetas-pos`, `presupuestos-modulo`, `remitos-venta`, `remitos-compra` (2026-10-16).

## 3. Decisiones de negocio abiertas

- [ ] **Cuenta `danielsevilla64`**: su plan Pro venció el 2026-10-09 y pasó a gratis por la regla general. Decidí si le das una cortesía (se configura desde `/admin`, exención o plan con vencimiento) o si queda en gratis.
- [ ] **Candidatos de seguridad que dejó `multiusuario-operativo`** (ninguno es urgente; decidí si querés que los haga en un change chico): el token de invitación se guarda en claro en dos tablas; el dueño puede escribir invitaciones por PostgREST saltando la RPC (sólo en su propia cuenta); el token viaja en el path de la API; la lista no muestra entregas de email fallidas.

## 4. Externos (paneles de terceros)

- [ ] **ARCA — homologación de la facturación electrónica** con el certificado real de producción (prerequisito para facturar de verdad a todos los clientes; hoy sólo Sumar factura real).
- [ ] **Supabase Auth — verificación de email**: revisar que «Confirm email» esté como lo querés en Authentication → Providers → Email (pendiente desde hace meses).
- [ ] **MercadoPago — cobro de noviembre** de la suscripción `fa624f9b-…` (tubecoventas6): la cuota de octubre se reparó a mano el 2026-10-14; la de noviembre debería acreditarse sola. Si no aparece en `/admin/pagos` la primera semana de noviembre, avisame y lo investigo.

---

## 5. `edicion-operaciones-con-dinero` — humo real en prod (task 17.4)

Las tres tandas (#659 cimientos, #660 edición con dinero, #661 superficie) deshabilitaron el bloqueo por dinero: ahora se puede **editar** una venta, compra o gasto con cuenta corriente, caja o banco, y antes de guardar la pantalla muestra **qué se va a ajustar en cada libro**. Esto sólo lo podés probar vos, con datos reales. Usá operaciones **tuyas de prueba** (después las borrás) y mirá siempre tres cosas en cada caso: el **plan** del diálogo, los **libros** resultantes (Caja, Banco, cuenta corriente del cliente o proveedor) y el **«Historial de cambios»** del detalle de la operación.

- [ ] 1. **Venta a crédito, subir el total y cambiar el vencimiento.** Cargá una venta a una cuenta corriente de un cliente de prueba, abrila con el lápiz, subí el total y cambiá el vencimiento. Al guardar tiene que aparecer el diálogo: «se revertirá el cargo de $X» + «se registrará un cargo de $Y, con vencimiento el …» + el saldo antes → después. Confirmá: el saldo del cliente queda en el total nuevo, el vencimiento es el elegido, y el historial muestra «Total $X → $Y».
- [ ] 2. **Venta en efectivo del día.** Con la caja abierta, cargá una venta en efectivo tildando «Registrar en caja», editala (cambiá el importe): el diálogo dice que **salen** $X de la caja y **entran** $Y. En `/caja` el arqueo de hoy tiene que reflejar el cambio. Probá también destildar «Registrado en caja»: el efectivo sale de la caja y la venta queda sin movimiento de caja.
- [ ] 3. **Compra por transferencia.** Cargá una compra por transferencia con cuenta bancaria, editala (cambiá el importe): el diálogo muestra el **egreso** nuevo y el movimiento inverso, ambos «pendientes de conciliar». En `/banco` tienen que aparecer los dos.
- [ ] 4. **Gasto en efectivo de una sesión ya cerrada, con la caja de hoy abierta.** Elegí un gasto en efectivo de un día cuya caja ya cerraste, editá su importe: el diálogo tiene que decir que la corrección se asienta en la **sesión abierta de hoy** (no toca la cerrada). Cerrá la caja de hoy, repetí la edición y verificá que el diálogo **bloquea** con «Abrí la caja para poder corregir esta operación» y el botón de confirmar deshabilitado.
- [ ] 5. **Rol.** Si tenés un usuario vendedor o cajero de prueba: sobre una operación con dinero registrado, el lápiz tiene que aparecer deshabilitado con «Solo el dueño o un administrador pueden corregir dinero ya registrado».

Si algo falla o el diálogo muestra algo que no coincide con los libros, decime el número de paso.

---

## 6. `v31-ia-ratelimit-budget` — límites de la lectura de facturas con IA (valores por defecto: aplican salvo que objetes)

Este change pone un tope a la lectura de facturas con IA (`/compras` → «Subir factura IA»). Hoy no tiene ninguno: cualquier usuario, incluso del plan gratis, puede dispararla sin límite, y es la llamada de IA más cara. Uso real: 2 facturas leídas en toda la historia y ninguna en los últimos 90 días, así que nadie se va a cruzar con estos límites.

- [ ] **Lecturas de factura por mes y por usuario**: gratis **5** · inicial **30** · avanzado **120** · pro **300**, el mismo número que las consultas IA. Si querés otros números, decímelo; se cambian sin deploy (es una fila de `plan_limits`).
- [ ] **Ráfaga**: como máximo **3 lecturas por minuto** por usuario. Una lectura que falla del lado de OpenAI **cuenta igual**, porque OpenAI la cobra igual.
- [ ] **Tope de gasto en OpenAI** (recomendado, sólo lo podés hacer vos): en el panel de OpenAI → *Settings → Limits* del proyecto que usa la app, fijá un **tope mensual de gasto**. Te sugiero unos US$20 hoy, y lo ajustás cuando crezca el uso. Es la red de último recurso si algo se escapa. No bloquea el change.
- [ ] **Humo real del OCR con clave real de OpenAI** (sólo se hizo humo local con clave dummy): en `/compras` → «Subir factura IA», ver «Te quedan N lecturas…», leer una factura y verificar que el contador baja de N a N-1. Opcional: 4 lecturas en un minuto → aviso «Esperá N segundos».

---

## 7. `v31-money-integration-tests` — volver obligatorio el check de CI (sólo lo podés hacer vos)

Este change hace que los tests contra una base real y los gates de dinero corran en cada PR y no puedan pasar en verde «salteándose». Hoy `main` no tiene ninguna regla de protección (medido el 2026-11-05), así que «obligatorio» depende de que se mergee sólo con la CI en verde.

- [ ] **Cuando el apply esté mergeado**: en GitHub → *Settings → Branches* (o *Rules → Rulesets*), creá una regla para `main` que exija el check **`validate-kpis`** (workflow «KPI Validation») antes de mergear. No marques `pytest` (Backend Tests) como obligatorio mientras tenga filtro de rutas: en los PRs que no tocan el backend quedaría «esperando» para siempre y bloquearía el merge. No bloquea el change.

---

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
| 15:10 UTC (5-nov) | Fix: fecha real en el historial de compras del cliente (doble corrimiento de zona) + enlace a la venta | #PRNUM | en revisión |
| 07:17 (5-nov) | Propose v31-money-integration-tests (H-34: tier de integración real contra Postgres en CI; todas las OQs por la recomendada) | #666 | en revisión |
| 08:20 UTC (5-nov) | Apply v31-money-integration-tests (tier de integración real contra Postgres en KPI_Validation + 33 gates de dinero estrictos; sin migración) | #667 | mergeado 08:41 |
| 08:52 UTC (5-nov) | Archive v31-money-integration-tests (spec integration-test-tier sincronizada, change cerrado) | #669 | en revisión |
