export default function Home() {
  const root = process.env.NEXT_PUBLIC_ROOT_DOMAIN ?? 'localhost:3000'
  return (
    <main className="mx-auto flex min-h-dvh max-w-3xl flex-col justify-center px-6">
      <section className="glass p-10">
        <h1 className="font-display text-4xl font-semibold tracking-tight sm:text-5xl">
          Abrí tu tienda online en minutos
        </h1>
        <p className="mt-4 max-w-prose text-neutral-400">
          Catálogo para ropa, zapatillas y accesorios. Tus clientes arman el carrito y te mandan el
          pedido por WhatsApp, sin pasarelas de pago.
        </p>
        <a href={`//app.${root}/login`} className="btn-neon mt-8">
          Crear mi tienda
        </a>
      </section>
    </main>
  )
}
