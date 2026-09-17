# realtime-websocket — Spec

## Purpose

**Capability retirada.** El backend propio expuso un canal `WebSocket /ws/{room_id}` desde la Fase 5; `auth-hardening-jwt-cookies` lo **retiró** (2026-09-17): autenticaba el handshake leyendo el token de la **cadena de consulta** —donde queda en logs, en el `Referer` y en el historial—, no comprobaba vigencia, no autorizaba la sala y **nunca tuvo un consumidor** (cero referencias en `frontend/`). Lo que queda documentado acá no es un canal sino su **invariante negativo**: el candado que impide que esa superficie vuelva por descuido, y la regla de que el token viaje únicamente por el encabezado de autorización. El tiempo real de la aplicación es **Supabase Realtime** sobre la publicación `supabase_realtime` (`notifications` y `fiscal_documents`), con el alcance impuesto por la RLS de cada tabla y el filtro del canal como optimización de red, no como límite de seguridad (ver `in-app-notifications` y `afip-fiscal-document`).

## Requirements

### Requirement: El backend no expone un canal WebSocket propio

El backend NOT SHALL exponer ningún endpoint WebSocket, NOT SHALL registrar un router de WebSocket en la aplicación y NOT SHALL mantener un gestor de conexiones por salas.

El tiempo real de la aplicación SHALL resolverse exclusivamente por la integración de Realtime del proveedor sobre tablas con seguridad a nivel de fila, que es el mecanismo que la aplicación usa realmente y el que exigen las capacidades de notificaciones y de comprobantes fiscales. Cualquier necesidad futura de un canal propio SHALL modelarse en un change propio, con autorización de sala vinculada a la cuenta del portador, transporte del token fuera del parámetro de consulta, revalidación durante la vida de la conexión y su propia spec.

#### Scenario: No existe ninguna ruta WebSocket en la superficie del backend

- **WHEN** se inspecciona el documento de OpenAPI de la aplicación y el registro de routers
- **THEN** no existe ninguna ruta WebSocket ni ningún router de WebSocket registrado

#### Scenario: No existe gestor de conexiones ni su suite

- **WHEN** se inspecciona el árbol del backend
- **THEN** no existen el módulo del gestor de conexiones por salas ni su suite de tests

#### Scenario: El tiempo real llega por la integración del proveedor

- **WHEN** ocurre un evento que la interfaz debe reflejar sin recargar
- **THEN** el cliente lo recibe por la suscripción de Realtime del proveedor sobre la tabla correspondiente, con el alcance impuesto por la seguridad a nivel de fila

