# data-export — Delta

## ADDED Requirements

### Requirement: La superficie de exportación informa el resultado por el sistema de toast canónico

El sistema SHALL comunicar al usuario el resultado de toda exportación disparada desde un `ExportButton` — éxito (con la referencia a `/exportaciones`), cuota agotada, o error — mediante el sistema de toast montado y canónico de la app (`sonner`). Ninguna rama de resultado del botón SHALL emitirse por un sistema de toast cuyo componente de render no esté montado en el layout. La app SHALL mantener un único sistema de toast montado.

#### Scenario: Éxito visible

- **GIVEN** una exportación que la Edge Function acepta
- **WHEN** la generación se dispara correctamente
- **THEN** el usuario ve un toast de confirmación

#### Scenario: Error visible

- **GIVEN** la Edge Function de exportación no disponible
- **WHEN** el usuario toca "Exportar … CSV"
- **THEN** el usuario ve un toast de error, nunca un silencio

#### Scenario: Cuota agotada visible

- **GIVEN** una cuenta con la cuota mensual de exportaciones agotada
- **WHEN** el usuario intenta exportar
- **THEN** el usuario ve el aviso de cuota con el CTA de upgrade que corresponda
