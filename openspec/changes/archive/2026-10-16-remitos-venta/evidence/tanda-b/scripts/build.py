"""Arma 20261070000001_remitos_venta_conversion.sql desde los cuerpos VIVOS.

Cada reescritura parte del pg_get_functiondef vivo (prod-live-b/, sin \\r) y
aplica parches por anclas EXACTAS que tienen que aparecer una sola vez. Escribe
además el cuerpo nuevo de cada función para el diff de evidence/.

uso: python build.py <stage>   (stage: 63 | 64 | 65 | full)
"""
import pathlib
import sys

B = pathlib.Path(__file__).parent
LIVE = B.parent / "prod-live-b"
FRAG = B / "frag"
WT = pathlib.Path("C:/Users/Usuario/Desktop/EIE/wt-remitos")
MIG = WT / "supabase/migrations/20261070000001_remitos_venta_conversion.sql"
EVID = WT / "openspec/changes/remitos-venta/evidence/tanda-b"


def read(p: pathlib.Path) -> str:
    return p.read_text(encoding="utf-8").replace("\r", "")


def patch(src: str, anchor: str, new: str, *, mode: str) -> str:
    n = src.count(anchor)
    if n != 1:
        raise SystemExit(f"ancla con {n} apariciones: {anchor[:90]!r}")
    if mode == "before":
        return src.replace(anchor, new + anchor)
    if mode == "after":
        return src.replace(anchor, anchor + new)
    if mode == "replace":
        return src.replace(anchor, new)
    raise ValueError(mode)


def live_def(name: str) -> str:
    s = read(LIVE / f"{name}.sql").rstrip("\n")
    assert s.endswith("$function$"), name
    return s


def live_comment(name: str) -> str:
    return read(LIVE / f"{name}.comment.txt").rstrip("\n")


def sql_literal(s: str) -> str:
    return "'" + s.replace("'", "''") + "'"


# ─── _c29_confirm_order_core ────────────────────────────────────────────────
def core() -> str:
    s = live_def("_c29_confirm_order_core")
    s = patch(s, "  v_cash_session_branch  uuid;\n", """  -- remitos-venta (D7): la orden nació de un remito — lo decide la columna
  -- persistida de la orden (sales_orders.source_delivery_note_id), NUNCA un
  -- parámetro: la firma no cambia.
  v_from_delivery_note   boolean := false;
  v_dn                   RECORD;
""", mode="after")
    s = patch(s, "  -- ─── pos-catalogo-pagos (D2): resolver el kind", """  -- ╔═══ remitos-venta (D7): orden nacida de un remito ═════════════════════╗
  -- El remito YA descontó el stock al emitirse: esta orden no lo vuelve a
  -- mover (rama del loop de más abajo). Antes de la primera escritura se
  -- revalida TODO, de forma autosuficiente (un guard que delega no es guard):
  -- una orden fabricada con un source_delivery_note_id válido pero con otro
  -- cliente, otra sucursal u otras líneas, o apuntando a un remito ajeno,
  -- anulado o ya convertido, rebota acá en lugar de regalar mercadería.
  -- El FOR UPDATE es un no-op si la conversión ya tiene el remito.
  IF v_order.source_delivery_note_id IS NOT NULL THEN
    SELECT * INTO v_dn
    FROM public.delivery_notes
    WHERE id = v_order.source_delivery_note_id
    FOR UPDATE;

    IF NOT FOUND
       OR v_dn.account_id <> v_account_id
       OR v_dn.direction <> 'sale'
       OR v_dn.status <> 'issued'
       OR v_dn.client_id IS DISTINCT FROM v_order.client_id
       OR v_dn.branch_id <> v_order.branch_id THEN
      RAISE EXCEPTION 'delivery_note_order_mismatch: la orden % no corresponde a un remito de venta pendiente de la misma cuenta, cliente y sucursal', p_sales_order_id
        USING ERRCODE = 'P0409';
    END IF;

    -- Multiconjunto de líneas (producto, unidad, cantidad) idéntico al del
    -- remito: dos EXCEPT ALL vacíos.
    IF EXISTS (
         SELECT soi.product_id, soi.unit_id, soi.quantity
         FROM public.sales_order_items soi
         WHERE soi.sales_order_id = p_sales_order_id
         EXCEPT ALL
         SELECT dni.product_id, dni.unit_id, dni.quantity
         FROM public.delivery_note_items dni
         WHERE dni.delivery_note_id = v_dn.id
       )
       OR EXISTS (
         SELECT dni.product_id, dni.unit_id, dni.quantity
         FROM public.delivery_note_items dni
         WHERE dni.delivery_note_id = v_dn.id
         EXCEPT ALL
         SELECT soi.product_id, soi.unit_id, soi.quantity
         FROM public.sales_order_items soi
         WHERE soi.sales_order_id = p_sales_order_id
       ) THEN
      RAISE EXCEPTION 'delivery_note_order_mismatch: las líneas de la orden % no son las del remito', p_sales_order_id
        USING ERRCODE = 'P0409';
    END IF;

    v_from_delivery_note := true;
  END IF;
  -- ╚════════════════════════════════════════════════════════════════════════╝

""", mode="before")
    s = patch(s, "    IF v_item.product_id IS NOT NULL THEN\n      -- v3-snapshot-pattern: se agrega sku, cost al lock existente.\n",
              """    IF v_item.product_id IS NOT NULL THEN
      -- remitos-venta (D7): con origen de remito se saltean el FOR UPDATE del
      -- producto, la normalización, el gate, el delta y el movimiento — no hay
      -- stock que proteger (el remito ya lo descontó) y el lock sólo sumaría
      -- superficie de interbloqueo contra otros remitos. La existencia del
      -- producto la garantiza la FK de delivery_note_items. Se conservan la
      -- fila legacy sales y sale_items, que toma los CUATRO snapshots de la
      -- línea de la orden (copiados del remito, sin re-leer el maestro:
      -- nombre y SKU del remito aunque el producto se haya renombrado, costo
      -- congelado al salir la mercadería — OQ-RV3/OQ-RV4).
      IF v_from_delivery_note THEN
        INSERT INTO public.sales
          (user_id, account_id, client_id, product_id, amount, quantity,
           unit_id, total, currency, date, operation_id, branch_id, canal,
           payment_method_id)
        VALUES
          (v_uid, v_account_id, v_order.client_id, v_item.product_id,
           v_item.price, v_item.quantity,
           v_item.unit_id, v_item.subtotal, 'ARS', public.reporting_local_today(),
           v_new_op_id, v_gate_branch, v_canal, p_payment_method_id)
        RETURNING id INTO v_new_sale_id;

        INSERT INTO public.sale_items (
          sale_id, product_id, account_id, variant_id, quantity, unit_id, price, subtotal,
          name_snapshot, sku_snapshot, unit_cost_snapshot, iva_rate_snapshot
        ) VALUES (
          v_new_sale_id, v_item.product_id, v_account_id, NULL,
          v_item.quantity, v_item.unit_id, v_item.price, v_item.subtotal,
          v_item.name_snapshot, v_item.sku_snapshot, v_item.unit_cost_snapshot, v_item.iva_rate_snapshot
        );

        CONTINUE;
      END IF;

      -- v3-snapshot-pattern: se agrega sku, cost al lock existente.
""", mode="replace")
    return s


# ─── rpc_delete_sale_operation ──────────────────────────────────────────────
def delete() -> str:
    s = live_def("rpc_delete_sale_operation")
    s = patch(s, "  v_voided_doc           jsonb;   -- venta-editable-sin-cae\n", """  -- remitos-venta (D9): venta nacida de un remito.
  v_source_dn            uuid;
  v_so_branch_id         uuid;
  v_dn_label             text;
  v_dn_status            text;
""", mode="after")
    s = patch(s, "  -- ── Guard fiscal (P0423) — MISMO helper que rpc_atomic_update_sale_operation ──", """  -- ── remitos-venta (D9): venta nacida de un remito ─────────────────────────
  -- La sucursal del remito (= la de la orden) tiene que estar activa y no
  -- cerrada ANTES de cualquier efecto: el guard de baja de sucursal no cuenta
  -- los remitos converted, así que una sucursal se puede vaciar y desactivar
  -- con un remito convertido; sin este guard, borrar la venta devolvería el
  -- remito a issued en una sucursal muerta (la conversión lo rechazaría y la
  -- anulación devolvería stock a una sucursal que no opera). FOR SHARE: una
  -- desactivación concurrente espera a este commit.
  IF v_sales_order_id IS NOT NULL THEN
    SELECT so.source_delivery_note_id, so.branch_id INTO v_source_dn, v_so_branch_id
    FROM public.sales_orders so
    WHERE so.id = v_sales_order_id;
  END IF;

  IF v_source_dn IS NOT NULL THEN
    SELECT COALESCE('R-' || lpad(dn.number::text, 8, '0'), 'del remito') INTO v_dn_label
    FROM public.delivery_notes dn
    WHERE dn.id = v_source_dn;

    PERFORM 1
    FROM public.branches b
    WHERE b.id = v_so_branch_id
      AND b.account_id = v_account_id
      AND b.is_active = TRUE
      AND b.status IS DISTINCT FROM 'closed'
    FOR SHARE;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'delivery_note_branch_inactive: la sucursal del remito % está desactivada o cerrada — reactivala antes de eliminar la venta', v_dn_label
        USING ERRCODE = 'P0422';
    END IF;
  END IF;

""", mode="before")
    s = patch(s, """  -- ── Reversa de stock (rpc_reverse_stock_movement, sin cambios — #417) ─────
  FOR v_row IN SELECT unnest(v_sale_ids) AS id LOOP
    PERFORM public.rpc_reverse_stock_movement(v_row.id, 'sale', COALESCE(p_reason, 'Venta eliminada'));
  END LOOP;
""", """  -- ── Reversa de stock (rpc_reverse_stock_movement, sin cambios — #417) ─────
  -- remitos-venta (D9): una venta nacida de un remito NO repone stock: la
  -- mercadería quedó entregada con el remito, que vuelve a pendiente más
  -- abajo (para devolverla al stock se anula el remito). El salto es
  -- explícito: no depende de que esas filas sales no tengan movimientos.
  IF v_source_dn IS NULL THEN
    FOR v_row IN SELECT unnest(v_sale_ids) AS id LOOP
      PERFORM public.rpc_reverse_stock_movement(v_row.id, 'sale', COALESCE(p_reason, 'Venta eliminada'));
    END LOOP;
  END IF;
""", mode="replace")
    s = patch(s, "  -- ── DELETE + limpieza de idempotencia ─────────────────────────────────────", """  -- ── remitos-venta (D9, R5): el remito vuelve a pendiente ─────────────────
  -- Lock del remito AL FINAL (sales -> sales_orders -> fiscal_documents ->
  -- delivery_notes). La orden ya pasó a canceled, así que el índice único
  -- parcial queda libre y el remito se puede volver a convertir. La
  -- transición converted -> issued no tiene rol propio: este borrado ya
  -- registró sales_order confirmed -> canceled, que exige admin/owner.
  IF v_source_dn IS NOT NULL AND v_sales_order_id IS NOT NULL AND v_so_status = 'confirmed' THEN
    SELECT dn.status INTO v_dn_status
    FROM public.delivery_notes dn
    WHERE dn.id = v_source_dn
    FOR UPDATE;

    IF v_dn_status = 'converted' THEN
      PERFORM public.record_status_transition(
        v_account_id, 'delivery_note_sale', v_source_dn, 'converted', 'issued',
        v_uid, format('Venta eliminada (operación %s)', v_operation_key)
      );

      UPDATE public.delivery_notes
      SET status = 'issued', updated_at = now(), updated_by = v_uid
      WHERE id = v_source_dn;
    END IF;
  END IF;

""", mode="before")
    return s


# ─── rpc_atomic_update_sale_operation ───────────────────────────────────────
def atomic() -> str:
    s = live_def("rpc_atomic_update_sale_operation")
    s = patch(s, "  v_resync_id           uuid;     -- orden re-apuntada que se recalcula (N3)\n",
              "  v_dn_label            text;     -- remitos-venta (D9): remito de origen de la venta\n", mode="after")
    s = patch(s, """      RAISE EXCEPTION 'client_not_found: %', p_client_id USING ERRCODE = 'P0404';
    END IF;
  END IF;
""", """
  -- remitos-venta (D9): una venta nacida de un remito NO se edita. El editor
  -- siempre reemplaza líneas (REVERSE + APPLY) y la REVERSE, sin movimiento
  -- propio de esas filas sales, cae a la normalización de la línea y
  -- REPONDRÍA stock que el remito sigue reteniendo (la APPLY lo descontaría
  -- de nuevo; una reducción dejaría reposición de más que la anulación del
  -- remito duplicaría). Va ANTES del bloque fiscal para no anular un
  -- comprobante pendiente por una edición que igual se rechaza, y bloquea la
  -- operación entera (también la cabecera).
  SELECT COALESCE('R-' || lpad(dn.number::text, 8, '0'), 'de origen') INTO v_dn_label
  FROM   public.sales s
  JOIN   public.sales_orders so ON so.sale_operation_id = s.operation_id
  JOIN   public.delivery_notes dn ON dn.id = so.source_delivery_note_id
  WHERE  s.id = ANY(p_sale_ids)
  LIMIT  1;

  IF FOUND THEN
    RAISE EXCEPTION 'delivery_note_sale_locked: la venta nació del remito %: para corregirla, eliminá la venta, editá el remito y volvé a convertirlo', v_dn_label
      USING ERRCODE = 'P0423';
  END IF;
""", mode="after")
    return s


# ─── _delivery_note_payload (tanda A) ───────────────────────────────────────
def payload() -> str:
    a = read(WT / "supabase/migrations/20261069000001_remitos_venta.sql")
    start = a.index("CREATE OR REPLACE FUNCTION public._delivery_note_payload(p_dn_id uuid)")
    end = a.index("$function$;", start) + len("$function$;")
    s = a[start:end]
    s = patch(s, """              'converted_sales_order_id', NULL,
              'converted_operation_id',   NULL,
""", """              -- remitos-venta tanda B: la orden VIVA nacida del remito (a lo
              -- sumo una, índice único parcial); NULL si no está convertido.
              'converted_sales_order_id', (SELECT so.id FROM public.sales_orders so
                                           WHERE so.source_delivery_note_id = dn.id
                                             AND so.account_id = dn.account_id
                                             AND so.status <> 'canceled'),
              'converted_operation_id',   (SELECT so.sale_operation_id FROM public.sales_orders so
                                           WHERE so.source_delivery_note_id = dn.id
                                             AND so.account_id = dn.account_id
                                             AND so.status <> 'canceled'),
""", mode="replace")
    return s


def section(title: str) -> str:
    bar = "-- " + "=" * 77
    return f"\n\n{bar}\n-- {title}\n{bar}\n"


def build(stage: str) -> str:
    parts = [read(FRAG / "00_header.sql"), read(FRAG / "10_model.sql")]
    if stage in ("64", "65", "full"):
        c = core()
        (EVID / "new_bodies").mkdir(parents=True, exist_ok=True)
        (EVID / "new_bodies/_c29_confirm_order_core.sql").write_text(c + "\n", encoding="utf-8", newline="\n")
        parts.append(section("2. _c29_confirm_order_core desde el cuerpo vivo: SÓLO la rama v_from_delivery_note (D7)"))
        parts.append(c + ";\n")
        parts.append("\nCOMMENT ON FUNCTION public._c29_confirm_order_core(text, uuid, text, uuid, text, uuid, text, uuid, uuid) IS\n  "
                     + sql_literal(live_comment("_c29_confirm_order_core")) + ";\n")
    if stage in ("65", "full"):
        parts.append(section("3. rpc_convert_delivery_note_to_sale (D7)"))
        parts.append(read(FRAG / "30_convert.sql"))
    if stage == "full":
        d = delete()
        (EVID / "new_bodies/rpc_delete_sale_operation.sql").write_text(d + "\n", encoding="utf-8", newline="\n")
        parts.append(section("4. rpc_delete_sale_operation desde el cuerpo vivo (D9)"))
        parts.append(d + ";\n")
        parts.append("\nCOMMENT ON FUNCTION public.rpc_delete_sale_operation(uuid, uuid, text) IS\n  "
                     + sql_literal(live_comment("rpc_delete_sale_operation")) + ";\n")
        u = atomic()
        (EVID / "new_bodies/rpc_atomic_update_sale_operation.sql").write_text(u + "\n", encoding="utf-8", newline="\n")
        parts.append(section("5. rpc_atomic_update_sale_operation desde el cuerpo vivo (D9)"))
        parts.append(u + ";\n")
        parts.append("\nCOMMENT ON FUNCTION public.rpc_atomic_update_sale_operation(uuid[], uuid, date, text, jsonb, uuid, boolean, uuid, boolean, text, boolean) IS\n  "
                     + sql_literal(live_comment("rpc_atomic_update_sale_operation")) + ";\n")
        p = payload()
        parts.append(section("6. _delivery_note_payload: la venta generada pasa a derivarse (tanda A -> B)"))
        parts.append(p + "\n")
        parts.append("""
REVOKE ALL ON FUNCTION public._delivery_note_payload(uuid) FROM PUBLIC, anon, authenticated;
COMMENT ON FUNCTION public._delivery_note_payload(uuid) IS
  'remitos-venta: fila de delivery_notes + document_type, nombres de cliente y sucursal, líneas en orden de '
  'carga (con símbolo de unidad y si el producto fue dado de baja) e historial de estados. '
  'converted_sales_order_id/converted_operation_id: la orden VIVA (no cancelada) nacida del remito (tanda B), '
  'NULL si no está convertido. Interna.';
""")
        parts.append(section("7. Introspección final"))
        parts.append(read(FRAG / "90_introspection.sql"))
    return "".join(parts)


if __name__ == "__main__":
    stage = sys.argv[1]
    out = build(stage)
    target = MIG if stage == "full" else B / f"stage{stage}.sql"
    target.write_text(out, encoding="utf-8", newline="\n")
    print(f"escrito {target} ({out.count(chr(10))} líneas)")
