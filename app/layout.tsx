import type { Metadata } from 'next'
import { Manrope, Sora } from 'next/font/google'
import './globals.css'

const display = Sora({ subsets: ['latin'], variable: '--font-display' })
const sans = Manrope({ subsets: ['latin'], variable: '--font-sans' })

export const metadata: Metadata = {
  title: 'Abrí tu tienda online',
  description: 'Catálogo para ropa, zapatillas y accesorios con pedidos por WhatsApp.',
}

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="es" data-accent="purple" className={`${display.variable} ${sans.variable}`}>
      <body>{children}</body>
    </html>
  )
}
