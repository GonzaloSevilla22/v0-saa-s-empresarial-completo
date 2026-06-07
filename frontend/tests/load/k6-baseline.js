/**
 * k6 Baseline Load Test — EIE Backend API
 *
 * Tests: GET /sales and GET /products under load
 * Parameters: 50 VUs, 1 minute duration
 * Threshold: p(95) < 500ms
 *
 * Usage:
 *   1. Export your JWT token:
 *      export K6_JWT="<your-supabase-access-token>"
 *   2. Run (backend must be warm — ping /health first):
 *      k6 run --env BACKEND_URL=https://your-backend.onrender.com k6-baseline.js
 */

import http from "k6/http"
import { check, sleep } from "k6"
import { Rate } from "k6/metrics"

// ── Config ────────────────────────────────────────────────────────────────────

const BACKEND_URL = __ENV.BACKEND_URL || "http://localhost:8000"
const JWT_TOKEN   = __ENV.K6_JWT       || ""

// ── Thresholds ────────────────────────────────────────────────────────────────

export const options = {
  vus:      50,
  duration: "1m",
  thresholds: {
    // 95th percentile response time must be under 500ms
    "http_req_duration{p(95)}":               ["p(95)<500"],
    // Specific thresholds per endpoint
    "http_req_duration{endpoint:sales}":      ["p(95)<500"],
    "http_req_duration{endpoint:products}":   ["p(95)<500"],
    // At least 99% of requests must succeed
    "http_req_failed":                        ["rate<0.01"],
  },
}

// ── Custom metrics ─────────────────────────────────────────────────────────────

const errorRate = new Rate("error_rate")

// ── Main test function ────────────────────────────────────────────────────────

export default function () {
  const headers = {
    "Content-Type":  "application/json",
    "Authorization": `Bearer ${JWT_TOKEN}`,
  }

  // ── GET /sales ───────────────────────────────────────────────────────────
  const salesRes = http.get(`${BACKEND_URL}/sales`, {
    headers,
    tags: { endpoint: "sales" },
  })

  const salesOk = check(salesRes, {
    "GET /sales: status 200":          (r) => r.status === 200,
    "GET /sales: response is array":   (r) => {
      try { return Array.isArray(JSON.parse(r.body)) } catch { return false }
    },
    "GET /sales: response time < 500ms": (r) => r.timings.duration < 500,
  })
  errorRate.add(!salesOk)

  sleep(0.5)

  // ── GET /products ────────────────────────────────────────────────────────
  const productsRes = http.get(`${BACKEND_URL}/products`, {
    headers,
    tags: { endpoint: "products" },
  })

  const productsOk = check(productsRes, {
    "GET /products: status 200":          (r) => r.status === 200,
    "GET /products: response is array":   (r) => {
      try { return Array.isArray(JSON.parse(r.body)) } catch { return false }
    },
    "GET /products: response time < 500ms": (r) => r.timings.duration < 500,
  })
  errorRate.add(!productsOk)

  sleep(0.5)
}

// ── Setup — warm up backend ───────────────────────────────────────────────────

export function setup() {
  const healthRes = http.get(`${BACKEND_URL}/health`)
  check(healthRes, { "backend health OK": (r) => r.status === 200 })
  // Allow the backend to warm up before full load
  sleep(2)
  return { backendUrl: BACKEND_URL }
}
