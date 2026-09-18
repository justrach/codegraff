import motion from "./transcript-motion.module.css";

/** Engine-generated context has its own identity, even when its wire role is user. */
export default function SessionNotice({ text }: { text: string }) {
  return <details data-session-notice className="min-w-0 rounded-control border border-line px-3 py-2 text-[12.5px] leading-relaxed text-ink-2">
    <summary className="cursor-pointer select-none">Session notification</summary>
    <p className={`${motion.reveal} mt-2 whitespace-pre-wrap [overflow-wrap:anywhere]`}>{text}</p>
  </details>;
}
