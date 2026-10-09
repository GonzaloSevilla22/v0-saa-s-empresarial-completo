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

# stock-ledger-solo-rpc (D5, OQ-2): ajustar el stock A MANO. PRIMER CONSUMIDOR:
# `POST /products` con stock inicial distinto de cero
# (`services/products.py::create_product`, 403 antes de escribir nada). ESPEJA
# el literal `ARRAY['owner', 'admin', 'stock']` de `_stock_assert_can_adjust`
# (migración 20261074000001) —la base es quien lo exige de verdad en las tres
# RPCs de ajuste— y `CAN_STOCK` de `frontend/lib/rbac-capabilities.ts`: un test
# del frontend (`__tests__/lib/rbac-capabilities.test.ts`) lee los tres y falla
# si divergen. Es una capacidad de ACCIÓN, no un sinónimo del rol `stock`: hoy
# coincide con `CAN_RECEIVE_PURCHASE` (abajo) pero va con nombre propio.
CAN_STOCK: frozenset[str] = frozenset({"owner", "admin", "stock"})
CAN_PURCHASE: frozenset[str] = frozenset({"owner", "admin", "purchases"})
CAN_ACCOUNT: frozenset[str] = frozenset({"owner", "admin", "accountant"})
# presupuestos-modulo (D11): crear, editar, enviar, rechazar, eliminar y
# convertir presupuestos. ESPEJA los `allowed_role` de las transiciones de
# `quote` del catálogo `document_status_transitions` (seed de
# v3-rbac-multirole + las dos filas de reapertura de 20261067000001): un test
# (`backend/tests/test_quotes_module.py::TestCanQuote`) lee esas migraciones y
# falla si divergen. El cajero lee presupuestos pero no los escribe: la
# conversión compromete una cotización, no sólo cobra un mostrador.
CAN_QUOTE: frozenset[str] = frozenset({"owner", "admin", "seller"})

# remitos-venta (D13): emitir y editar un remito de venta, y anularlo. ESPEJAN
# los `allowed_role` de las transiciones `NULL -> issued` y `issued -> canceled`
# de `delivery_note_sale` del catálogo `document_status_transitions`
# (migración 20261069000001): un test
# (`backend/tests/test_delivery_notes_module.py::TestCapabilities`) lee esa
# migración y falla si divergen. `stock` emite y edita (carga lo que sale del
# depósito) pero no anula; el cajero lee y convierte en venta (`CAN_SELL`) pero
# no emite.
#
# `CAN_VOID_DELIVERY_NOTE` tiene el MISMO contenido que `CAN_CONFIGURE`, así
# que `is_sensitive_capability` lo trata como sensible: la autoridad es la base
# (el pivot de roles) y no el claim del token. Es deliberado para una acción que
# DEVUELVE stock al depósito: ante un claim desactualizado el error queda del
# lado seguro.
CAN_DELIVER_SALE: frozenset[str] = frozenset({"owner", "admin", "seller", "stock"})
CAN_VOID_DELIVERY_NOTE: frozenset[str] = frozenset({"owner", "admin"})

# remitos-compra (D12): recibir (emitir y editar) un remito de compra y convertirlo
# en compra. `CAN_RECEIVE_PURCHASE` ESPEJA la fila `NULL -> issued` de
# `delivery_note_purchase` del catálogo `document_status_transitions` (migración
# 20261071000001) y la anulación reutiliza `CAN_VOID_DELIVERY_NOTE`, que espeja
# `issued -> canceled` en los dos sentidos: un test
# (`test_delivery_notes_module.py::TestPurchaseCapabilities`) lee las migraciones
# y falla si divergen.
#
# `CAN_RECEIVE_PURCHASE` tiene hoy el MISMO contenido que `CAN_STOCK`, pero va con
# nombre propio por acción (igual que `CAN_DELIVER_SALE` y `CAN_VOID_DELIVERY_NOTE`
# arriba): si un día "depósito" y "recepción de mercadería" divergen, cambia una
# constante y no todas las pantallas de stock. El vendedor NO recibe mercadería.
#
# `CAN_CONVERT_PURCHASE_DELIVERY_NOTE` suma `stock` a `CAN_PURCHASE` (OQ-RC6):
# hoy cualquier escritor registra compras directas, que vuelven a sumar el stock;
# si quien recibió no pudiera convertir, su único camino con la factura en la mano
# sería esa doble suma. La conversión es de la tanda B; su fila del catálogo
# (`issued -> converted`) y el test que la ata llegan con ella.
CAN_RECEIVE_PURCHASE: frozenset[str] = frozenset({"owner", "admin", "stock"})
CAN_CONVERT_PURCHASE_DELIVERY_NOTE: frozenset[str] = frozenset({"owner", "admin", "purchases", "stock"})

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
