import { Button } from "@/components/ui/button"
import { LandingSection } from "@/lib/landing"
import Link from "next/link"

export function HeroSection({ section }: { section: LandingSection }) {
    return (
        <section className="relative overflow-hidden bg-slate-950 py-24 sm:py-32">
            {/* Background elements */}
            <div className="absolute top-0 left-0 w-full h-full overflow-hidden pointer-events-none opacity-20">
                <div className="absolute -top-[10%] -left-[10%] w-[40%] h-[40%] bg-emerald-500 rounded-full blur-[120px]" />
                <div className="absolute top-[40%] -right-[10%] w-[30%] h-[30%] bg-blue-500 rounded-full blur-[100px]" />
            </div>

            <div className="container relative z-10 mx-auto px-4 text-center">
                <div className="flex items-center justify-center gap-4 mb-8">
                    <img src="/aliada-logo.png" alt="ALIADA Logo" className="h-20 w-20 object-contain" />
                    <span className="text-3xl font-bold text-white tracking-widest uppercase">ALIADA</span>
                </div>
                <h1 className="mb-6 text-4xl font-bold tracking-tight text-white sm:text-6xl lg:text-7xl">
                    {section.title}
                </h1>
                <p className="mb-8 text-lg leading-8 text-slate-300 sm:text-xl max-w-2xl mx-auto">
                    {section.subtitle}
                </p>
                {section.content && (
                    <p className="mb-10 text-base text-slate-400">
                        {section.content}
                    </p>
                )}
                <div className="flex flex-col sm:flex-row items-center justify-center gap-4">
                    <Button size="lg" className="rounded-full px-8 bg-emerald-600 hover:bg-emerald-500 text-white font-semibold" asChild>
                        <Link href={section.button_link || "/auth/login"}>
                            {section.button_text || "Comenzar Gratis"}
                        </Link>
                    </Button>
                    <Button variant="outline" size="lg" className="rounded-full px-8 border-slate-700 text-slate-200 hover:bg-slate-800" asChild>
                        <Link href="#features">
                            Ver Funcionalidades
                        </Link>
                    </Button>
                </div>
            </div>

            {section.image_url && (
                <div className="mt-16 flow-root sm:mt-24">
                    <div className="-m-2 rounded-xl bg-slate-900/50 p-2 ring-1 ring-inset ring-white/10 lg:-m-4 lg:rounded-2xl lg:p-4 backdrop-blur-sm">
                        <img
                            src={section.image_url}
                            alt="App screenshot"
                            className="rounded-md shadow-2xl ring-1 ring-white/10"
                        />
                    </div>
                </div>
            )}
        </section>
    )
}
