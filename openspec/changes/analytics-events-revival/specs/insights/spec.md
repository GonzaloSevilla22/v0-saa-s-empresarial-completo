## ADDED Requirements

### Requirement: La UMV depende de un emisor de operaciones vivo
El sistema SHALL marcar el evento `umv_reached` cuando un usuario genera un insight y existe al menos un evento `operation_created` previo para ese usuario, emitido por el choke point de base de datos que cubre todas las rutas de escritura de ventas, compras y gastos.

La UMV (Unidad Mínima de Valor, `knowledge-base/01_vision_y_objetivos.md`) se define como una operación registrada más un insight generado. La detección vive en `rpc_create_insight` y consulta `analytics_events` buscando `operation_created`. Cuando las rutas modernas de escritura dejaron de emitir ese evento, la condición dejó de cumplirse y la UMV nunca se disparó para esos usuarios, aunque hubieran operado y generado insights. Este requirement fija la dependencia por escrito: la lógica de UMV es correcta sólo mientras exista un emisor de operaciones activo, y ese emisor es la capa de base de datos, no la aplicación.

#### Scenario: Usuario que operó por la ruta moderna alcanza la UMV
- **WHEN** un usuario registra un gasto vía el backend FastAPI y luego genera un insight
- **THEN** se emite el evento `umv_reached` para ese usuario

#### Scenario: Usuario que operó por RPC de venta alcanza la UMV
- **WHEN** un usuario registra una venta vía `rpc_create_sale_operation` y luego genera un insight
- **THEN** se emite el evento `umv_reached` para ese usuario

#### Scenario: Insight sin operación previa no alcanza la UMV
- **WHEN** un usuario genera un insight sin haber registrado ninguna venta, compra ni gasto
- **THEN** no se emite `umv_reached`

#### Scenario: La UMV se marca una sola vez por usuario
- **WHEN** un usuario que ya alcanzó la UMV genera insights adicionales
- **THEN** no se emiten eventos `umv_reached` adicionales
