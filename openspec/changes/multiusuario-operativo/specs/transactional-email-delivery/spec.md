## ADDED Requirements

### Requirement: Plantilla de correo de invitación a una cuenta
La función de envío SHALL contar con una plantilla propia para la invitación a una cuenta, que nombre a quien invita, al negocio, los roles con que se incorpora y el vencimiento, y que lleve un único botón de acción hacia la pantalla de aceptación.

Todo dato provisto por un usuario que la plantilla interpole —nombre del negocio, nombre de quien invita— SHALL escaparse como texto antes de insertarse en el HTML. El enlace del botón SHALL construirse con la URL fija de la aplicación y el token de la invitación codificado, y NOT SHALL tomar ninguna URL ni dominio de los datos de la fila.

#### Scenario: El nombre del negocio con marcado se muestra como texto
- **GIVEN** una invitación cuyo nombre de negocio contiene etiquetas HTML
- **WHEN** se envía el email de invitación
- **THEN** el email muestra el nombre como texto literal, sin interpretar las etiquetas

#### Scenario: El enlace apunta siempre a la aplicación
- **GIVEN** una fila de invitación cuyos datos incluyen una URL de otro dominio
- **WHEN** se arma el email de invitación
- **THEN** el botón apunta a la pantalla de aceptación de la aplicación con el token de la invitación, y la URL ajena no aparece en el email
