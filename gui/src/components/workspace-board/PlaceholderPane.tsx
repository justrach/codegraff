import type {
  IDockviewPanelProps,
} from "dockview-react";

import { PaneSurface } from "@/components/ui/PaneSurface";

import type { PlaceholderPaneParams } from "./types/layout";

export function PlaceholderPane({
  params,
}: IDockviewPanelProps<PlaceholderPaneParams>) {
  return (
    <PaneSurface className="items-center justify-center p-6 text-center">
      <div className="space-y-2">
        <p className="text-xs font-semibold uppercase tracking-widest text-muted-foreground">
          {params.kind}
        </p>
        <p className="text-sm font-medium text-foreground">
          {params.label}
        </p>
      </div>
    </PaneSurface>
  );
}
