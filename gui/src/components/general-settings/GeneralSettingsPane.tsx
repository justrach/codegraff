import { CheckIcon, MoonIcon, SunIcon } from "lucide-react";

import { useThemeStore } from "@/app/themeStore";
import type { ThemeMode } from "@/app/themeStore";
import { Button } from "@/components/ui/Button";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/Card";
import { PaneSurface } from "@/components/ui/PaneSurface";
import { cn } from "@/utils/cn";

import { THEME_PRESETS } from "./constants/themePresets";
import { UpdatesCard } from "./UpdatesCard";

const MODE_OPTIONS: { value: ThemeMode; label: string; icon: typeof SunIcon }[] =
  [
    { value: "light", label: "Light", icon: SunIcon },
    { value: "dark", label: "Dark", icon: MoonIcon },
  ];

export function GeneralSettingsPane() {
  const mode = useThemeStore((state) => state.mode);
  const preset = useThemeStore((state) => state.preset);
  const setMode = useThemeStore((state) => state.setMode);
  const setPreset = useThemeStore((state) => state.setPreset);

  return (
    <PaneSurface className="flex-1" aria-label="General settings">
      <div className="mx-auto flex h-full min-h-0 w-full max-w-4xl flex-col gap-4 overflow-y-auto px-6 pt-6 pb-12">
        <div className="flex flex-col gap-1">
          <h1 className="text-lg font-medium text-foreground">General</h1>
          <p className="max-w-xl text-sm text-muted-foreground">
            Personalise how codegraff looks. Your choices are saved on this
            device.
          </p>
        </div>

        <Card>
          <CardHeader>
            <CardTitle>Appearance</CardTitle>
          </CardHeader>
          <CardContent className="flex flex-col gap-2">
            <span className="text-xs font-medium text-muted-foreground">
              Mode
            </span>
            <div className="inline-flex w-fit gap-1 rounded-lg border border-border bg-secondary/40 p-1">
              {MODE_OPTIONS.map(({ value, label, icon: Icon }) => (
                <Button
                  key={value}
                  type="button"
                  size="sm"
                  variant={mode === value ? "default" : "ghost"}
                  aria-pressed={mode === value}
                  onClick={() => setMode(value)}
                >
                  <Icon data-icon="inline-start" strokeWidth={2} />
                  {label}
                </Button>
              ))}
            </div>
          </CardContent>
        </Card>

        <Card>
          <CardHeader>
            <CardTitle>Theme</CardTitle>
          </CardHeader>
          <CardContent>
            <div className="grid grid-cols-1 gap-3 sm:grid-cols-2">
              {THEME_PRESETS.map((option) => (
                <ThemePresetCard
                  key={option.id}
                  isSelected={preset === option.id}
                  name={option.name}
                  description={option.description}
                  swatch={option.swatch}
                  onSelect={() => setPreset(option.id)}
                />
              ))}
            </div>
          </CardContent>
        </Card>

        <UpdatesCard />
      </div>
    </PaneSurface>
  );
}

function ThemePresetCard({
  isSelected,
  name,
  description,
  swatch,
  onSelect,
}: {
  isSelected: boolean;
  name: string;
  description: string;
  swatch: { bg: string; surface: string; accent: string; text: string };
  onSelect: () => void;
}) {
  return (
    <button
      type="button"
      aria-pressed={isSelected}
      onClick={onSelect}
      className={cn(
        "group relative flex items-center gap-3 rounded-xl border p-3 text-left transition-colors",
        isSelected
          ? "border-accent ring-2 ring-accent/30"
          : "border-border hover:border-accent/40 hover:bg-secondary",
      )}
    >
      <span
        aria-hidden
        className="flex size-11 shrink-0 flex-col justify-center gap-1 overflow-hidden rounded-lg border border-black/10 px-1.5"
        style={{ backgroundColor: swatch.bg }}
      >
        <span
          className="h-1.5 w-7 rounded-full"
          style={{ backgroundColor: swatch.text }}
        />
        <span className="flex items-center gap-1">
          <span
            className="h-3 w-3 rounded-full"
            style={{ backgroundColor: swatch.accent }}
          />
          <span
            className="h-3 flex-1 rounded-sm"
            style={{ backgroundColor: swatch.surface }}
          />
        </span>
      </span>
      <span className="flex min-w-0 flex-col gap-0.5">
        <span className="text-sm font-medium text-foreground">{name}</span>
        <span className="text-xs leading-snug text-muted-foreground">
          {description}
        </span>
      </span>
      {isSelected ? (
        <CheckIcon
          aria-hidden
          strokeWidth={2.5}
          className="absolute top-2.5 right-2.5 size-4 text-accent"
        />
      ) : null}
    </button>
  );
}
