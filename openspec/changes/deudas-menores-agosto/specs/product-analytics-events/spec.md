## ADDED Requirements

### Requirement: Todo evento de operación referencia una operación existente
El sistema SHALL mantener `analytics_events` libre de eventos `operation_created` cuya entidad referenciada no exista en `sales`, `purchases` ni `expenses`, y libre de más de un evento `operation_created` por operación.

La identificación de la entidad referenciada SHALL contemplar **ambas formas de payload** que conviven en los datos históricos: la canónica (`entity_id`) y la del emisor legacy ya retirado (`sale_id`, `purchase_id`, `expense_id`). Una limpieza que sólo mire la clave canónica NO SHALL considerarse conforme.

La limpieza SHALL derivar el conjunto a borrar en el momento de ejecutarse, comparando contra el estado real de las tablas de operaciones; NO SHALL depender de identificadores enumerados ni de un conteo esperado fijado de antemano. SHALL ser idempotente —una segunda ejecución borra cero filas— y SHALL registrar cuántas filas borró en cada paso. Ante eventos duplicados para la misma operación, SHALL conservarse el de `created_at` más antiguo.

Una operación con borrado lógico SHALL considerarse existente: su evento describe un hecho ocurrido y NO SHALL borrarse.

#### Scenario: Evento que apunta a una operación inexistente
- **WHEN** un evento `operation_created` referencia, en cualquiera de las dos formas de payload, una entidad que no tiene fila en `sales`, `purchases` ni `expenses`
- **THEN** la limpieza lo borra

#### Scenario: Evento de una operación con borrado lógico
- **WHEN** un evento `operation_created` referencia una operación marcada como borrada lógicamente
- **THEN** la limpieza lo conserva

#### Scenario: Dos eventos para la misma operación
- **WHEN** existen dos eventos `operation_created` que referencian la misma operación
- **THEN** la limpieza conserva el de `created_at` más antiguo y borra el resto

#### Scenario: La limpieza es idempotente
- **WHEN** la limpieza se ejecuta dos veces seguidas
- **THEN** la segunda ejecución borra cero filas y reporta cero en su registro

#### Scenario: Sólo se tocan los eventos de operación
- **WHEN** la limpieza se ejecuta
- **THEN** el conteo de eventos `insight_generated`, `first_operation`, `umv_reached` y `post_created` permanece exactamente igual

#### Scenario: Ningún evento huérfano sobrevive a la limpieza
- **WHEN** se consulta el conjunto de eventos `operation_created` después de la limpieza
- **THEN** ninguno referencia una entidad ausente de las tres tablas de operaciones
