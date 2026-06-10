-- C-22 v20-fiscal-identity-clients
-- Identidad fiscal opcional del cliente (FiscalIdentity VO compartido — DEC-18, modelo V2 §5.5)
-- Columnas nullable sin DEFAULT: sin rewrite de tabla. Sin backfill (NULL = consumidor final sin identificar).

ALTER TABLE public.clients
  ADD COLUMN IF NOT EXISTS tax_id TEXT,
  ADD COLUMN IF NOT EXISTS legal_name TEXT,
  ADD COLUMN IF NOT EXISTS iva_condition TEXT;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'clients_iva_condition_check'
      AND conrelid = 'public.clients'::regclass
  ) THEN
    ALTER TABLE public.clients
      ADD CONSTRAINT clients_iva_condition_check
      CHECK (iva_condition IN ('responsable_inscripto', 'monotributista', 'exento', 'consumidor_final'));
  END IF;
END $$;

COMMENT ON COLUMN public.clients.tax_id IS 'CUIT (NN-NNNNNNNN-N) o DNI del cliente — opcional, validado en frontend';
COMMENT ON COLUMN public.clients.iva_condition IS 'Condición frente al IVA — dominio cerrado por CHECK, opcional';
COMMENT ON COLUMN public.clients.legal_name IS 'Razón social — opcional';
