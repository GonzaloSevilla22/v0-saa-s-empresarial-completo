## ADDED Requirements

### Requirement: Almacén genérico de valoraciones de IA
El sistema SHALL guardar la valoración de una respuesta de IA en la tabla `ai_feedback`, una fila por `(user_id, subject_type, subject_id)`, con `account_id`, `rating` en `{useful, not_useful}` y `subject_type` en `{copilot_answer, insight}`. La tabla SHALL tener RLS activa con lectura sólo de las filas propias del usuario en su cuenta activa, sin policies de escritura y sin privilegios de `INSERT`, `UPDATE`, `DELETE` ni `TRUNCATE` para `anon` ni `authenticated`.

#### Scenario: Un usuario no ve valoraciones ajenas
- **GIVEN** las usuarias U1 y U2 de la misma cuenta, U1 con una valoración guardada
- **WHEN** U2 lee `ai_feedback`
- **THEN** no ve la fila de U1

#### Scenario: Escritura directa rechazada
- **WHEN** un usuario autenticado intenta `INSERT` directo en `ai_feedback` por PostgREST
- **THEN** la base lo rechaza por falta de privilegio

### Requirement: Valoración sólo por RPC y sobre un sujeto propio
El sistema SHALL escribir valoraciones sólo con `rpc_set_ai_feedback(p_subject_type, p_subject_id, p_rating)` (`SECURITY DEFINER`, `EXECUTE` sólo para `authenticated`). La RPC SHALL rechazar sin sesión (`P0401`), con tipo o valoración fuera de dominio (`22023`) y con un sujeto que no existe o no pertenece al usuario en su cuenta activa (`P0404`). Para `copilot_answer`, el sujeto SHALL ser una fila de `ai_conversations` del mismo usuario y de una cuenta en `current_account_ids()`. Mientras la rama `insight` no esté habilitada, `p_subject_type = 'insight'` SHALL rechazarse con `22023`. Con `p_rating` no nulo la RPC SHALL crear o reemplazar la valoración; con `p_rating` nulo SHALL borrarla.

#### Scenario: Me sirvió
- **GIVEN** una respuesta del Copiloto del usuario U con `conversation_id = C`
- **WHEN** U llama `rpc_set_ai_feedback('copilot_answer', C, 'useful')`
- **THEN** existe una fila con `rating = 'useful'` para `(U, copilot_answer, C)`

#### Scenario: Cambiar de opinión
- **GIVEN** esa fila con `useful`
- **WHEN** U llama la RPC con `'not_useful'`
- **THEN** la misma fila queda con `not_useful` y no hay una segunda fila

#### Scenario: Quitar la valoración
- **WHEN** U llama la RPC con `p_rating = NULL`
- **THEN** la fila se borra

#### Scenario: Respuesta de otro usuario
- **GIVEN** una respuesta del Copiloto de la usuaria U2
- **WHEN** U la valora
- **THEN** la RPC rechaza con `P0404` y no se escribe nada

### Requirement: Valoración visible en el Copiloto
Cada respuesta del Copiloto con `conversation_id` SHALL mostrar los botones «Me sirvió» y «No me sirvió», con el estado elegido marcado (`aria-pressed`), aplicado de forma optimista y revertido con un aviso si la RPC falla; tocar el botón ya marcado SHALL quitar la valoración. Al recargar el historial, cada respuesta SHALL mostrar la valoración guardada.

#### Scenario: Valorar y recargar
- **WHEN** el usuario marca «Me sirvió» en una respuesta y recarga la página
- **THEN** esa respuesta sigue mostrando «Me sirvió» marcado

#### Scenario: Falla al guardar
- **WHEN** la RPC devuelve error
- **THEN** el botón vuelve a su estado anterior y aparece un aviso «No se pudo guardar tu opinión»
