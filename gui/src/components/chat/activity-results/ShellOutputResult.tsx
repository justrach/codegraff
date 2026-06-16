import { ActivityResultCard, ActivityResultPreformattedBody } from "./ActivityResultCard";
import type { ShellOutputResultProps } from "../types/chatComponents";

export function ShellOutputResult({ result }: ShellOutputResultProps) {
  return (
    <ActivityResultCard
      title={result.title}
      copyText={result.copyText}
      footer={result.footer}
    >
      <ActivityResultPreformattedBody text={result.text} />
    </ActivityResultCard>
  );
}
