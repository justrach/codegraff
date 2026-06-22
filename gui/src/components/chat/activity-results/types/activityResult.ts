import type { ReactNode } from "react";

import type { FileOperation } from "@/services/desktop/types/contracts";

export interface ActivityResultFooter {
  leading: ReactNode;
  trailing: ReactNode;
}

/** How the body text should be rendered. Diffs are a separate result kind. */
export type ActivityResultFormat = "terminal" | "code" | "prose";

/** Visual category of the result. */
export type ActivityResultTone = "default" | "error";

/** Whether the result gets full card chrome or renders inline under the row. */
export type ActivityResultPresentation = "inline" | "card";

export type ActivityResultModel =
  | {
      kind: "file_diff";
      copyText: string;
      path: string;
      patch: string;
      operation?: FileOperation;
    }
  | {
      kind: "content";
      format: ActivityResultFormat;
      tone: ActivityResultTone;
      presentation: ActivityResultPresentation;
      /** Display label for code outputs, e.g. "json". */
      language?: string;
      title: string;
      text: string;
      copyText: string;
      footer: ActivityResultFooter;
    };
