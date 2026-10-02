"""
Documentos comerciales no fiscales (presupuestos-modulo; los remitos los
reutilizan después).

Tres piezas, separadas a propósito (como `factura-fiscal-imprimible`):

  - `numbering`: etiqueta visible del número interno (`P-00000012`) y lectura
    del texto que el usuario busca en el listado.
  - `view`: la vista pura `CommercialDocumentView` y su constructor
    `build_quote_view` (sin I/O).
  - `issuer`: resolución del emisor SIN bloquear, sobre lo que devuelve
    `rpc_commercial_issuer`.
  - `pdf`: `build_commercial_document_pdf(view)`, el render con `fpdf2`.
"""
