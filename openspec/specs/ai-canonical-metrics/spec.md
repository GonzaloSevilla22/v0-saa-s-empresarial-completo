# ai-canonical-metrics Specification

## Purpose

Los números que la IA le muestra al usuario. Todo consumidor de IA que exponga ingresos, ganancia neta, margen o balance SHALL derivarlos del read-model canónico (`rpc_dashboard_kpi_summary`) en lugar de recalcularlos por su cuenta, para que la IA y el Tablero nunca puedan disentir sobre el mismo período. Cubre los cinco caminos de IA vigentes: el Copiloto (`frontend/lib/ai/buildBusinessSnapshot.ts`) y las Edge Functions `ai-insights`, `ai-simulador`, `ai-prediccion` y `ai-resumen`.

## Requirements

### Requirement: Las cifras financieras que la IA expone provienen del read-model canónico
Todo consumidor de IA que incluya ingresos, ganancia neta, margen o balance en el contexto que envía al modelo SHALL derivar esas cifras de `rpc_dashboard_kpi_summary` — `invoiced_revenue` para ingresos del período, `prev_invoiced_revenue` para la comparativa y `net_profit` para la ganancia — y NUNCA agregarlas por su cuenta desde las tablas operativas. Los consumidores alcanzados son los cinco caminos de IA vigentes: el Copiloto (`frontend/lib/ai/buildBusinessSnapshot.ts`) y las Edge Functions `ai-insights`, `ai-simulador`, `ai-prediccion` y `ai-resumen`. La llamada SHALL hacerse con el cliente Supabase del usuario (JWT del caller), de modo que la cuenta la resuelva el propio RPC.

#### Scenario: Los ingresos que cita la IA igualan los del Tablero
- **GIVEN** una cuenta con ventas en el período y el Bloque Resumen del Tablero mostrando `invoiced_revenue` para esa misma ventana
- **WHEN** cualquier consumidor de IA arma su contexto para esa ventana
- **THEN** el valor de ingresos del contexto es exactamente el mismo que muestra el Tablero

#### Scenario: Una venta multi-unidad aporta su total de línea, no el precio unitario
- **GIVEN** una venta de 3 unidades a $1.000 de precio unitario (`amount = 1000`, `quantity = 3`, `total = 3000`) como única venta del período
- **WHEN** un consumidor de IA arma su contexto
- **THEN** los ingresos del período son $3.000

#### Scenario: La ganancia que cita la IA descuenta compras y notas de crédito
- **GIVEN** un período con $10.000 de ventas, $1.000 de notas de crédito, $2.000 de gastos y $3.000 de compras
- **WHEN** un consumidor de IA arma su contexto
- **THEN** la ganancia neta del contexto es $4.000 (`(10.000 − 1.000) − (2.000 + 3.000)`)
- **AND** el margen neto es 44% (`ganancia neta / ingresos devengados`)

#### Scenario: Aislamiento entre cuentas
- **WHEN** un consumidor de IA obtiene las cifras del período
- **THEN** el resultado NUNCA incluye datos de otra cuenta, porque la cuenta la resuelve el RPC a partir del JWT del caller y no un parámetro del consumidor

### Requirement: Los desgloses locales de la IA suman el revenue de línea canónico
Todo desglose que un consumidor de IA calcule localmente sobre filas de ventas (revenue por producto, revenue por cliente) SHALL sumar `COALESCE(total, amount)` por línea a través del helper canónico compartido, y NUNCA `amount` a secas. El helper SHALL existir una sola vez por runtime — `frontend/lib/reporting/revenue-canon.ts` para Next.js y `supabase/functions/_shared/reporting-canon.ts` para Deno — y ambas copias SHALL producir resultados idénticos, verificado por un test automático de paridad que corre las dos implementaciones sobre la misma tabla de casos.

#### Scenario: El ranking de productos usa totales de línea
- **GIVEN** el producto A con una venta de 1 unidad a $5.000 y el producto B con una venta de 4 unidades a $2.000 (`total = 8000`)
- **WHEN** un consumidor de IA arma el ranking de productos por revenue
- **THEN** B encabeza el ranking con $8.000 y A queda segundo con $5.000

#### Scenario: Fila legacy sin total usa amount como total de línea
- **GIVEN** una fila de venta legacy con `total = NULL` y `amount = 500`
- **WHEN** se agrega cualquier desglose local
- **THEN** la línea aporta $500

#### Scenario: Las dos implementaciones del helper no pueden divergir
- **GIVEN** la tabla de casos compartida del test de paridad
- **WHEN** una de las dos copias del helper cambia su resultado para cualquier caso
- **THEN** el test de paridad falla

### Requirement: Sin canon disponible, la cifra se omite en lugar de inventarse
Cuando la llamada al read-model canónico falla, el consumidor de IA SHALL omitir del contexto la ganancia neta, el margen y la comparativa contra el período anterior, y NUNCA sustituirlos por una estimación calculada con otra fórmula. Los ingresos SHALL seguir informándose, calculados con el helper canónico de revenue de línea sobre las filas ya disponibles en memoria. El fallo SHALL quedar registrado en los logs con el prefijo del consumidor. En el Copiloto, esto se materializa en que `BusinessSnapshot.gastos.margen_neto_pct` y `ganancia_neta` son `number | null` y los constructores de texto omiten sus fragmentos cuando valen `null`.

#### Scenario: El RPC falla y el contexto sale sin margen
- **GIVEN** una llamada al read-model canónico que devuelve error
- **WHEN** el consumidor de IA arma su contexto
- **THEN** el contexto informa los ingresos calculados con el helper canónico
- **AND** no contiene ninguna línea de ganancia neta, margen ni comparativa
- **AND** el fallo queda registrado en los logs

#### Scenario: La respuesta al usuario no se cae por un KPI faltante
- **GIVEN** el mismo fallo del read-model canónico
- **WHEN** el usuario le hace una pregunta al Copiloto
- **THEN** recibe una respuesta normal, sin error HTTP

### Requirement: La ganancia neta en pesos está disponible en el contexto de la IA
El contexto que los consumidores de IA envían al modelo SHALL incluir la ganancia neta del período expresada en pesos (`net_profit` del read-model canónico), además del margen porcentual. El system prompt obliga al modelo a citar números concretos del contexto; la ganancia en pesos es la cifra que el usuario puede contrastar contra el Tablero.

#### Scenario: El contexto incluye la ganancia en pesos
- **GIVEN** un período con ganancia neta canónica de $4.000
- **WHEN** un consumidor de IA arma su contexto
- **THEN** el contexto contiene la ganancia neta $4.000 junto al margen porcentual

#### Scenario: Período sin ingresos
- **GIVEN** un período sin ventas
- **WHEN** un consumidor de IA arma su contexto
- **THEN** el margen porcentual no se informa (no hay base sobre la cual calcularlo) y la ganancia neta se informa tal como la devuelve el read-model

### Requirement: La ventana comparativa se deriva de la ventana consultada
Los consumidores de IA cuya ventana no tiene un período anterior natural (mes en curso, últimos N días, rango explícito del caller) SHALL derivar la ventana comparativa que exige el read-model como el intervalo inmediatamente anterior de igual duración, mediante un helper único compartido. La derivación NUNCA SHALL producir un rango invertido.

#### Scenario: Ventana previa de igual duración
- **GIVEN** una ventana consultada del 1 al 30 de julio
- **WHEN** se deriva la ventana comparativa
- **THEN** es el intervalo inmediatamente anterior de la misma duración, que termina justo antes del 1 de julio

#### Scenario: El consumidor que no compara descarta las columnas previas
- **GIVEN** un consumidor que no muestra comparativa (simulador, predicción, resumen)
- **WHEN** obtiene la fila del read-model
- **THEN** usa solo las columnas del período actual y las columnas `prev_*` no influyen en el contexto

### Requirement: Aproximaciones documentadas en los desgloses por producto y por cliente
Los desgloses por producto y por cliente SHALL calcularse brutos de notas de crédito, porque las NC no se atribuyen a la línea de venta original. Como el total del período sí resta NC, el porcentaje que representa el mayor cliente sobre el total SHALL acotarse a 100 para que el contexto de la IA nunca exprese una participación imposible.

#### Scenario: El ranking de productos no resta notas de crédito
- **GIVEN** un período con una NC emitida sobre una venta de un producto del ranking
- **WHEN** se calcula el revenue por producto
- **THEN** el producto conserva su revenue bruto en el desglose
- **AND** el total del período sí descuenta la NC

#### Scenario: La participación del mayor cliente nunca supera el 100%
- **GIVEN** un período con una NC lo bastante grande como para que el revenue bruto del mayor cliente supere el ingreso neto del período
- **WHEN** se arma el contexto
- **THEN** la participación informada es 100%
