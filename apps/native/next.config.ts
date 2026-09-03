import type { NextConfig } from "next";

const nextConfig: NextConfig = {
  images: { unoptimized: true },
  // `npm run dev` is how the native app runs; Next's dev button defaults to
  // the bottom-left corner, on top of the sidebar's session control.
  devIndicators: { position: "bottom-right" },
  experimental: {
    optimizePackageImports: ["iconoir-react"],
  },
};

export default nextConfig;
