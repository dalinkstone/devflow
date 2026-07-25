import type { Metadata } from "next";
import { Geist, Geist_Mono } from "next/font/google";
import "./globals.css";

const geistSans = Geist({
  variable: "--font-geist-sans",
  subsets: ["latin"],
});

const geistMono = Geist_Mono({
  variable: "--font-geist-mono",
  subsets: ["latin"],
});

export const metadata: Metadata = {
  metadataBase: new URL("https://devflow.sh"),
  title: "devflow",
  description: "Cloud Claude Code and Codex sessions on Daytona.",
  openGraph: {
    title: "devflow",
    description: "Agents in the cloud.",
    url: "https://devflow.sh",
    siteName: "devflow",
    images: [
      {
        url: "/og.png",
        width: 1200,
        height: 630,
        alt: "devflow — Agents in the cloud.",
      },
    ],
    type: "website",
  },
  twitter: {
    card: "summary_large_image",
    title: "devflow",
    description: "Agents in the cloud.",
    images: ["/og.png"],
  },
  icons: {
    icon: "/favicon.svg",
    shortcut: "/favicon.svg",
  },
};

export default function RootLayout({
  children,
}: Readonly<{
  children: React.ReactNode;
}>) {
  return (
    <html lang="en">
      <body className={`${geistSans.variable} ${geistMono.variable}`}>
        {children}
      </body>
    </html>
  );
}
