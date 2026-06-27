# Ejemplos de comprobantes

PDFs de **muestra del layout** del comprobante de venta que genera la app.

- [`comprobante-ejemplo.pdf`](./comprobante-ejemplo.pdf) — venta con varios ítems y cliente nombrado.
- [`recibo-ejemplo.pdf`](./recibo-ejemplo.pdf) — venta a consumidor final.

## Datos ficticios

Estos archivos contienen **datos 100% inventados** (comercios "de Ejemplo", teléfonos `5555-xxxx`, emails en el TLD reservado `.test`, UUIDs de ceros). No hay PII de usuarios reales: son sólo una referencia visual del formato.

> ⚠️ Los comprobantes **reales** que la app exporta llevan datos personales (nombre del comercio, teléfono, email, cliente). **No los versiones** — el repo es público. El `.gitignore` ya bloquea `comprobante-ejemplo.pdf` y `recibo-ejemplo.pdf` en la raíz por ese motivo.

## Cómo se generan en la app

El layout sale de `generateReceiptHTML` en [`frontend/lib/receipt.ts`](../../frontend/lib/receipt.ts): un HTML autocontenido (CSS inline, sin dependencias) que dispara `window.print()` para "Guardar como PDF". Estos ejemplos reproducen ese layout (header con inicial del comercio, grilla cliente/fecha, tabla de ítems con subtotales en verde, total y pie "¡Gracias por su compra!").
