# Spec: backend-auth

## Overview

Middleware de autenticación para FastAPI que valida JWTs emitidos por Supabase. FastAPI no emite tokens propios — actúa como resource server que verifica la firma del token.

## Requirements

### REQ-BA-01: Validación de JWT de Supabase
El middleware debe decodificar y verificar tokens usando `SUPABASE_JWT_SECRET` y algoritmo `HS256`.

### REQ-BA-02: Claims extraídos
Tras validación exitosa, el dependency debe retornar:
```python
{"user_id": str, "role": str}
```
Donde `user_id` = claim `sub` y `role` = claim `role` (default: `"authenticated"` si ausente).

> **Superado por "Contrato tipado del contexto de autenticación" (más abajo, `v31-fix-auth-shape-500`, 2026-07-31).** El shape real incluye una tercera clave (`plan`) y el default de `role` cuando el claim está ausente es `"user"`, no `"authenticated"`. Se conserva este requisito legacy sin editar para no perder historial; el requisito nuevo es la fuente normativa vigente. Normalizar el resto del archivo al formato canónico es trabajo de `v31-docs-refresh` (H-22), fuera de alcance de este sync.

### REQ-BA-03: Token inválido → 401
Si el token tiene firma incorrecta, ha expirado, o está malformado: HTTP 401 con body `{"detail": "Invalid token"}`.

### REQ-BA-04: Sin verificación de audience
Supabase emite `aud: "authenticated"` (string no-URL). La verificación de `aud` debe estar desactivada (`verify_aud: False`) para evitar falsos 401.

### REQ-BA-05: Header Bearer en HTTP, query param en WebSocket
- Endpoints HTTP: `Authorization: Bearer <token>`
- Endpoints WebSocket: query param `?token=<token>` (los browsers no envían headers custom en WS handshake)

<!-- Requisitos siguientes en formato canónico, agregados por `v31-fix-auth-shape-500` (2026-07-31). Ver nota sobre REQ-BA-02 más arriba. -->

### Requirement: Contrato tipado del contexto de autenticación

El dependency de autenticación del backend SHALL declarar el contexto que produce como un tipo explícito (`AuthContext`) con exactamente tres claves obligatorias: `user_id` (el claim `sub` del JWT), `role` (el rol de aplicación) y `plan` (el plan comercial). El tipo SHALL ser la única declaración normativa de ese contrato: cualquier clave que el dependency produzca SHALL estar declarada en el tipo, y cualquier clave declarada en el tipo SHALL ser producida por el dependency. El contrato SHALL ser un mapeo (compatible con acceso por clave), de modo que los consumidores existentes no requieran reescritura.

Este requisito reemplaza la descripción del contexto de `REQ-BA-02`, que documenta un shape de dos claves (`user_id`, `role`) que el código dejó atrás al incorporar `plan`, y que atribuye a `role` un valor por defecto (`authenticated`) distinto del que el sistema produce.

#### Scenario: El contexto expone las tres claves del contrato

- **WHEN** un request presenta un JWT válido y el dependency de autenticación resuelve el contexto
- **THEN** el contexto contiene exactamente las claves `user_id`, `role` y `plan`, con `user_id` igual al claim `sub` del token

#### Scenario: Una divergencia entre el tipo declarado y el contexto producido falla la suite

- **WHEN** el conjunto de claves que el dependency produce deja de coincidir con el conjunto de claves declaradas en el tipo (por agregado, renombre o eliminación en cualquiera de los dos lados)
- **THEN** la suite de tests falla, en lugar de propagar el contexto divergente

### Requirement: Los consumidores derivan actor y tenant de las fuentes canónicas

Todo consumidor del contexto de autenticación SHALL derivar la identidad del actor exclusivamente de la clave `user_id`, y NOT SHALL leer claves ausentes del contrato (en particular `sub` o `account_id`, que el contexto no expone). La cuenta (tenant) sobre la que opera un endpoint SHALL resolverse mediante la dependencia de resolución de cuenta del backend, y NOT SHALL derivarse de la identidad del usuario ni de ningún claim del JWT.

Un acceso a una clave inexistente con valor por defecto vacío SHALL considerarse un defecto, no una degradación aceptable: propaga una cadena vacía a columnas que esperan un identificador y produce un fallo del servidor aguas abajo.

#### Scenario: La creación de un presupuesto registra al actor real

- **WHEN** un usuario autenticado crea un presupuesto
- **THEN** el presupuesto se persiste con el identificador del usuario autenticado como autor, y el endpoint responde con éxito en lugar de fallar con un error del servidor

#### Scenario: Los endpoints de cuenta corriente operan sobre la cuenta resuelta

- **WHEN** un usuario autenticado consulta la cuenta corriente de un cliente o de un proveedor
- **THEN** la consulta se ejecuta contra la cuenta resuelta por la dependencia de resolución de cuenta, y el endpoint responde con éxito en lugar de fallar con un error del servidor

#### Scenario: Ningún consumidor lee claves fuera del contrato

- **WHEN** se revisa el backend en busca de lecturas del contexto de autenticación
- **THEN** toda lectura referencia únicamente claves declaradas en el contrato, sin valores por defecto que sustituyan una clave ausente

### Requirement: Los dobles de test no pueden divergir del contrato real

Los dobles de test que sustituyan el contexto de autenticación SHALL construirse a partir del contrato declarado, y la suite SHALL contener al menos una verificación que observe el identificador efectivamente propagado a la capa de datos en los endpoints que lo consumen. Un test NOT SHALL considerarse cobertura válida si su doble reproduce el mismo error que el código bajo prueba, de modo que ambos defectos se cancelen y el test pase.

#### Scenario: El test observa el identificador que llega a la capa de datos

- **WHEN** se ejercita un endpoint que persiste la identidad del actor o la cuenta del tenant
- **THEN** el test verifica el valor concreto recibido por el repositorio, y falla si ese valor es una cadena vacía o difiere del identificador autenticado
