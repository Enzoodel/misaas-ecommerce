// Fase 3: aquí se resuelve el tenant (slug o dominio propio) y se renderiza el storefront.
export default function TenantHome({ params }: { params: { domain: string } }) {
  const domain = decodeURIComponent(params.domain)
  return (
    <main className="mx-auto flex min-h-dvh max-w-3xl flex-col justify-center px-6">
      <section className="glass p-10">
        <p className="text-sm text-neutral-400">Tienda</p>
        <h1 className="font-display text-3xl font-semibold">{domain}</h1>
      </section>
    </main>
  )
}
