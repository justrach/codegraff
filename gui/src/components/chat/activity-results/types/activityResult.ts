import type { ReactNode } from "react";

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
    }
  | (ActivityResultBase & {
      kind: "text";
      footer: ActivityResultFooter;
      text: string;
      title: "Output";
    });
