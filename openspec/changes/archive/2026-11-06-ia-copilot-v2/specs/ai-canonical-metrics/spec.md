## MODIFIED Requirements

### Requirement: Las cifras financieras que la IA expone provienen del read-model canónico
Todo consumidor de IA que incluya ingresos, ganancia neta, margen o balance en el contexto que envía al modelo SHALL derivar esas cifras de `rpc_dashboard_kpi_summary` — `invoiced_revenue` para ingresos del período, `prev_invoiced_revenue` para la comparativa y `net_profit` para la ganancia — y NUNCA agregarlas por su cuenta desde las tablas operativas. Los consumidores alcanzados son los cinco caminos de IA vigentes: el Copiloto (Edge Function `ai-copilot`, a través de su herramienta `resumen_periodo`) y las Edge Functions `ai-insights`, `ai-simulador`, `ai-prediccion` y `ai-resumen`. La llamada SHALL hacerse con el cliente Supabase del usuario (JWT del caller), de modo que la cuenta la resuelva el propio RPC.

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

#### Scenario: El Copiloto cita el resumen canónico
- **GIVEN** una pregunta del Copiloto sobre la ganancia del mes en curso
- **WHEN** el Copiloto la contesta
- **THEN** la ganancia de la respuesta es el `net_profit` que `rpc_dashboard_kpi_summary` devuelve para esa ventana, obtenido por la herramienta `resumen_periodo`

### Requirement: Sin canon disponible, la cifra se omite en lugar de inventarse
Cuando la llamada al read-model canónico falla, el consumidor de IA SHALL omitir del contexto la ganancia neta, el margen y la comparativa contra el período anterior, y NUNCA sustituirlos por una estimación calculada con otra fórmula. Los ingresos SHALL seguir informándose, calculados con el helper canónico de revenue de línea sobre las filas ya disponibles en memoria, en los consumidores que tienen esas filas. El fallo SHALL quedar registrado en los logs con el prefijo del consumidor. En el Copiloto, esto se materializa en que la herramienta `resumen_periodo` devuelve `{error:"no_disponible"}` al modelo y el prompt le prohíbe dar la cifra faltante.

#### Scenario: El RPC falla y el contexto sale sin margen
- **GIVEN** una llamada al read-model canónico que devuelve error
- **WHEN** el consumidor de IA arma su contexto
- **THEN** el contexto informa los ingresos calculados con el helper canónico, si el consumidor tiene las filas
- **AND** no contiene ninguna línea de ganancia neta, margen ni comparativa
- **AND** el fallo queda registrado en los logs

#### Scenario: La respuesta al usuario no se cae por un KPI faltante
- **GIVEN** el mismo fallo del read-model canónico
- **WHEN** el usuario le hace una pregunta al Copiloto
- **THEN** recibe una respuesta normal, sin error HTTP, que dice que ese dato no está disponible y no da ninguna cifra de ganancia
