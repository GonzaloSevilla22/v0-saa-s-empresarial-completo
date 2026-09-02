## Context

### Lo que está medido contra producción (2026-09-02)

Todo lo que sigue se verificó contra el `pg_get_functiondef` **vivo** de producción (`gxdhpxvdjjkmxhdkkwyb`) vía `mcp__supabase__execute_sql` (SELECT, read-only), no contra los archivos de migración del repo. Es la regla de la casa desde `metodos-pago-operaciones`: el cuerpo vivo y el último archivo de migración **divergieron al menos una vez**, y el checkpoint que lo atrapó fue el hash.

| Función | Rol en este change | md5 del functiondef | chars |
|---|---|---|---|
| `rpc_register_payment_received` | **se reescribe** (firma + ruteo) | `4d5de67480d67d064c1fba1198c9c6e3` | 7.656 |
| `rpc_register_payment_made` | **se reescribe** (firma + ruteo) | `07acdadbbcab5eb3086e31e0f055067f` | 6.751 |
| `_pay_register_operation_bank_movement` | **helper adoptado**, sin tocar | `89bd5f041fbee39a44925d1f3aff61c6` | 3.231 |
| `c28_register_cash_movement` | helper reusado tal cual | `1b0692ad5ba614f267389b335e4d366a` | 4.413 |
| `c30_get_or_create_customer_account` | helper reusado tal cual | `8e0f0907ebac4fc23e40671b12033b6b` | 1.199 |
| `rpc_reverse_payment_received` | **NO se toca** — ver D7 | `7f042df098a007a4fa9da8f4682223a8` | 7.483 |
| `rpc_reverse_payment_made` | **NO se toca** — ver D7 | `1c1ea81b9157d7e74cb838a6b1cf3590` | 5.158 |
| `_journal_post_from_event` | **NO se toca** — ver D8 | `1106ce7750c94f2e01e4752726411051` | 38.173 |
| `rpc_register_supplier_charge` | no se toca (firma vecina en el gate) | `4337a5fea2e3deddb59e6d693280a5b4` | 3.831 |

### Estado de los datos

| Medición | Valor |
|---|---|
| `payments_received` / `payments_made` | **6** / **1** |
| ...con `payment_method` (text) poblado | **0 de 7** |
| `payment_methods` totales | **266** = 38 cuentas × **7 kinds**, **todas activas** |
| ...con `bank_account_id` configurado | **0 de 266** |
| Sesiones de caja abiertas | 4 |
| Última migración (`origin/main` **y** prod) | `20261019000001` (268 filas) |
| Tablas con `payment_method_id` | `sales`, `purchases`, `expenses`, `sales_orders` |
| Tablas con `payment_method` **text** | **sólo** `payments_received`, `payments_made` |

**Las tres mediciones que gobiernan el diseño:**

1. **`payment_method` (text) es NULL en el 100% de las 7 filas.** La columna nació el 2026-09-01 (OQ-1 de `caja-compras-cobranzas`) y nunca se pobló porque los pagos son anteriores. **No hay dato que migrar**: el "sin backfill" de este change no es una renuncia sino una constatación (D3).
2. **Las otras cuatro tablas ya convergieron** a `payment_method_id` y su columna de texto fue **dropeada** por `limpiezas-pagos-admin`. Conservar la de cobros sería dejar viva la única excepción del sistema, justo cuando está vacía.
3. **Los 38 tenants tienen los 7 kinds sembrados y activos**, `wallet` incluido. La restricción a 4 no protege ningún dato: excluye opciones que el usuario ya tiene configuradas.

### El texto exacto que este change deroga

`openspec/specs/payment-method/spec.md`, requirement *"Vocabulario cerrado de `kind`"*:

> El CHECK de las RPCs de cobro/pago (`{cash, transfer, card, check}`) sigue siendo un subconjunto propio, sin tocar.

Esa cláusula era la excepción declarada. Este change la retira; es el motivo de que el delta de `payment-method` sea `MODIFIED` y no un agregado.

### Constraints vivos que el diseño respeta

- **No existe ningún CHECK** sobre `payments_received.payment_method` ni sobre `payments_made.payment_method` (verificado en `pg_constraint`: cero filas). La taxonomía de 4 vive **sólo** en el cuerpo de las dos RPCs y en el validador Pydantic. No hay constraint que ampliar ni que dropear — hay dos listas hardcodeadas que retirar.
- `payment_methods_kind_check` con los 7 valores es el **único** lugar donde vive el vocabulario del sistema (requirement vigente de `payment-method`).
- **DEC-24**: la unidad de trabajo es la RPC `SECURITY DEFINER`.
- **Regla de reutilización (PO 2026-08-02)**: `PaymentMethodSelect`, `useCashOptin`, `_pay_register_operation_bank_movement`, `c28_register_cash_movement`. Cero paralelos.

## Goals / Non-Goals

**Goals:**

1. Que cobrar una cuenta corriente y pagar a un proveedor ofrezcan **el mismo catálogo de formas de pago** que la venta, la compra y el gasto, con los nombres que el tenant configuró.
2. Que el `kind` que dispara los efectos (caja, banco) se **derive en el servidor** desde `payment_method_id`, nunca se acepte como texto del cliente.
3. Que un cobro por billetera virtual (`wallet`) sea registrable sin mentir sobre la forma de pago.
4. Que los cobros y pagos entren al reporte `/reportes/formas-pago`, del que hoy están estructuralmente excluidos.
5. Que la anulación de un cobro siga funcionando **exactamente igual**, y que eso quede probado por un gate y no por confianza.

**Non-Goals:**

1. **Tocar las RPCs de reverso.** No cambian de firma ni de cuerpo (D7).
2. **Asiento contable de cobros.** Ya existe y no cambia: `_journal_post_from_event` no gana ni pierde ramas (D8).
3. **Backfill.** No hay dato que backfillear (D3).
4. **Configurar destinos bancarios por defecto** en las 266 formas de pago. Sigue siendo 0/266 y este change no lo cambia: el cobro exige cuenta bancaria explícita, que es más estricto que el default (D4).
5. **Cambiar el opt-in de caja de pre-marcado a destildado** ni sus dos condiciones. Firmado por el PO el 2026-09-01.
6. **Unificar el modal de cobro con el de pago** en un componente compartido. Son dos archivos espejo hoy y siguen siéndolo; fusionarlos es refactor, no unificación de catálogo.

## Decisions

### D1 — La firma cambia el tipo del 5.º parámetro, y se aplica con `DROP` + `CREATE`

**Decisión.** `p_payment_method text` → `p_payment_method_id uuid` en la misma posición. La aridad sigue siendo 7. La migración hace `DROP FUNCTION` de la firma anterior **antes** del `CREATE`.

```
ANTES: (text, uuid, numeric, uuid, text, uuid, uuid)
AHORA: (text, uuid, numeric, uuid, uuid, uuid, uuid)
```

**Por qué el `DROP` es obligatorio y no una precaución.** Postgres identifica una función por `(nombre, tipos de argumentos)`. Un `CREATE OR REPLACE` con un tipo distinto **no reemplaza nada**: crea un **overload**. Quedarían dos definiciones vivas, y como los dos tipos son distintos pero ambos aceptan un literal sin casteo explícito, la resolución de sobrecarga puede fallar con `42725 function is not unique` o —mucho peor— resolver silenciosamente a la versión vieja, dejando el backend llamando a una función que ya nadie mantiene. Es el gotcha `42725` registrado en la memoria del proyecto y el mismo `DROP` explícito que `caja-compras-cobranzas` (D6) usó anteayer sobre estas dos mismas funciones.

**Por qué el parámetro no se agrega al final dejando el viejo.** Mantener `p_payment_method text` *y* sumar `p_payment_method_id uuid` daría dos fuentes para el mismo dato y exigiría un guard de coherencia entre ambas — exactamente el escenario *"El kind se deriva en el servidor"* que la spec `payment-method` ya declara como incoherencia a rechazar. Se cambia el tipo en el lugar, no se acumula.

**`REVOKE` en la misma migración.** Un `DROP`+`CREATE` **resetea las ACLs**: la función renace con el `EXECUTE` por defecto de `PUBLIC`. La migración incluye `REVOKE` de `PUBLIC`, `anon` **y** `authenticated`, y `GRANT` selectivo. No alcanza con revocar el pseudo-rol público: el proyecto hospedado otorga `EXECUTE` a los roles de aplicación de forma directa. Lección ya registrada en `project_advisor_0028_backlog` y verificada por el gate de ACLs.

### D2 — Los kinds aceptados pasan a **6 de 7**: `credit` se rechaza, `wallet` y `other` se suman

**Decisión.** El guard de taxonomía de las dos RPCs pasa de una lista literal de 4 strings a la derivación del `kind` desde el catálogo, con un único rechazo explícito:

| `kind` | Cobro / Pago | Efecto | Fundamento |
|---|---|---|---|
| `cash` | ✅ | caja, bajo opt-in de 2 condiciones | sin cambios |
| `transfer` | ✅ | `bank_movement` (`transfer_in`/`out`) | sin cambios |
| `card` | ✅ | `bank_movement` (`card_settlement`) | sin cambios |
| `check` | ✅ | `bank_movement` (`transfer_in`/`out`) | sin cambios |
| `wallet` | ✅ **nuevo** | `bank_movement` (`transfer_in`/`out`) | ya es kind bancario en **todo** el resto del sistema |
| `other` | ✅ **nuevo** | **etiqueta pura**, ningún libro | *"El `kind = 'other'` SHALL comportarse siempre como etiqueta"* (spec vigente) |
| `credit` | ❌ **`P0400`** | rechazado | ver abajo |

**Por qué `wallet` entra, y por qué no es una decisión discutible.** No se está inventando una semántica: `wallet` **ya está** en `v_is_bank_kind` de `_pay_register_operation_bank_movement`, **ya está** en `isBankPaymentKind` del frontend, y `pagos-cableados-restantes` **ya lo rutea** a `1110 Banco` en el consumidor contable. La cobranza es el único subsistema que lo desconoce, y lo desconoce por omisión histórica: la taxonomía de 4 se escribió en `bank-payment-routing` (2026-08-04), **quince días antes** de que existiera el catálogo con sus 7 kinds. Excluirlo hoy no protege nada — obliga al usuario a elegir "Transferencia" para un cobro por Mercado Pago, produciendo un `bank_movement` con una etiqueta falsa.

**Por qué `credit` se rechaza con `P0400`.** Cobrar una cuenta corriente **con** cuenta corriente es circular: el cobro *reduce* la deuda del cliente (`c30_register_customer_account_movement` con importe negativo) y `kind='credit'` significa *aumentarla*. No es una limitación técnica a levantar más adelante: es un hecho económico que el modelo no admite. Es el mismo rechazo, con el mismo ERRCODE y por el mismo tipo de razón, que `gastos-forma-pago` (D3) aplicó al gasto —*"un gasto no tiene contraparte con cuenta corriente"*—, y el precedente ya dejó el molde de las dos capas: **el selector no lo ofrece** (`paymentMethodOptionsFor`) **y el servidor lo rechaza igual**, para que la API no sea un bypass de la UI.

**Por qué `other` entra en vez de rechazarse.** Un cobro en especie, con un vale o por un canal que el tenant no modeló es un hecho real, y hoy el usuario no tiene cómo registrarlo salvo mintiendo con "Efectivo" —que, con el opt-in pre-marcado, **le inyectaría plata inexistente en el arqueo** y contaminaría la `difference` que RN-95 usa como señal antifraude. Admitir `other` como etiqueta pura es estrictamente más seguro que la alternativa de hoy.

**Alternativa considerada y descartada:** aceptar los 7 y dejar que `credit` se comporte como etiqueta (como `other`). Rechazada porque *parecería* funcionar: el cobro se registraría, la deuda bajaría, y la forma de pago diría "Cuenta corriente" — una fila que se lee como un cargo y es un pago. La ambigüedad silenciosa es peor que el error explícito.

### D3 — La columna de texto se **reemplaza**, no convive

**Decisión.** `payments_received.payment_method text` y su espejo se **dropean**; entra `payment_method_id uuid NULL REFERENCES payment_methods(id)`.

**Por qué se puede dropear sin ceremonia.** **0 de 7 filas** la tienen poblada (medido). No existe una sola fila de producción cuyo dato se pierda. La columna nació anteayer con `caja-compras-cobranzas` (OQ-1) y su justificación era *"para que el detalle de la cuenta corriente pueda decir cómo se cobró"* — objetivo que `payment_method_id` cumple **mejor**, porque además da el nombre configurado por el usuario y la entrada al reporte.

**Por qué no conviven las dos (snapshot de texto + FK).** El patrón de snapshot de `v3-snapshot-pattern` existe para que un documento recuerde el nombre/precio/IVA que tenía al emitirse, aunque el maestro cambie después. Acá no aplica, por dos razones concretas:
1. **La baja del catálogo es desactivación, no borrado** (requirement vigente de `payment-method`: *"La baja es desactivación y preserva la imputación histórica"*), y el `PaymentMethodSelect` ya tiene `includeInactive` justamente para que un documento imputado a un método dado de baja siga siendo legible. La FK nunca queda colgada.
2. **Ninguna de las otras cuatro tablas guarda snapshot de texto.** `sales`, `purchases`, `expenses` y `sales_orders` tienen sólo la FK. Un snapshot en cobros sería una asimetría sin precedente ni consumidor.

`NULL` sigue siendo válido y significa lo mismo que en las otras cuatro tablas: sin imputar. Los 7 históricos quedan así.

**El FK no lleva `ON DELETE`.** Ningún camino borra una forma de pago del catálogo (la baja es desactivación); dejar el default `NO ACTION` es la salvaguarda correcta.

### D4 — El ruteo bancario **adopta el helper compartido** y conserva el guard estricto de cuenta

**Decisión.** El bloque de ruteo bancario inline de las dos RPCs —hoy un `CASE` propio sobre `p_payment_method` que llama al escritor crudo `_register_bank_movement`— se reemplaza por una llamada a `_pay_register_operation_bank_movement`, el helper que la venta, la compra y el gasto ya usan. **Y se conserva** el guard vigente que exige `p_bank_account_id` para todo kind bancario (`P0400 bank_account_required`).

**Por qué el helper, más allá de la regla de reutilización.** Los tres beneficios son concretos y verificados en su cuerpo vivo:
- **`wallet` sale gratis.** El mapa `kind → movement_type` del helper ya cubre los cuatro kinds bancarios. Sin él, D2 obligaría a extender a mano el `CASE` de cada RPC — dos copias más del mapa que ya está escrito.
- **Aporta el guard de período conciliado (`P0424`) que las RPCs de cobro hoy NO tienen.** Un cobro puede postearse hoy con `value_date` dentro de un período de conciliación ya cerrado y firmado, corrompiéndolo en silencio. Adoptar el helper lo cierra **sin escribir una línea** de ese guard.
- **Rechaza `bank_account_id` informado junto a un kind no bancario** (`P0400`), un guard de payload que si no habría que escribir dos veces.

**Por qué se conserva el guard estricto de cuenta bancaria, aunque el helper tenga fallback.** El helper resuelve la cuenta por `override → default del método → NULL` y, si no resuelve, hace `RETURN NULL` **sin error**. Con **0 de 266** formas de pago con `bank_account_id` configurado, apoyarse en el default significaría que **ningún cobro bancario de ningún tenant escribiría su movimiento**, en silencio. Es exactamente el hallazgo que cambió el diseño de `gastos-forma-pago` (D5: *"con el destino sin resolver el helper hace `RETURN NULL` sin error, así que el pedido literal del PO habría fallado en silencio para el 100% de los tenants"*). Manteniendo el `P0400` vigente, `p_bank_account_id` nunca llega NULL para un kind bancario y el fallback nunca se ejerce. **El comportamiento observable de los kinds que ya funcionaban no cambia.**

**Compatibilidad con el reverso, verificada.** `rpc_reverse_payment_received` invierte los tipos con `transfer_in → transfer_out`, `transfer_out → transfer_in`, `ELSE mismo tipo`. El helper produce exactamente `transfer_in`, `transfer_out` y `card_settlement` — los tres contemplados. `wallet` produce `transfer_in`, que la tabla invierte correctamente. **Ningún tipo nuevo llega al reverso.**

### D5 — El `kind` se deriva bajo el `account_id` del tenant, con `P0404`

**Decisión.** Cada RPC resuelve el método con un `SELECT kind ... WHERE id = p_payment_method_id AND account_id = v_account_id`; si no lo encuentra → **`P0404`**, con un mensaje que **no revela** si el identificador existe en otro tenant.

**Por qué el filtro explícito por `account_id` y no la RLS.** Regla dura del proyecto desde la fuga multi-tenant de agosto (PR #446): *"todo repository filtra explícito por `account_id`; RLS es red, no guard único"*. Y estas dos funciones son `SECURITY DEFINER`: **la RLS no las mira**. Sin el filtro, un `payment_method_id` de otro tenant resolvería un `kind` ajeno y dispararía sus efectos — una variante exacta del hueco que `cuenta-corriente-party-guard` cerró para `client_id`/`supplier_id` en estas mismas RPCs.

**`P0404`, no `P0400`.** Reusa el mapeo RFC 7807 → 404 que `cuenta-corriente-party-guard` ya dejó puesto, y el mensaje sigue la misma redacción no-reveladora que el guard de cliente de dos líneas más arriba en la misma función. Cero ERRCODEs nuevos en todo el change.

**El guard de tenencia del cliente/proveedor (`P0404`) queda intacto**, en su posición actual y con su mensaje actual. Este change **no toca** ninguna línea del guard de `cuenta-corriente-party-guard`, y el gate que lo verifica se actualiza sólo en la firma con que resuelve la función (D9).

### D6 — Un solo contexto nuevo del selector, `"collection"`, para cobro y pago

**Decisión.** `PaymentMethodContext` pasa de `"sale" | "purchase" | "expense"` a sumar **`"collection"`**, usado por los dos modales. `paymentMethodOptionsFor` filtra `credit` para ese contexto, igual que ya hace para `"expense"`.

**Por qué un contexto y no dos (`"collection"` / `"payment"`).** El contexto existe para dos cosas: qué opciones se ofrecen y qué dice el texto de apoyo. Las opciones son **idénticas** (6 kinds, sin `credit`). El texto de apoyo difiere sólo en la dirección del dinero — *"ingresa a la caja"* vs. *"sale de la caja"*—, que es un dato que el componente **ya recibe por otra vía** en la superficie. Dos contextos para una sola diferencia de preposición duplicarían el `Record` de textos y el filtro sin ganar nada; es la misma economía por la que `caja-compras-cobranzas` usó un solo `document="cobro"` en `useCashOptin` para los dos modales.

**Por qué extender el componente y no envolverlo.** `PaymentMethodSelect` ya es el punto único del sistema y ya absorbió una extensión aditiva idéntica cuando `gastos-forma-pago` sumó `"expense"` (documentado en su propio comentario como *"EXTENSIÓN ADITIVA, no un selector nuevo"*). Este change repite ese movimiento exacto. El requirement vigente *"La etiqueta de forma de pago tiene una sola definición en la interfaz"* lo exige.

**El texto de apoyo de `cash` en este contexto dice la verdad del opt-in pre-marcado**, siguiendo la redacción que `gastos-forma-pago` fijó para el suyo (*"salvo que destildes…"*), y **no** la de venta (que describe un opt-in destildado). Decirlo al revés sería el bug que `qa-integral-modulos` (G10/H8) corrigió para compra: un texto que afirma que la etiqueta es inocua mientras el sistema mueve dinero de verdad.

### D7 — El reverso **no se toca**, y eso se prueba con un gate

**Decisión.** `rpc_reverse_payment_received` y `rpc_reverse_payment_made` no cambian de firma ni de cuerpo. Se agrega un escenario de gate que ejercita **anular un cobro imputado a `payment_method_id`** y verifica los cuatro libros.

**Por qué es seguro, verificado en el cuerpo vivo y no supuesto.** Se leyó `rpc_reverse_payment_received` completo (`7f042df0…`, 7.483 chars). Las cuatro patas de compensación se disparan así:

| Pata | Cómo se dispara |
|---|---|
| Cuenta corriente | `v_payment.customer_account_id` + `v_payment.amount` de la fila |
| Caja | `EXISTS` sobre `cash_movements WHERE reference_id = p_payment_id AND movement_type = 'payment_received'` |
| Banco | loop sobre `bank_movements WHERE source_doc_type='payment_received' AND source_doc_ref = p_payment_id` |
| Asiento | evento `PaymentReceivedReversed`; el consumidor localiza el asiento por `source_doc_ref` |

**Ninguna de las cuatro lee `payments_received.payment_method`.** El `SELECT * INTO v_payment` trae la fila entera, pero la columna nunca se referencia. Dropearla no rompe el `SELECT *` (que se resuelve en ejecución contra el rowtype vigente) ni ninguna rama.

Y no es un accidente afortunado: es **diseño declarado**. La spec `payment-reversal` tiene un requirement cuyo título lo dice — *"Cada pata de compensación se dispara por la existencia del movimiento, **nunca por su signo ni por la forma de pago declarada**"*—, escrito por `cobranzas-reverso` (D3) precisamente porque la columna estaba vacía y despachar por ella habría fallado en silencio. **Esa decisión, tomada por otra razón, es la que hace que este change no pueda romper el reverso.** El delta refuerza el requirement declarando que la independencia se mantiene bajo `payment_method_id`, y el gate lo ejercita en vez de confiar.

**El único efecto observable del reverso que sí cambia** es cosmético y ya estaba anotado: OQ-5 de `cobranzas-reverso` observó que, borrada la fila del pago, `AccountMovementOut.payment_method` pasa a `NULL` en el movimiento original. Con la columna migrada el `LEFT JOIN` es a `payment_methods` a través de la fila borrada — mismo resultado `NULL`, misma conclusión: se acepta.

### D8 — Ni ERRCODEs, ni eventos, ni ramas contables nuevas

**Decisión.** Cero ERRCODEs nuevos (`P0400`, `P0404`, `P0412`, `P0422`, `P0424` ya existen, están mapeados en `backend/core/errors.py` y tienen traducción de cliente). Cero tipos de evento nuevos. `_journal_post_from_event` **no se toca**.

**El payload del evento sí cambia de forma mínima**: `'payment_method', p_payment_method` pasa a llevar el `kind` derivado (más `payment_method_id`). El `kind` es un string del mismo dominio para los 4 valores que hoy viajan, así que **ningún consumidor cambia de comportamiento** para los casos existentes. Se verifica leyendo las ramas `PaymentReceived`/`PaymentMade` del consumidor antes de escribir SQL (checkpoint 1.x): si alguna comparara el payload contra la lista de 4, habría que ampliarla — la medición dice que no, pero se confirma en el apply y no se asume acá.

**Por qué importa decirlo.** Que un change no necesite ERRCODEs ni ramas contables nuevas es la mejor evidencia de que está copiando un molde existente en vez de inventar uno. Es el mismo argumento que `caja-compras-cobranzas` (D10) hizo sobre sí mismo.

### D9 — Los tres gates que resuelven las firmas se migran **en el mismo PR**

**Decisión.** Se actualizan en el mismo commit que la migración:

| Gate | Qué rompe | Corrección |
|---|---|---|
| `test_cuenta_corriente_party_guard.sql` L887/L901 | `pg_get_functiondef('...(text,uuid,numeric,uuid,text,uuid,uuid)'::regprocedure)` — la firma deja de existir | firma nueva con `uuid` en 5.ª posición |
| `test_party_payment_cash.sql` | ~14 llamadas con `p_payment_method => 'cash'` + 2 asserts sobre la columna de texto | `p_payment_method_id => <id del método cash>` + asserts sobre `payment_method_id` |
| `test_cobranzas_reverso.sql` | 8 llamadas con `p_payment_method => …` | ídem |

**Por qué se trata como parte del change y no como daño colateral.** `test_cuenta_corriente_party_guard.sql` **ya se rompió dos veces por exactamente esto** — la lección está registrada en `CHANGES.md` (ítem 19: *"resolvía la firma vieja de 6 args… corregido a la firma nueva de 7"*). Un gate que resuelve por `::regprocedure` es un **caller más** de la función, y la regla de la casa desde el incidente del cierre de caja (#451) es literal: *"al endurecer un contrato, migrar TODOS los callers"*. La tarea 1.x del apply enumera los callers con `pg_get_functiondef` y `grep`, no de memoria.

**Se agrega además el chequeo de firma única** (`SELECT count(*) FROM pg_proc WHERE proname = …` = 1 por función), que `test_party_payment_cash.sql` ya tiene en su caso 4.7 y que es la red contra el overload de D1.

### D10 — La superficie: dos modales, cuatro combinaciones, verificación visual

**Decisión.** `RegisterPaymentForm.tsx` y `RegisterPaymentMadeForm.tsx` pierden su constante `PAYMENT_METHODS`, su `BANK_METHODS` y su `<Select>` propio; montan `PaymentMethodSelect` con `context="collection"` y `BankAccountDestinationSelect` con `required` — el mismo par que el formulario de gasto ya usa.

**Qué cambia para el usuario, dicho sin adorno**: donde veía cuatro opciones fijas ve **su** catálogo. Un tenant que renombró "Transferencia bancaria" a "Banco Nación" ve "Banco Nación". El bloque de opt-in de caja, su checkbox pre-marcado y sus motivos **no cambian de comportamiento** — cambia de dónde sale el `kind` que los alimenta (D11).

**Verificación obligatoria (regla PO 2026-08-02)**: los dos modales, en **desktop y mobile**, en **tema claro y oscuro** = 8 combinaciones, con capturas. Se verifica explícitamente el caso que el QA integral encontró como patrón: **el desplegable del selector dentro de un modal** — `qa-integral-modulos` (G1) corrigió el popover portalizado fuera del shard de scroll del modal, y estos dos son modales con un desplegable nuevo adentro. Es el escenario exacto de aquel bug, así que se prueba en lugar de asumir que el fix cubre.

### D11 — El opt-in de caja pasa a recibir el `kind` real, y hoy funciona por coincidencia

**Decisión.** `useCashOptin({ kind, ... })` pasa a recibir el `kind` resuelto del método elegido, en lugar del `value` del `<Select>` local.

**Por qué esto no es cosmético.** El hook tipa el parámetro como `PaymentMethodKind` y compara `kind === "cash"`. Hoy los modales le pasan el valor de su `<Select>` propio, cuyos `value` son `"cash" | "transfer" | "card" | "check"` — **strings que coinciden con los `kind` del catálogo por decisión de nomenclatura, no por derivación**. El opt-in de caja funciona hoy por esa coincidencia. En cuanto el selector pase a emitir un **UUID**, `kind === "cash"` sería `false` siempre y **el opt-in de caja dejaría de ofrecerse en silencio** — sin error, sin aviso, simplemente el bloque no se renderiza y ningún cobro vuelve a llegar al arqueo. Sería una regresión invisible sobre el camino que `caja-compras-cobranzas` abrió hace dos días.

Por eso el cableado del `kind` derivado es **parte del núcleo de este change**, con su propia task y su propio test, y no un ajuste de acompañamiento. El dato ya está disponible sin pedir nada nuevo: `usePaymentMethods()` (el hook que `PaymentMethodSelect` ya usa) devuelve `kind` junto a `id`.

**El servidor no depende de esto.** El opt-in sigue siendo autoridad de la RPC (`P0422`), que deriva su propio `kind` del catálogo (D5). El hook sólo decide qué mostrar.

## Risks / Trade-offs

**[Un `CREATE OR REPLACE` en vez del `DROP` deja dos overloads vivos y el backend llama al viejo en silencio]** → `DROP FUNCTION` explícito + chequeo de firma única en el gate (`count(*) FROM pg_proc` = 1 por función), que ya existe en `test_party_payment_cash.sql` 4.7 y se extiende a las dos. Gotcha `42725`, registrado.

**[Los gates rompen el CI por resolver la firma vieja]** → Es **esperado y planificado**, no un riesgo a evitar: los tres archivos se migran en el mismo commit (D9). El riesgo real sería descubrirlos en CI en vez de enumerarlos en la task 1.x.

**[El opt-in de caja deja de ofrecerse porque el hook recibe un UUID donde espera un `kind`]** → D11 lo trata como núcleo, con test propio. Es el modo de falla **más probable y menos visible** de todo el change: no rompe nada, sólo deja de ofrecer el checkbox.

**[Dropear la columna de texto pierde datos]** → **0 de 7 filas** la tienen poblada (medido). El conteo se re-verifica en el checkpoint 1.x del apply: si en el momento del apply hubiera alguna fila poblada (un cobro nuevo cargado entre el propose y el merge), la task se detiene y se decide backfill de esa fila puntual antes del `DROP COLUMN`.

**[La reescritura de dos RPCs pierde una rama existente]** → Regla de integridad de función: parte del `pg_get_functiondef` **vivo hasheado** (`4d5de674…` / `07acdadb…`), el hash se verifica en el checkpoint 1.x **antes de escribir una línea de SQL**. Un hash que no coincide **detiene el apply**. Las funciones tienen 7.656 y 6.751 chars — de las más chicas que el proyecto ha reescrito.

**[Adoptar el helper bancario cambia el comportamiento de cobros que hoy funcionan]** → El helper produce **los mismos tres `movement_type`** que el `CASE` inline actual para los mismos tres kinds (verificado en ambos cuerpos vivos), y el guard estricto de cuenta bancaria se conserva, de modo que el fallback al default (que resolvería NULL en 266/266) nunca se ejerce. Lo único que se **suma** es el guard `P0424` de período conciliado, que hoy falta y cuya ausencia es un bug latente. El gate ejercita los cuatro kinds bancarios contra la tabla de inversión del reverso.

**[El reverso deja de compensar un cobro imputado por catálogo]** → Estructuralmente imposible: las cuatro patas despachan por existencia de movimientos (D7, verificado en el cuerpo vivo), y el requirement de `payment-reversal` lo declara normativo. Se ejercita igual con un escenario de gate.

**[`credit` rechazado bloquea un caso de uso real que no anticipamos]** → El rechazo es de servidor **y** el selector no lo ofrece, así que el usuario no llega al error por accidente. Si apareciera el caso, levantarlo es borrar una condición; permitirlo primero y prohibirlo después rompería filas ya escritas. Se prohíbe ahora, que es la dirección reversible.

**[Los 7 pagos históricos quedan sin forma de pago y el reporte no los muestra]** → Su columna de texto ya está en `NULL` (0/7): **no pierden nada que hoy tengan**. Es el mismo estado, con una columna distinta. Precedente firmado dos veces (175 gastos, 11 documentos de `caja-compras-cobranzas`).

## Migration Plan

1. **Checkpoint 1.x (antes de escribir SQL)**: re-capturar el `pg_get_functiondef` vivo de las 9 funciones de la tabla del Context y comparar los md5. **Un hash que no coincide detiene el apply.** En el mismo checkpoint: re-contar `payments_received`/`payments_made` con `payment_method IS NOT NULL` (debe seguir en 0) y confirmar que las ramas `PaymentReceived`/`PaymentMade` de `_journal_post_from_event` no comparan el payload contra la lista de 4 (D8).
2. **Re-verificar la correlativa** contra `origin/main` **y** contra `supabase_migrations.schema_migrations`. `20261020000001` es la previsión verificada hoy (ambos en `20261019000001`), no una certeza: la numeración se corrió tres veces en `cuenta-corriente-party-guard` y una en `caja-compras-cobranzas`.
3. **Migración en un solo archivo, idempotente**, en este orden: (a) `ALTER TABLE` de las dos columnas (`ADD` la FK, `DROP` el texto); (b) `DROP FUNCTION` + `CREATE` de las dos RPCs; (c) `REVOKE` de `PUBLIC`/`anon`/`authenticated` + `GRANT` selectivo.
4. **Backend, frontend y gates en el mismo PR.** La firma nueva sin el frontend migrado deja los dos modales rotos, y el frontend sin la RPC manda un UUID a un parámetro `text`.
5. **Rollback**: revertir el PR restaura los cuerpos y la firma anteriores. El `DROP COLUMN` **no se revierte** (la columna vuelve vacía, que es su estado actual). Los cobros creados con `payment_method_id` conservan su FK: la columna nueva es aditiva y ningún lector la exige.
6. **Verificación post-merge en prod** (rutina de los últimos ocho changes): `MAX(version)`; **una sola firma viva** por función; ACLs de las dos RPCs (`anon` sin `EXECUTE`); cuerpo vivo conteniendo `_pay_register_operation_bank_movement`; y **humo real con el PO**: un cobro por billetera virtual (el kind que hoy no se puede), un cobro en efectivo verificando el movimiento en `/caja`, y la **anulación** de ese cobro verificando que los cuatro libros compensan.

## Open Questions

**OQ-1 — ¿`credit` se rechaza o se acepta como etiqueta?**
D2 decide **rechazar con `P0400`** en servidor y no ofrecerlo en el selector: cancelar una deuda con deuda es circular. La alternativa es aceptarlo como etiqueta pura (como `other`), que evitaría un error posible pero produciría filas que se leen como un cargo siendo un pago.
**Recomendación: rechazar (D2).** Es la dirección reversible —permitirlo después es borrar una condición; prohibirlo después rompería filas ya escritas— y replica el precedente firmado de `gastos-forma-pago` (D3). **Si el PO no responde, se hace así.**

**OQ-2 — ¿`other` se acepta en un cobro?**
D2 decide **sí**, como etiqueta pura sin efecto en ningún libro. El argumento en contra es que un cobro sin forma de pago identificable es difícil de conciliar.
**Recomendación: aceptarlo.** La alternativa que hoy tiene el usuario para un cobro en especie o por un canal no modelado es elegir "Efectivo", que con el opt-in pre-marcado **le mete plata inexistente en el arqueo** y ensucia la señal antifraude de RN-95. Admitir `other` es estrictamente más seguro que el statu quo. No bloqueante.

**OQ-3 — ¿La columna de texto se dropea o se conserva como snapshot?**
D3 decide **dropear**: 0 de 7 filas pobladas, y las otras cuatro tablas del sistema ya convergieron a la FK sola. La alternativa —conservarla como snapshot del `kind`— alinearía con `v3-snapshot-pattern`.
**Recomendación: dropear (D3).** El snapshot protege contra la mutación del maestro, y acá el maestro **no se borra nunca** (la baja es desactivación, requirement vigente) y el selector ya sabe mostrar métodos inactivos. Conservarla dejaría a cobros como la única tabla del sistema con dos columnas para el mismo dato. **Si el PO no responde, se hace así.**

**OQ-4 — ¿El contexto del selector es uno (`"collection"`) o dos (`"collection"`/`"payment"`)?**
D6 decide **uno**: las opciones ofrecidas son idénticas y la única diferencia es la preposición del texto de apoyo.
**Recomendación: uno.** Partirlo después, si el texto de apoyo diverge de verdad, es aditivo y barato. No bloqueante.

**OQ-5 — ¿Se aprovecha para configurar `bank_account_id` por defecto en las formas de pago?**
Hoy son **0 de 266**. D4 lo deja explícitamente fuera y conserva el guard que exige cuenta bancaria explícita en cada cobro.
**Recomendación: fuera de este change.** Es una decisión de configuración por tenant, no de código, y tocarla acá cambiaría el comportamiento de venta, compra y gasto —que sí usan el default— sin que nadie lo haya pedido. Anotarlo como candidato. No bloqueante.
