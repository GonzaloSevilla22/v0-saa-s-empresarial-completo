"""v3-rbac-multirole Parte B, grupo 10 (D10, D15): constantes de capacidad de
`backend/core/rbac.py`.

RED (10.7): antes de que `backend/core/rbac.py` existiera, este import
fallaba con ImportError — la prueba de que el módulo es necesario, no
decorativo.
"""
from __future__ import annotations


def test_can_configure_matches_current_15_call_sites_set():
    """CAN_CONFIGURE debe ser exactamente {owner, admin} — el conjunto que
    ya usan las 15 llamadas de cost_centers/payment_methods/
    product_categories/account_charges. Cambiar este valor cambiaría el
    comportamiento de las 15 sin que nadie lo pida (D15: "las 15 llamadas
    quedan exactamente iguales")."""
    from backend.core.rbac import CAN_CONFIGURE

    assert set(CAN_CONFIGURE) == {"owner", "admin"}


def test_capability_constants_are_derived_from_d15_matrix():
    """Las 6 capacidades de D15 existen con el conjunto normativo exacto."""
    from backend.core import rbac

    assert set(rbac.CAN_SELL) == {"owner", "admin", "seller", "cashier"}
    assert set(rbac.CAN_CASH) == {"owner", "admin", "cashier"}
    assert set(rbac.CAN_STOCK) == {"owner", "admin", "stock"}
    assert set(rbac.CAN_PURCHASE) == {"owner", "admin", "purchases"}
    assert set(rbac.CAN_ACCOUNT) == {"owner", "admin", "accountant"}


def test_capability_constants_only_use_catalog_codes():
    """Ronda 1 adversarial (nit 11, renombrado): cada código en las 6
    capacidades de TENANT pertenece al catálogo real de
    account_role_catalog (owner/admin/seller/cashier/stock/purchases/
    accountant/viewer) — nunca un código inventado. Este test se llamaba
    `..._are_disjoint_from_platform_role_namespace`, pero su aserción
    (`values <= catalog_codes`) nunca probó disyunción de namespaces —
    "todos los códigos están en el catálogo" es una afirmación distinta, y
    una disyunción LITERAL contra el vocabulario de plataforma sería
    imposible de sostener en general: `admin` vive a propósito en los DOS
    vocabularios (authz-token-claims D1). El nombre ahora dice lo que el
    test realmente verifica; el candado real contra la deriva del namespace
    de plataforma vive en el test siguiente."""
    from backend.core import rbac

    catalog_codes = {
        "owner", "admin", "seller", "cashier", "stock", "purchases",
        "accountant", "viewer",
    }
    for name in ("CAN_CONFIGURE", "CAN_SELL", "CAN_CASH", "CAN_STOCK", "CAN_PURCHASE", "CAN_ACCOUNT"):
        values = set(getattr(rbac, name))
        assert values <= catalog_codes, f"{name} tiene un código fuera del catálogo: {values - catalog_codes}"


def test_capability_constants_never_leak_the_platform_only_role_code():
    """Ronda 1 adversarial (nit 11, candado real de disyunción de
    namespaces): el ÚNICO código EXCLUSIVO de plataforma (`profiles.role`)
    es `user` — `admin` es compartido A PROPÓSITO entre plataforma y
    tenant (authz-token-claims D1 lo advierte explícitamente), así que no
    puede ser el criterio de disyunción. Ninguna de las 6 capacidades de
    TENANT debe contener jamás `user` — eso sí sería colar el vocabulario
    de plataforma en una decisión de rol de cuenta, y es la propiedad que
    el nombre del test anterior prometía verificar."""
    from backend.core import rbac

    platform_only_codes = {"user"}
    for name in ("CAN_CONFIGURE", "CAN_SELL", "CAN_CASH", "CAN_STOCK", "CAN_PURCHASE", "CAN_ACCOUNT"):
        values = set(getattr(rbac, name))
        assert values.isdisjoint(platform_only_codes), (
            f"{name} coló un código exclusivo de plataforma: {values & platform_only_codes}"
        )
