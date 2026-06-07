/** @type {import('next').NextConfig} */
const nextConfig = {
  async rewrites() {
    // In development: proxy /api/backend-docs → NEXT_PUBLIC_BACKEND_URL/docs
    // This lets devs open http://localhost:3000/api/backend-docs to see Swagger UI
    // without opening a separate tab for the backend URL directly.
    // Not needed in production — devs can open NEXT_PUBLIC_BACKEND_URL/docs directly.
    if (process.env.NODE_ENV !== "development") return []

    const backendUrl = process.env.NEXT_PUBLIC_BACKEND_URL
    if (!backendUrl) return []

    return [
      {
        source: "/api/backend-docs",
        destination: `${backendUrl}/docs`,
      },
      {
        source: "/api/backend-docs/:path*",
        destination: `${backendUrl}/docs/:path*`,
      },
    ]
  },
}

export default nextConfig
