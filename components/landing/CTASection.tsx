import { Button } from "@/components/ui/button"
import { LandingSection } from "@/lib/landing"
import Link from "next/link"

export function CTASection({ section }: { section: LandingSection }) {
    return (
        <section className="bg-slate-900 py-16 sm:py-24">
            <div className="container mx-auto px-4">
                <div className="relative isolate overflow-hidden bg-emerald-700 px-6 py-24 shadow-2xl rounded-3xl sm:px-24 xl:py-32">
                    <h2 className="mx-auto max-w-2xl text-center text-3xl font-bold tracking-tight text-white sm:text-4xl">
                        {section.title}
                    </h2>
                    <p className="mx-auto mt-6 max-w-xl text-center text-lg leading-8 text-emerald-100">
                        {section.subtitle || "Unite a los cientos de emprendedores que ya confían en ALIADA."}
                    </p>
                    {section.content && (
                        <p className="mx-auto mt-4 max-w-lg text-center text-sm text-emerald-200/80">
                            {section.content}
                        </p>
                    )}
                    <div className="mt-10 flex justify-center gap-x-6">
                        <Button size="lg" className="bg-white text-emerald-700 hover:bg-emerald-50 rounded-full px-10 font-bold" asChild>
                            <Link href={section.button_link || "/auth/register"}>
                                {section.button_text || "Empezar Ahora"}
                            </Link>
                        </Button>
                    </div>
                    {/* Decorative circles */}
                    <svg
                        viewBox="0 0 1024 1024"
                        className="absolute left-1/2 top-1/2 -z-10 h-[64rem] w-[64rem] -translate-x-1/2 [mask-image:radial-gradient(closest-side,white,transparent)]"
                        aria-hidden="true"
                    >
                        <circle cx="512" cy="512" r="512" fill="url(#8d958450-c69f-4db8-9793-702298a7ff69)" fillOpacity="0.7" />
                        <defs>
                            <radialGradient id="8d958450-c69f-4db8-9793-702298a7ff69">
                                <stop stopColor="#10b981" />
                                <stop offset="1" stopColor="#047857" />
                            </radialGradient>
                        </defs>
                    </svg>
                </div>
            </div>
        </section>
    )
}
