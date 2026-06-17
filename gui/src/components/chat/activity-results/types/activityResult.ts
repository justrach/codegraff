import type { ReactNode } from "react";

import type { FileOperation } from "@/services/desktop/types/contracts";

export interface ActivityResultFooter {
  leading: ReactNode;
  trailing: ReactNode;
}

interface ActivityResultBase {
  copyText: string;
}

export type ActivityResultModel =
  | (ActivityResultBase & {
      kind: "shell";
      footer: ActivityResultFooter;
      text: string;
      title: "Shell";
    })
  | {
      kind: "file_diff";
      copyText: string;
      path: string;
      patch: string;
      operation?: FileOperation;
    }
  | (ActivityResultBase & {
      kind: "text";
      footer: ActivityResultFooter;
      text: string;
      title: "Output";
    });
