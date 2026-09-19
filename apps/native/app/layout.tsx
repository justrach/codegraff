import type { Metadata } from "next";
import { GeistSans } from "geist/font/sans";
import { GeistMono } from "geist/font/mono";
import localFont from "next/font/local";
import "./globals.css";
import "./appearance.css";
import "./motion.css";
import { MotionLifecycle } from "@/components/site/MotionLifecycle";
import { appearanceScript } from "@/lib/appearance";
import { ThemeSync } from "@/components/site/ThemeSync";
import DesktopTitlebar from "@/components/site/DesktopTitlebar";
import DesktopUpdates from "@/components/site/DesktopUpdates";
import { BrowserWarm } from "@/components/site/BrowserWarm";

export const metadata: Metadata = {
  title: "Codegraff",
  description: "CodeGraff desktop workspace.",
};

const googleSansCode = localFont({
  src: [
    { path: "./fonts/GoogleSansCode-latin-normal.woff2", weight: "300 800", style: "normal" },
    { path: "./fonts/GoogleSansCode-latin-italic.woff2", weight: "300 800", style: "italic" },
  ],
  variable: "--font-google-sans-code",
  display: "swap",
  preload: true,
});


export default function RootLayout({
  children,
}: Readonly<{ children: React.ReactNode }>) {
  return (
    <html lang="en" suppressHydrationWarning>
      <head>
        <script dangerouslySetInnerHTML={{ __html: appearanceScript }} />
      </head>
      <body className={`${GeistSans.variable} ${GeistMono.variable} ${googleSansCode.variable} font-sans`}>
        <ThemeSync />
        <MotionLifecycle />
        <BrowserWarm />
        <DesktopTitlebar />
        <DesktopUpdates />
        {children}
      </body>
    </html>
  );
}
