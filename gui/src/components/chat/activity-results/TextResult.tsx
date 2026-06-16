import { ActivityResultCard, ActivityResultPreformattedBody } from "./ActivityResultCard";
import type { TextResultProps } from "../types/chatComponents";

export function TextResult({ result }: TextResultProps) {
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
