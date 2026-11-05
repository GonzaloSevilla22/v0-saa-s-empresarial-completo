## ADDED Requirements

### Requirement: Cambiar la forma de pago al editar traslada el efecto entre libros
El sistema SHALL tratar el cambio de forma de pago en la edición de una venta, una compra o un gasto como un cambio de **contrato de pago**. El efecto de la operación se traslada al libro que corresponde a la clase (`kind`) de la forma de pago final, derivada en el servidor desde el catálogo:

| Clase final | Libro |
|---|---|
| `credit` | cuenta corriente de la parte |
| `cash` | caja, con la intención de caja de la edición |
| `transfer`, `card`, `check`, `wallet` | banco, con la cuenta resuelta como en el alta |
| `other` o sin forma de pago | sin efecto |

El libro que deja de corresponder SHALL compensarse en la misma transacción, con las reglas de la capability `operation-money-edit`.

La comparación SHALL hacerse por valor: reenviar la misma forma de pago vigente SHALL NOT contarse como un cambio. La validación de pertenencia y de estado activo de una forma de pago reimputada SHALL ser la misma que en el alta.

#### Scenario: De cuenta corriente a efectivo
- **GIVEN** una venta a crédito impaga de 1000 de hoy y una sesión de caja abierta en su sucursal
- **WHEN** se edita a una forma de pago de efectivo, pidiendo registrar en esa sesión
- **THEN** la cuenta corriente del cliente recibe la reversión de 1000 y la caja un ingreso de 1000

#### Scenario: De efectivo a transferencia
- **GIVEN** una compra en efectivo con movimiento de caja y una forma de pago de transferencia con cuenta bancaria destino
- **WHEN** se edita a esa forma de pago
- **THEN** la caja recibe la reversión del egreso y el banco el egreso nuevo

#### Scenario: Reenviar la misma forma de pago no traslada nada
- **WHEN** se edita una operación reenviando su forma de pago vigente y sin cambiar el importe
- **THEN** ningún libro recibe movimientos
