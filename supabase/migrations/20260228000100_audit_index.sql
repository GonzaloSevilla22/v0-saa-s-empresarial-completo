-- 1. Analytics Optimization: Add GIN index on analytics_events.event_data
CREATE INDEX IF NOT EXISTS idx_analytics_events_event_data_gin 
ON public.analytics_events USING GIN (event_data);
