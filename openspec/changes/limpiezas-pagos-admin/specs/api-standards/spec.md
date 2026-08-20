## ADDED Requirements

### Requirement: Todo ERRCODE custom tiene exactamente 5 caracteres

Toda función SQL del sistema que lance un error de negocio con `RAISE ... USING ERRCODE = '<codigo>'` SHALL usar un SQLSTATE de **exactamente 5 caracteres**, siguiendo la convención `P04xx` ya vigente en el proyecto. Un SQLSTATE custom de menos de 5 caracteres no es un código válido: al ejecutarse el `RAISE`, PostgreSQL lo rechaza con `42704 unrecognized exception condition`, el mensaje escrito por la función se pierde y el mapeo `sqlstate → HTTP status` de `backend/core/errors.py` degrada el error a un 500 genérico — es decir, el contrato RFC 7807 se rompe en silencio justo en los casos que más lo necesitan.

El sistema SHALL sostener este invariante con un gate automático en CI que inspeccione las funciones **vivas** de la base (no los archivos de migración) y falle la integración si alguna contiene un ERRCODE custom de menos de 5 caracteres. Verificarlo solo por corrección puntual no alcanza: la normalización de `20260624000001` se perdió porque cada RPC nueva volvió a copiar el patrón inválido de las migraciones viejas.

#### Scenario: Un ERRCODE de 4 caracteres falla el pipeline

- **GIVEN** una migración que define una función con `RAISE ... USING ERRCODE = 'P404'`
- **WHEN** corre el gate de CI sobre la base resultante de aplicar todas las migraciones
- **THEN** la integración falla nombrando la función y el código inválido

#### Scenario: El error de negocio llega con su status y su mensaje

- **GIVEN** una función corregida que lanza `RAISE EXCEPTION 'producto no encontrado' USING ERRCODE = 'P0404'`
- **WHEN** el backend la invoca y el RPC falla
- **THEN** la respuesta HTTP tiene `status 404`, `code: "P0404"` y `detail` con el mensaje original de la función, en vez de un 500 genérico

#### Scenario: La base vigente no tiene ningún código inválido

- **WHEN** se inspeccionan todas las funciones de los schemas `public` y `community` de la base
- **THEN** ninguna contiene un ERRCODE custom de menos de 5 caracteres
