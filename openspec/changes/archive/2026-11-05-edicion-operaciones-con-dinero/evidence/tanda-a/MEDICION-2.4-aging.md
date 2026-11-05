# Medición 2.4 — reparto del aging antes y después del emparejamiento (prod, sólo SELECT, 2026-11-04)

Consulta de sólo lectura sobre prod, con la regla vieja y la nueva escritas en línea (sin crear nada), para las cuentas
corrientes que tienen alguna reversión de cargo (`credit_note` de cliente / `debit_note` de proveedor).

Clientes (5 cuentas corrientes con `credit_note`, 7 notas en total; todas con su cargo `sale` de la misma referencia):

| Cuenta (8 primeros) | Saldo | Regla vieja (sin venc. / vigente / 1-30 / 31-60 / 60+) | Regla nueva |
|---|---|---|---|
| 02422abd | 0 | 0 / 0 / 0 / 0 / 0 | idéntico |
| 7aa5bd2f | 45.000 | 0 / 45.000 / 0 / 0 / 0 | idéntico |
| b1819a2a | 0 | 0 / 0 / 0 / 0 / 0 | idéntico |
| c51d117f | 12.000 | 0 / 12.000 / 0 / 0 / 0 | idéntico |
| f023d7cc | 0 | 0 / 0 / 0 / 0 / 0 | idéntico |

Proveedores (1 cuenta con `debit_note`): abierto total 0 antes y después, saldo 0.

Resultado: **ningún tramo cambia hoy** y el saldo total es el mismo (la suma de lo abierto coincide con el saldo en las
seis cuentas). El design preveía un cambio de reparto en esas cuentas; con los datos de hoy no ocurre porque en cada una
la reversión cancela cargos que el reparto viejo ya cancelaba (todas quedaron en saldo cero o con un único cargo vigente).
El efecto se verá con las ediciones futuras.
