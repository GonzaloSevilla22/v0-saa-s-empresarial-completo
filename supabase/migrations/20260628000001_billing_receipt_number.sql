-- Recibo de pago: numeración estable y contigua para los pagos aprobados.
--
-- No toca la lógica del webhook de pagos (governance CRÍTICO): el número se
-- asigna por TRIGGER en el INSERT existente de billing_events, solo para
-- event_type='plan_upgraded' (los pagos reales). Así los recibos quedan
-- contiguos (RC-AAAA-000001, 000002, ...) sin gaps por otros eventos.

-- Secuencia global (el año es solo prefijo legible, no resetea el contador).
CREATE SEQUENCE IF NOT EXISTS billing_receipt_seq START 1;

ALTER TABLE billing_events ADD COLUMN IF NOT EXISTS receipt_number text;

-- Trigger: asigna número solo a pagos aprobados que aún no tengan uno.
CREATE OR REPLACE FUNCTION assign_billing_receipt_number()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NEW.event_type = 'plan_upgraded' AND NEW.receipt_number IS NULL THEN
    NEW.receipt_number :=
      'RC-' || to_char(now() AT TIME ZONE 'UTC', 'YYYY') || '-' ||
      lpad(nextval('billing_receipt_seq')::text, 6, '0');
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_assign_billing_receipt_number ON billing_events;
CREATE TRIGGER trg_assign_billing_receipt_number
  BEFORE INSERT ON billing_events
  FOR EACH ROW
  EXECUTE FUNCTION assign_billing_receipt_number();

-- Backfill: numerar los pagos ya existentes por orden cronológico.
WITH ordered AS (
  SELECT id, row_number() OVER (ORDER BY created_at, id) AS rn
  FROM billing_events
  WHERE event_type = 'plan_upgraded' AND receipt_number IS NULL
)
UPDATE billing_events be
SET receipt_number =
  'RC-' || to_char(be.created_at AT TIME ZONE 'UTC', 'YYYY') || '-' ||
  lpad(o.rn::text, 6, '0')
FROM ordered o
WHERE be.id = o.id;

-- Avanzar la secuencia por encima de lo ya numerado para no repetir.
SELECT setval(
  'billing_receipt_seq',
  GREATEST((SELECT count(*) FROM billing_events WHERE receipt_number IS NOT NULL), 1)
);

-- Unicidad (no dos recibos con el mismo número).
CREATE UNIQUE INDEX IF NOT EXISTS billing_events_receipt_number_key
  ON billing_events (receipt_number)
  WHERE receipt_number IS NOT NULL;
