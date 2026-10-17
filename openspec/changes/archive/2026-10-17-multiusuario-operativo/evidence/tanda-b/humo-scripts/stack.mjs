// Levanta (o baja) el stack local de humo: build de producción de Next + next start + uvicorn.
// Uso: node stack.mjs build | up | down
import { spawn, execFileSync } from "node:child_process"
import { openSync, writeFileSync, readFileSync, existsSync } from "node:fs"
import { WT, HUMO, loadSecrets } from "./common.mjs"

const s = loadSecrets()
const PY = "C:/Users/Usuario/Desktop/EIE/v0-saa-s-empresarial-completo/backend/.venv/Scripts/python.exe"
const cmd = process.argv[2]

const frontEnv = {
  ...process.env,
  NEXT_PUBLIC_SUPABASE_URL: s.api,
  NEXT_PUBLIC_SUPABASE_ANON_KEY: s.anon,
  NEXT_PUBLIC_BACKEND_URL: "http://127.0.0.1:8000",
  NEXT_PUBLIC_TURNSTILE_SITE_KEY: "1x00000000000000000000AA", // clave de PRUEBA de Cloudflare: siempre pasa
  NEXT_PUBLIC_SITE_URL: "http://localhost:3000",
  NEXT_PUBLIC_APP_URL: "http://localhost:3000",
  SUPABASE_SERVICE_ROLE_KEY: "",
}

const backEnv = {
  ...process.env,
  DATABASE_URL: "postgresql://postgres:postgres@127.0.0.1:54322/postgres",
  SUPABASE_URL: s.api, // JWKS: el GoTrue local firma ES256
  APP_ENV: "development",
  AUTH_ALLOW_HS256_FALLBACK: "true", // el SUPABASE_URL local es http: el validator exige la palanca de desarrollo; con la URL puesta la rama es JWKS igual
  BACKEND_ALLOWED_ORIGIN: "http://localhost:3000",
  // Mismas palancas que producción: el pool adopta el rol authenticated por transacción.
  TENANCY_TX_SCOPE_ENABLED: "true",
  TENANCY_RLS_ROLE_ENABLED: "true",
}

function pidFile(name) {
  return `${HUMO}/${name}.pid`
}

if (cmd === "build") {
  console.log("next build (producción)…")
  execFileSync("pnpm", ["build"], { cwd: `${WT}/frontend`, env: frontEnv, stdio: "inherit", shell: true })
}

if (cmd === "up") {
  const out1 = openSync(`${HUMO}/next.log`, "a")
  const next = spawn("pnpm", ["exec", "next", "start", "-p", "3000"], { cwd: `${WT}/frontend`, env: frontEnv, detached: true, stdio: ["ignore", out1, out1], shell: true })
  writeFileSync(pidFile("next"), String(next.pid))
  next.unref()
  const out2 = openSync(`${HUMO}/backend.log`, "a")
  const back = spawn(PY, ["-m", "uvicorn", "backend.main:app", "--port", "8000"], { cwd: WT, env: backEnv, detached: true, stdio: ["ignore", out2, out2] })
  writeFileSync(pidFile("backend"), String(back.pid))
  back.unref()
  console.log("next pid", next.pid, "backend pid", back.pid)
}

if (cmd === "down") {
  for (const n of ["next", "backend"]) {
    const f = pidFile(n)
    if (!existsSync(f)) continue
    const pid = readFileSync(f, "utf8").trim()
    try {
      execFileSync("taskkill", ["/PID", pid, "/T", "/F"], { stdio: "ignore" })
    } catch {}
  }
  console.log("bajado")
}
