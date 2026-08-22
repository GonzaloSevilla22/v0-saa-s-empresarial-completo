## ADDED Requirements

### Requirement: El ajuste manual entra a la conciliación como cualquier movimiento del sistema
El sistema SHALL tratar el movimiento bancario de tipo `manual_adjustment` como un movimiento del sistema más a los efectos de la conciliación: SHALL nacer con `reconciliation_status = 'unreconciled'`, SHALL aparecer entre los pendientes de la sesión de conciliación de su cuenta y período, y SHALL ser matcheable y desmatcheable con las mismas RPCs que el resto, sin piezas nuevas ni excepciones en el algoritmo de matching.

#### Scenario: Un ajuste recién registrado aparece como pendiente
- **GIVEN** una sesión de conciliación abierta sobre una cuenta y un período
- **WHEN** se registra un `manual_adjustment` con `value_date` dentro de ese período
- **THEN** el movimiento aparece en los pendientes del lado del sistema con estado `unreconciled`

#### Scenario: Un ajuste se concilia contra una línea del extracto
- **GIVEN** un `manual_adjustment` pendiente y una línea de extracto por el mismo importe y fecha
- **WHEN** el usuario los concilia
- **THEN** el ajuste pasa a `matched` con `reconciled_at` seteado, por el mismo camino que cualquier otro movimiento

#### Scenario: El matching no distingue el tipo de ajuste
- **WHEN** se inspecciona la lógica de matching y de sugerencias
- **THEN** no existe ninguna rama ni excepción específica para `manual_adjustment`

### Requirement: La conciliación sigue sin tocar la contabilidad tras la incorporación de los ajustes
El sistema SHALL mantener la separación entre el ledger bancario y el libro diario también para los movimientos de ajuste: registrar, conciliar o desconciliar un `manual_adjustment` NO SHALL crear, modificar ni revertir ningún asiento contable.

#### Scenario: Conciliar un ajuste no genera asiento
- **WHEN** un `manual_adjustment` se concilia contra una línea de extracto
- **THEN** no se crea ni se modifica ningún asiento en el libro diario

#### Scenario: Cerrar una sesión con ajustes conciliados no genera asiento
- **WHEN** se cierra una sesión de conciliación que incluye ajustes manuales conciliados
- **THEN** el cierre registra la diferencia de la sesión como hasta ahora y no postea nada al libro diario
