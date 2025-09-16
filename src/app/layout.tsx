import type { Metadata } from "next";
import { Geist, Geist_Mono } from "next/font/google";
import { AgreementGuard } from "@/components/agreement/AgreementGuard";
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
  title: "EarnLayer - Publisher Platform",
  description: "Monetize your content with EarnLayer's AI-powered advertising platform",
};

export default function RootLayout({
  children,
}: Readonly<{
  children: React.ReactNode;
}>) {
  return (
    <html lang="en">
      <head>
        <meta name="google-site-verification" content="ku5igFBJfbJW_5BxDG24fq-Lo73Mi_bnWwl5FQPoCCc" />
      </head>
      <body
        className={`${geistSans.variable} ${geistMono.variable} antialiased`}
      >
        <AgreementGuard>
          {children}
        </AgreementGuard>
      </body>
    </html>
  );
}
