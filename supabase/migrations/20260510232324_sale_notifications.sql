-- =============================================================================
-- Migration: sale_notifications
-- Audit log for outbound sale notifications (WhatsApp, email, print, etc.)
--
-- Etapa 1: tracks deep-link WhatsApp opens (channel = 'whatsapp_link')
-- Etapa 2: will store provider message IDs from WhatsApp Business API
--          (channel = 'whatsapp_api'), Twilio, WATI, etc.
-- =============================================================================

CREATE TABLE IF NOT EXISTS sale_notifications (
  id                  uuid DEFAULT gen_random_uuid() PRIMARY KEY,
  user_id             uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,

  -- What was sent
  operation_id        text NOT NULL,          -- SaleOperation.operationId or .key
  client_id           uuid REFERENCES clients(id) ON DELETE SET NULL,

  -- How it was sent
  channel             text NOT NULL DEFAULT 'whatsapp_link'
                        CHECK (channel IN (
                          'whatsapp_link',    -- wa.me deep link (Etapa 1)
                          'whatsapp_api',     -- WhatsApp Business API (Etapa 2)
                          'email',            -- Email via Resend
                          'print'             -- Physical print / PDF
                        )),
  phone_used          text,                   -- Normalised number actually used
  provider_message_id text,                   -- Twilio/WATI msg ID (Etapa 2)

  -- Outcome
  status              text NOT NULL DEFAULT 'sent'
                        CHECK (status IN ('sent', 'failed', 'pending', 'delivered', 'read')),
  error_message       text,

  sent_at             timestamptz DEFAULT now(),
  created_at          timestamptz DEFAULT now()
);

-- Fast lookups by user + operation (for "already sent?" checks)
CREATE INDEX IF NOT EXISTS idx_sale_notifications_operation
  ON sale_notifications (user_id, operation_id, sent_at DESC);

-- Fast lookups by client (for CRM view: "all messages sent to client X")
CREATE INDEX IF NOT EXISTS idx_sale_notifications_client
  ON sale_notifications (user_id, client_id, sent_at DESC);

-- RLS: users only see and write their own notification logs
ALTER TABLE sale_notifications ENABLE ROW LEVEL SECURITY;

CREATE POLICY sale_notifications_all ON sale_notifications
  FOR ALL
  USING  (auth.uid() = user_id)
  WITH CHECK (auth.uid() = user_id);
