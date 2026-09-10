## REMOVED Requirements

### Requirement: El importador de gastos no imputa forma de pago

**Reason**: El requirement prohibía imputar forma de pago en el importador **por una limitación técnica que él mismo declara** como su motivo: *"el importador emite una llamada por fila sin transacción que abarque el lote: con impacto en libros, un fallo a mitad del proceso dejaría parte de los gastos con movimiento y parte sin él, sin forma de reconstruir el estado"*. Este change elimina esa limitación —la importación pasa a ser una única unidad de trabajo de servidor, todo o nada— con lo que la condición que sostenía la prohibición deja de valer y la prohibición pasaría a impedir el comportamiento correcto. La cláusula de la ayuda que el requirement exigía tampoco puede sobrevivir tal cual: afirmaba que *"los gastos importados quedan sin forma de pago y sin impacto en caja ni en banco"*, que a partir de este change es falso para el banco.

**Migration**: El comportamiento pasa a la capability `expense-import`, que lo reemplaza sin perder nada de lo que este requirement protegía:

- **La verdad de la ayuda se conserva y se acota, no se suelta.** Lo que el requirement realmente defendía —que el importador no prometa un efecto que el sistema no produce— sigue siendo normativo en `expense-import`, ahora aplicado al único libro donde el efecto sigue ausente: el aviso de que los gastos en efectivo importados **no impactan la caja** es obligatorio y no puede omitirse, con el motivo (el libro de caja es por sesión, se arquea y se firma) y con el camino alternativo (cargarlo desde el formulario).
- **La atomicidad deja de ser una promesa y pasa a ser un requirement verificable**: `expense-import` exige que el lote sea una función `SECURITY DEFINER` todo-o-nada, prohíbe trocearlo y prohíbe implementarlo como llamadas independientes por fila.
- **La edición de un gasto sigue sin postear movimientos** (requirement "El gasto con dinero posteado es inmutable" y el contrato tri-estado, ambos intactos en esta capability). Lo que cambia es que ya no hace falta apoyarse en la edición: el gasto importado nace con su forma de pago y con su movimiento bancario.
- **Los gastos ya importados no se tocan**: conservan `payment_method_id` nulo y ningún efecto en libros, sin backfill, por el mismo criterio de "no inventar un dato" con el que quedaron los 175 gastos históricos.
- El template de cuatro columnas **sigue siendo válido**: las columnas nuevas son opcionales.
