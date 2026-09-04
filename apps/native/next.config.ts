import type { NextConfig } from "next";

const nextConfig: NextConfig = {
  images: { unoptimized: true },
  // The desktop app ships this interface inside its bundle, so the build has
  // to produce a server that runs without the repository or a node_modules
  // tree beside it.
  output: "standalone",
  // Without this the tracer walks up to the repository root and copies the
  // Zig build outputs into the payload.
  outputFileTracingRoot: __dirname,
  // The app is opened at 127.0.0.1 (the desktop shell points there), which
  // Next 16 treats as cross-origin for its dev resources unless it is
  // listed here; without it hot reloading is refused.
  allowedDevOrigins: ["127.0.0.1", "localhost"],
  // Next 16 writes AGENTS.md and CLAUDE.md into the app on first run. This
  // repository has its own, and they are the contract for working in it.
  agentRules: false,
  // `npm run dev` is how the native app runs; Next's dev button defaults to
  // the bottom-left corner, on top of the sidebar's session control.
  devIndicators: { position: "bottom-right" },
  experimental: {
    optimizePackageImports: ["iconoir-react"],
  },
};

export default nextConfig;
