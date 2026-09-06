"use client";
import { useEffect, useRef } from "react";
import { createShader, playSweep, accentChain, ACCENTS } from "glimm";
const RAINBOW = accentChain([ACCENTS.red, ACCENTS.orange, ACCENTS.yellow, ACCENTS.green, ACCENTS.cyan, ACCENTS.blue, ACCENTS.purple]);

/** Allocate a GPU context only while the optional model celebration is visible. */
export function useComposerSweep() {
  const glimmRef = useRef<HTMLCanvasElement>(null);
  const shaderRef = useRef<ReturnType<typeof createShader> | null>(null);
  useEffect(() => () => { shaderRef.current?.destroy(); shaderRef.current = null; }, []);
  const celebrate = () => {
    if (shaderRef.current || !glimmRef.current || window.matchMedia("(prefers-reduced-motion: reduce)").matches) return;
    const shader = createShader({ canvas: glimmRef.current, palette: RAINBOW, direction: "ltr", bandTight: 10, swellAmount: 0.85 });
    if (!shader) return;
    shaderRef.current = shader;
    const sweep = playSweep(shader, { palette: RAINBOW, direction: "ltr", sweepMs: 570, outroMs: 80,
      peakAlpha: 1.3, bandTight: 10, brightness: 1.4, swellAmount: 1, waveSpeed: 1.8, easing: "easeOutExpo" });
    const finish = () => { if (shaderRef.current === shader) { shader.destroy(); shaderRef.current = null; } };
    void sweep.done.then(finish, finish);
  };
  return { glimmRef, celebrate };
}
