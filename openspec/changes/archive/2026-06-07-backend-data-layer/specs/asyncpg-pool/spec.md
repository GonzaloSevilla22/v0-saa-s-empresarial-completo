## ADDED Requirements

### Requirement: Pool asyncpg con JWT-passthrough
El sistema SHALL mantener un pool de conexiones asyncpg con `min_size=2` y `max_size=10`, inicializado en el startup de la aplicación FastAPI y cerrado en el shutdown. Cada conexión adquirida del pool SHALL inyectar los claims del JWT del usuario (`user_id`, `org_id`) como parámetro de sesión PostgreSQL (`SET LOCAL app.jwt_claims`) antes de ser entregada al caller, garantizando que la RLS org-based se aplique en cada query.

#### Scenario: Pool se inicializa en startup sin DATABASE_URL
- **WHEN** la app arranca sin la variable de entorno `DATABASE_URL` configurada
- **THEN** la app lanza un error claro en startup (`ValueError: DATABASE_URL required`) y no inicia

#### Scenario: Pool se inicializa en startup con DATABASE_URL válida
- **WHEN** la app arranca con `DATABASE_URL` configurada correctamente
- **THEN** el pool se crea con min_size=2, las 2 conexiones iniciales se establecen contra PostgreSQL y la app queda lista para recibir requests

#### Scenario: Pool se cierra limpiamente en shutdown
- **WHEN** la app recibe señal de shutdown (SIGTERM o KeyboardInterrupt)
- **THEN** el pool asyncpg se cierra (`await pool.close()`) antes de que el proceso termine, sin conexiones colgadas

#### Scenario: JWT-passthrough inyecta claims en conexión
- **WHEN** `get_db_conn` adquiere una conexión con un user dict `{user_id, role}`
- **THEN** ejecuta `SET LOCAL app.jwt_claims = '{"sub": "<user_id>", "role": "<role>"}'` en esa conexión antes de yieldarla

#### Scenario: Request sin autenticación no obtiene conexión DB
- **WHEN** un endpoint que usa `get_db_conn` recibe un request sin Bearer token
- **THEN** `get_current_user` lanza HTTP 401 antes de que se adquiera ninguna conexión del pool

### Requirement: Configuración de base de datos vía entorno
El sistema SHALL leer `DATABASE_URL` y `REDIS_URL` desde variables de entorno via `pydantic-settings`. Ambas deben tener valores por defecto vacíos que causen un error explícito en startup si no están configuradas en producción.

#### Scenario: Settings carga DATABASE_URL desde entorno
- **WHEN** el proceso tiene `DATABASE_URL=postgresql://user:pass@host:5432/db` en el entorno
- **THEN** `settings.database_url` retorna ese valor sin modificación

#### Scenario: Settings en development usa .env file
- **WHEN** existe un archivo `.env` en la raíz con `DATABASE_URL=...`
- **THEN** `pydantic-settings` lo carga automáticamente y `settings.database_url` retorna el valor del archivo
