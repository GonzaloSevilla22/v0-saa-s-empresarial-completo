"""
v22-afip-delegation-billing — PlatformCredentialProvider.

Proveedor del certificado del representante de la plataforma (CRÍTICO — governance).

Lee el cert + key + CUIT del representante desde `settings` (env vars del backend):
  - AFIP_PLATFORM_CERT: contenido PEM del certificado (.crt)
  - AFIP_PLATFORM_KEY:  contenido PEM de la clave privada (.key)
  - AFIP_PLATFORM_CUIT: CUIT del representante (ej. "20422662457")

La clave privada es el secreto más sensible del sistema: permite firmar TRAs de WSAA
y facturar por CUALQUIER CUIT representado. Restricciones DURAS:
  - NUNCA logueada en ningún nivel (DEBUG, INFO, WARNING, ERROR)
  - NUNCA incluida en __repr__, __str__ u otras representaciones del objeto
  - NUNCA devuelta en ningún endpoint de la API
  - Solo accesible via get_key() en el adapter, justo antes de firmar la TRA

Design ref: D3 (cert de plataforma server-side, OQ-3)
Spec ref: specs/afip-platform-credential/spec.md §"Certificado representante de la plataforma"
"""
from __future__ import annotations

import logging
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from backend.core.config import Settings

logger = logging.getLogger(__name__)


class PlatformCredentialProvider:
    """Proveedor del certificado del representante de la plataforma.

    Diseñado para ser inyectado en WSFEAdapter y build_cae_adapter.
    Inmutable post-construcción (los campos se leen de settings una vez).

    Seguridad:
      - __repr__ y __str__ muestran solo el CUIT y si está configurado — nunca el PEM.
      - get_key() retorna bytes; el caller (adapter) lo usa y descarta. No cachear afuera.
      - is_configured() es seguro de llamar en cualquier lugar (no expone material).
    """

    def __init__(self, settings: "Settings") -> None:
        # Los valores se leen en el constructor para que el provider sea inmutable.
        # _cert y _key son bytes (convertidos desde str PEM de env).
        # NUNCA loguear _key.
        self._cert_pem: str = (settings.afip_platform_cert or "").strip()
        self._key_pem:  str = (settings.afip_platform_key  or "").strip()
        self._cuit:     str = (settings.afip_platform_cuit or "").strip()

        # Solo logueamos el estado de configuración (nunca el contenido de la key).
        is_ok = self._is_configured_internal()
        logger.debug(
            "PlatformCredentialProvider: configurado=%s, CUIT representante=%s",
            is_ok,
            self._cuit if is_ok else "<no configurado>",
        )

    def _is_configured_internal(self) -> bool:
        """Verifica internamente que cert + key + CUIT están presentes."""
        return bool(self._cert_pem and self._key_pem and self._cuit)

    def is_configured(self) -> bool:
        """Retorna True si el cert + key + CUIT del representante están configurados.

        Seguro de llamar en factory/router para decidir real-vs-stub.
        No expone ningún material criptográfico.
        """
        return self._is_configured_internal()

    def get_cert(self) -> bytes:
        """Retorna el certificado del representante como bytes PEM.

        Raises:
            RuntimeError: si el cert no está configurado (AFIP_PLATFORM_CERT vacío).
        """
        if not self._cert_pem:
            raise RuntimeError(
                "Certificado del representante de plataforma no configurado. "
                "Configurar la variable de entorno AFIP_PLATFORM_CERT en el backend."
            )
        return self._cert_pem.encode("utf-8")

    def get_key(self) -> bytes:
        """Retorna la clave privada del representante como bytes PEM.

        GOVERNANCE CRÍTICO: esta función entrega el secreto más sensible del sistema.
        El caller debe usarla inmediatamente (firmar TRA) y no guardar la referencia.

        Raises:
            RuntimeError: si la key no está configurada (AFIP_PLATFORM_KEY vacío).
        """
        if not self._key_pem:
            raise RuntimeError(
                "Clave privada del representante de plataforma no configurada. "
                "Configurar la variable de entorno AFIP_PLATFORM_KEY en el backend."
            )
        # CRÍTICO: no logueamos el valor. El logger.debug de __init__ tampoco lo hace.
        return self._key_pem.encode("utf-8")

    def get_cuit(self) -> str:
        """Retorna el CUIT del representante de la plataforma.

        Raises:
            RuntimeError: si el CUIT no está configurado (AFIP_PLATFORM_CUIT vacío).
        """
        if not self._cuit:
            raise RuntimeError(
                "CUIT del representante de plataforma no configurado. "
                "Configurar la variable de entorno AFIP_PLATFORM_CUIT en el backend."
            )
        return self._cuit

    def __repr__(self) -> str:
        """Representación segura — NO incluye el PEM de la clave privada."""
        cuit_display = repr(self._cuit) if self._cuit else "'<no configurado>'"
        return (
            f"PlatformCredentialProvider("
            f"configured={self._is_configured_internal()}, "
            f"cuit={cuit_display}"
            f")"
        )

    def __str__(self) -> str:
        """Str seguro — NO incluye el PEM de la clave privada."""
        return self.__repr__()
