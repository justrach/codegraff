"use client";

import { ButtonHTMLAttributes } from "react";

export type ButtonVariant = "primary" | "secondary" | "ghost" | "accent" | "success";
type Size = "sm" | "md";

const filledShadow = "shadow-[inset_0_1px_0_rgba(255,255,255,0.14)]";

const variants: Record<ButtonVariant, string> = {
  primary:
    `bg-ink text-canvas hover:opacity-90 dark:bg-ink dark:text-canvas ${filledShadow}`,
  secondary:
    "bg-surface text-ink shadow-btn hover:bg-inset aria-expanded:bg-hover",
  ghost: "bg-hover-2 text-ink hover:bg-line-strong",
  accent: `bg-accent text-white hover:bg-accent-ink ${filledShadow}`,
  success: `bg-green text-white hover:brightness-95 ${filledShadow}`,
};

/* Pill-shaped by default — the app's core button style. Explicit symmetric
 * padding (not a fixed height) so the top/bottom spacing is always equal. */
const sizes: Record<Size, string> = {
  sm: "px-3 py-[7px] text-[13px] leading-none rounded-full gap-1.5",
  md: "px-4 py-[9px] text-sm leading-none rounded-full gap-2",
};

export function Button({
  variant = "secondary",
  size = "md",
  className = "",
  ...props
}: ButtonHTMLAttributes<HTMLButtonElement> & {
  variant?: ButtonVariant;
  size?: Size;
}) {
  return (
    <button
      className={`inline-flex items-center justify-center font-medium select-none
        transition-[transform,background-color,opacity] duration-150 ease-out
        active:scale-[0.96] disabled:opacity-50 disabled:pointer-events-none
        ${variants[variant]} ${sizes[size]} ${className}`}
      {...props}
    />
  );
}
