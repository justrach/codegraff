import type { Metadata } from "next";
import { Geist, Geist_Mono } from "next/font/google";
import "./globals.css";
import "./appearance.css";
import { appearanceScript } from "@/lib/appearance";
import { ThemeSync } from "@/components/site/ThemeSync";
import DesktopTitlebar from "@/components/site/DesktopTitlebar";
import DesktopUpdates from "@/components/site/DesktopUpdates";
import { BrowserWarm } from "@/components/site/BrowserWarm";

const inter = Geist({
  subsets: ["latin"],
  variable: "--font-inter",
});

const mono = Geist_Mono({
  subsets: ["latin"],
  variable: "--font-mono-face",
});

export const metadata: Metadata = {
  title: "Codegraff",
  description: "CodeGraff desktop workspace.",
};


export default function RootLayout({
  children,
}: Readonly<{ children: React.ReactNode }>) {
  return (
    <html lang="en" suppressHydrationWarning>
      <head>
        <script dangerouslySetInnerHTML={{ __html: appearanceScript }} />
      </head>
      <body className={`${inter.variable} ${mono.variable} font-sans`}>
        <ThemeSync />
        <BrowserWarm />
        <DesktopTitlebar />
        <DesktopUpdates />
        {children}
      </body>
    </html>
  );
}
