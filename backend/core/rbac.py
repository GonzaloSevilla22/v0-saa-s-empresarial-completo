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

from typing import Collection

# auth-hardening-jwt-cookies D12: las capacidades pasan de `list` a
# `frozenset`. El motivo NO es estético — es que tienen que poder ser
# ELEMENTOS de un registro (abajo), y una lista no es hasheable. De paso, un
# conjunto es lo que estas constantes siempre fueron semánticamente: el orden
# nunca significó nada y la duplicación tampoco.
CAN_CONFIGURE: frozenset[str] = frozenset({"owner", "admin"})
CAN_SELL: frozenset[str] = frozenset({"owner", "admin", "seller", "cashier"})
CAN_CASH: frozenset[str] = frozenset({"owner", "admin", "cashier"})
CAN_STOCK: frozenset[str] = frozenset({"owner", "admin", "stock"})
CAN_PURCHASE: frozenset[str] = frozenset({"owner", "admin", "purchases"})
CAN_ACCOUNT: frozenset[str] = frozenset({"owner", "admin", "accountant"})

# auth-hardening-jwt-cookies D12 — registro EXPLÍCITO de las capacidades para
# las que la base es la autoridad y el claim es sólo un caché.
#
# Que sea un registro con nombre, y no una comparación contra el contenido,
# es la decisión. Las dos formas obvias no sirven:
#   - `allowed is CAN_CONFIGURE` se rompe en cuanto un caller pasa una copia
#     o un `frozenset(...)` reconstruido;
#   - `allowed == CAN_CONFIGURE` engancha CUALQUIER literal coincidente, que
#     es exactamente lo que el docstring de arriba prohíbe escribir pero nada
#     impide — un caller que pase `["owner","admin"]` inline empezaría a
#     pagar una query por request sin que nadie lo decidiera.
SENSITIVE_CAPABILITIES: frozenset[frozenset[str]] = frozenset({CAN_CONFIGURE})


def is_sensitive_capability(allowed: Collection[str]) -> bool:
    """¿El conjunto permitido es una capacidad sensible declarada?

    Exige que sea del TIPO de las capacidades (`frozenset`) y que esté en el
    registro. Una lista o una tupla con el mismo contenido no lo es: no es la
    capacidad nombrada, es una coincidencia de contenido.

    Un `frozenset` equivalente reconstruido a mano SÍ cuenta, y es
    deliberado: el error queda del lado seguro (activa el re-chequeo de más,
    nunca de menos).
    """
    return isinstance(allowed, frozenset) and allowed in SENSITIVE_CAPABILITIES
