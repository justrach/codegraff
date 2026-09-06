import type { Metadata } from "next";
import { Inter, JetBrains_Mono } from "next/font/google";
import "./globals.css";
import { ThemeSync } from "@/components/site/ThemeSync";
import DesktopTitlebar from "@/components/site/DesktopTitlebar";
import { BrowserWarm } from "@/components/site/BrowserWarm";

const inter = Inter({
  subsets: ["latin"],
  variable: "--font-inter",
});

const mono = JetBrains_Mono({
  subsets: ["latin"],
  variable: "--font-mono-face",
});

export const metadata: Metadata = {
  title: "Codegraff",
  description: "Native graff harness — Beautiful UI primitives in a merjs desktop shell.",
};

const themeScript = `(function(){try{var t=localStorage.getItem("bui-theme");document.documentElement.classList.toggle("dark",t!=="light")}catch(e){document.documentElement.classList.add("dark")}})()`;

export default function RootLayout({
  children,
}: Readonly<{ children: React.ReactNode }>) {
  return (
    <html lang="en" suppressHydrationWarning>
      <head>
        <script dangerouslySetInnerHTML={{ __html: themeScript }} />
      </head>
      <body className={`${inter.variable} ${mono.variable} font-sans`}>
        <ThemeSync />
        <BrowserWarm />
        <DesktopTitlebar />
        {children}
      </body>
    </html>
  );
}
