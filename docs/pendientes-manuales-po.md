# Pendientes manuales del PO

> Documento vivo. Lo mantiene el orquestador: cada change que se mergea agrega acá lo que **sólo vos** podés hacer (demos reales en prod, decisiones de negocio, configuración en paneles de terceros). Lo que el agente puede verificar solo, no está acá.
>
> Convención: una sección por change o tema, con los pasos concretos y qué esperar en cada uno. Cuando lo hagas, marcá `[x]` o decime «pasó» / «falló en el paso N» y lo cierro.
>
> Última actualización: 2026-11-04.

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
| — | `edicion-operaciones-con-dinero` tanda A (huella neta, aging, consumidor contable; migración `20261088000001`; sin superficie: nada que probar a mano) | #__PR__ | en revisión |
| — | `edicion-operaciones-con-dinero` tanda B (edición con dinero) | — | pendiente |
| — | `edicion-operaciones-con-dinero` tanda C (superficie) | — | pendiente |
| — | Archive `edicion-operaciones-con-dinero` | — | pendiente |
