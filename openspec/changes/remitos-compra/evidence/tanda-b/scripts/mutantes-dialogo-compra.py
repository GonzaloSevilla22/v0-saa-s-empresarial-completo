"""Triangulación por mutantes del frontend de la conversión (remitos-compra tanda B, 7.4-7.9).

Cada mutante rompe UNA regla en UN archivo; la suite de tests asociada tiene que fallar
(mutante muerto). Restaura cada archivo al terminar (también si algo falla). Uso, desde
cualquier carpeta:

    C:/.../python.exe -u .../mutantes-dialogo-compra.py            # ConvertPurchaseDeliveryNoteDialog (7.4/7.5)
    C:/.../python.exe -u .../mutantes-dialogo-compra.py detalle    # detalle del remito de compra (7.6)
    C:/.../python.exe -u .../mutantes-dialogo-compra.py aviso      # aviso contra la doble suma (7.9)
"""
import pathlib
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[6]
SUITE = sys.argv[1] if len(sys.argv) > 1 else "dialogo"
PNPM = "pnpm.cmd" if sys.platform == "win32" else "pnpm"
NL = "\n"

DIALOGO = "frontend/components/delivery-notes/ConvertPurchaseDeliveryNoteDialog.tsx"
DETALLE = "frontend/app/(dashboard)/remitos/[id]/page.tsx"
AVISO = "frontend/components/delivery-notes/PendingPurchaseNotesNotice.tsx"
FORM = "frontend/components/forms/purchase-form.tsx"
MODAL = "frontend/components/invoice/InvoiceReviewModal.tsx"
BOTON = "frontend/components/invoice/InvoiceAIButton.tsx"
STATUS = "frontend/lib/delivery-note-status.ts"

# (nombre, archivo, patrón exacto, reemplazo)
DIALOGO_MUTANTS = [
    ("M1 el payload manda supplier_id", DIALOGO,
     "        date," + NL + "        // Con efectivo", "        date," + NL + "        supplier_id: deliveryNote.supplier_id," + NL + "        // Con efectivo"),
    ("M2 la forma de pago deja de ser obligatoria (se ofrece 'Sin especificar')", DIALOGO,
     "            paymentRequired" + NL, "            paymentRequired={false}" + NL),
    ("M3 el vencimiento viaja aunque no sea crédito", DIALOGO,
     "due_date: checkout.isCredit ? dueDate.valueForServer : null,", "due_date: dueDate.valueForServer,"),
    ("M4 el vencimiento viaja sin que el usuario lo toque", DIALOGO,
     "due_date: checkout.isCredit ? dueDate.valueForServer : null,", "due_date: checkout.isCredit ? dueDate.dueDate || null : null,"),
    ("M5 se permite una fecha anterior a la recepción", DIALOGO,
     "      : date < deliveryNote.issued_on" + NL, "      : false" + NL),
    ("M6 invalid_state no recarga el remito", DIALOGO,
     "/delivery_note_changed|delivery_note_invalid_state/", "/delivery_note_changed/"),
    ("M7 la clave de idempotencia usa el alcance de VENTA", DIALOGO,
     "`delivery-note-purchase-convert:${deliveryNote.id}`", "`delivery-note-convert:${deliveryNote.id}`"),
    ("M8 el plazo del proveedor no se consulta", DIALOGO,
     "useSupplier(supplierId)", "useSupplier(null)"),
    ("M9 la caja se resuelve sin la sucursal del remito", DIALOGO,
     "    branchId: deliveryNote.branch_id," + NL + "    date,", "    branchId: null," + NL + "    date,"),
    ("M10 la confirmación no exige forma de pago", DIALOGO,
     "confirmDisabled={blockReason !== null || checkout.creditBlockedNoSupplier}", "confirmDisabled={false}"),
    ("M11 el crédito sin proveedor deja confirmar", DIALOGO,
     "confirmDisabled={blockReason !== null || checkout.creditBlockedNoSupplier}", "confirmDisabled={blockReason !== null}"),
    ("M12 cambiar de forma de pago conserva la cuenta bancaria", DIALOGO,
     "    setBankAccountId(null)" + NL + "  }", "  }"),
    ("M13 el mensaje del remito ya convertido habla de venta", DIALOGO,
     "ya fue convertido en compra", "ya fue convertido en venta"),
    ("M14 humaniza como remito de venta", DIALOGO,
     '{ documentLabel: "remito", direction: "purchase" }', '{ documentLabel: "remito", direction: "sale" }'),
    ("M15 la expected_revision no viaja", DIALOGO,
     "        expected_revision: deliveryNote.revision," + NL, "        expected_revision: 0," + NL),
]
DIALOGO_TESTS = ["__tests__/components/ConvertPurchaseDeliveryNoteDialog.test.tsx"]

DETALLE_MUTANTS = [
    ("D1 la conversión sigue deshabilitada para compra", DETALLE,
     "    conversionEnabled: true," + NL, "    conversionEnabled: !isPurchase," + NL),
    ("D2 el botón de compra abre el diálogo de VENTA", DETALLE,
     "          <ConvertPurchaseDeliveryNoteDialog deliveryNote={note}", "          <ConvertDeliveryNoteDialog deliveryNote={note}"),
    ("D3 el botón se llama siempre 'Venta'", DETALLE,
     '{isPurchase ? "Compra" : "Venta"}', '{"Venta"}'),
    ("D4 el motivo deshabilitado no se asocia al botón", DETALLE,
     "aria-describedby={actions.convert.disabledReason ? CONVERT_REASON_ID : undefined}", ""),
    ("D5 el diálogo se monta sin que se haya abierto", DETALLE,
     "{convertOpen &&" + NL + "        (isPurchase", "{(convertOpen || true) &&" + NL + "        (isPurchase"),
    ("D6 el diálogo se desmonta al pasar a convertido", DETALLE,
     "{convertOpen &&" + NL + "        (isPurchase", '{convertOpen && note.status === "issued" &&' + NL + "        (isPurchase"),
    ("D7 la capacidad de compra es la de venta", DETALLE,
     "canSell: hasCapability(roles, isPurchase ? CAN_CONVERT_PURCHASE_DELIVERY_NOTE : CAN_SELL, rolesResolved),",
     "canSell: hasCapability(roles, CAN_SELL, rolesResolved),"),
]
DETALLE_TESTS = ["__tests__/DeliveryNoteDetailPage.test.tsx"]

AVISO_MUTANTS = [
    ("A1 sin proveedor (null) igual consulta y avisa", AVISO,
     "  if (supplierId === null) return null" + NL, "  if (supplierId === null && false) return null" + NL),
    ("A2 el aviso consulta también los remitos de venta", AVISO,
     '    direction: "purchase",' + NL, ""),
    ("A3 el aviso cuenta también los ya convertidos", AVISO,
     '    status: "issued",' + NL, ""),
    ("A4 con proveedor no se acota al proveedor", AVISO,
     "    ...(supplierId ? { supplierId } : {})," + NL, ""),
    ("A5 pide la página completa en vez de una fila", AVISO,
     "    pageSize: 1," + NL, ""),
    ("A6 el aviso pasa a ser una alerta", AVISO,
     '      role="note"' + NL + '      className="flex items-start', '      role="alert"' + NL + '      className="flex items-start'),
    ("A7 el enlace pierde el filtro de proveedor", AVISO,
     "href={pendingPurchaseNotesHref(supplierId)}", "href={pendingPurchaseNotesHref()}"),
    ("A8 el formulario avisa también al EDITAR", FORM,
     "{!isEdit && <PendingPurchaseNotesNotice supplierId={supplierId} />}", "{<PendingPurchaseNotesNotice supplierId={supplierId} />}"),
    ("A9 el formulario no monta el aviso", FORM,
     "{!isEdit && <PendingPurchaseNotesNotice supplierId={supplierId} />}", "{null}"),
    ("A10 la revisión de Factura IA no muestra el aviso", MODAL,
     '          {notice && <div className="mb-4">{notice}</div>}', ""),
    ("A11 el botón de Factura IA no pasa el aviso", BOTON,
     "          notice={<PendingPurchaseNotesNotice />}", ""),
    ("A12 la Factura IA acota el aviso a un proveedor inexistente (null)", BOTON,
     "notice={<PendingPurchaseNotesNotice />}", "notice={<PendingPurchaseNotesNotice supplierId={null} />}"),
    ("A13 el texto pierde el singular", STATUS,
     'const noun = count === 1 ? "remito de compra pendiente" : "remitos de compra pendientes"',
     'const noun = "remitos de compra pendientes"'),
    ("A14 el enlace no escapa el proveedor", STATUS,
     "`${base}&proveedor=${encodeURIComponent(supplierId)}`", "`${base}&proveedor=${supplierId}`"),
]
AVISO_TESTS = [
    "__tests__/lib/delivery-note-pending-notice.test.ts",
    "__tests__/components/PendingPurchaseNotesNotice.test.tsx",
    "__tests__/components/purchase-form-pending-delivery-notes.test.tsx",
    "__tests__/components/invoice-ai-pending-delivery-notes.test.tsx",
]

SUITES = {
    "dialogo": (DIALOGO_MUTANTS, DIALOGO_TESTS),
    "detalle": (DETALLE_MUTANTS, DETALLE_TESTS),
    "aviso": (AVISO_MUTANTS, AVISO_TESTS),
}


def run_tests(tests: list[str]) -> int:
    proc = subprocess.run(
        [PNPM, "vitest", "run", *tests],
        cwd=ROOT / "frontend", capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=900,
    )
    return proc.returncode


def main() -> int:
    mutants, tests = SUITES[SUITE]
    originals: dict[pathlib.Path, bytes] = {}
    survivors: list[str] = []
    try:
        for _, rel, _, _ in mutants:
            path = ROOT / rel
            originals.setdefault(path, path.read_bytes())
        baseline = run_tests(tests)
        print(f"baseline: exit {baseline}")
        if baseline != 0:
            print("el test no está verde sin mutar: abortando")
            return 2
        for name, rel, old, new in mutants:
            path = ROOT / rel
            text = originals[path].decode("utf-8")
            if text.count(old) != 1:
                print(f"{name}: PATRÓN NO ENCONTRADO (o ambiguo) -> {text.count(old)} coincidencias")
                survivors.append(name + " (patrón)")
                continue
            path.write_bytes(text.replace(old, new).encode("utf-8"))
            try:
                code = run_tests(tests)
            finally:
                path.write_bytes(originals[path])
            status = "MUERTO" if code != 0 else "SOBREVIVIÓ"
            print(f"{name}: {status}")
            if code == 0:
                survivors.append(name)
    finally:
        for path, data in originals.items():
            path.write_bytes(data)
    print("sobrevivientes:", survivors or "ninguno")
    return 0 if not survivors else 1


if __name__ == "__main__":
    sys.exit(main())
