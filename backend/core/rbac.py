"""v3-rbac-multirole Parte B (D10, D15): capacidades nombradas del backend de
TENANT, derivadas de la matriz normativa única (openspec/changes/
v3-rbac-multirole/design.md §D15). Un service NUNCA debe escribir un literal
`["owner", "admin"]` (o cualquier otro conjunto de roles) inline — declara acá
la capacidad una sola vez, con nombre, y el service importa la constante.

Por qué no una tabla `account_role_capabilities` (D10): sería infraestructura
nueva para una política que hoy tiene 6 entradas y cambia con la frecuencia de
una decisión de producto — la Regla de Tres no está alcanzada. Estas
constantes ya eliminan la dispersión, que era el problema real.

CAN_CONFIGURE deja las 15 llamadas existentes de `cost_centers`,
`payment_methods`, `product_categories` y `account_charges` con EXACTAMENTE el
mismo conjunto efectivo que hoy (`owner, admin`) — ningún comportamiento
cambia para ellas por este change.

Aclaración (D10): esta matriz de capacidades y la matriz FSM de
`document_status_transitions.allowed_role` (D15, base de datos) NO son dos
codificaciones de la misma política — la FSM gobierna *cambios de estado de
un documento*, las capacidades gobiernan *acceso a un endpoint*. Se solapan
pero no son redundantes; la tabla normativa única de la que ambas derivan es
§D15 del design.
"""
from __future__ import annotations

CAN_CONFIGURE: list[str] = ["owner", "admin"]
CAN_SELL: list[str] = ["owner", "admin", "seller", "cashier"]
CAN_CASH: list[str] = ["owner", "admin", "cashier"]
CAN_STOCK: list[str] = ["owner", "admin", "stock"]
CAN_PURCHASE: list[str] = ["owner", "admin", "purchases"]
CAN_ACCOUNT: list[str] = ["owner", "admin", "accountant"]
