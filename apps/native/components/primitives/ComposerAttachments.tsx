"use client";

import { useLayoutEffect, useId, useRef, useState } from "react";
import { createPortal } from "react-dom";
import type { Attachment } from "@/lib/attachments";
import { Icon, GLYPHS } from "./prompt-demo";

export type FailedAttach = { id: string; name: string; error: string };

export default function ComposerAttachments({ attachments, failed = [], pill, onRemove, onRetryFailed, onDismissFailed }: {
  attachments: readonly Attachment[]; failed?: readonly FailedAttach[]; pill: boolean;
  onRemove(id: string): void; onRetryFailed?(id: string): void; onDismissFailed?(id: string): void;
}) {
  const [previewId, setPreviewId] = useState<string | null>(null);
  const preview = attachments.find(file => file.id === previewId && file.preview);
  const chips = attachments.length > 0 || failed.length > 0;
  return <>
    {chips && <div className={`flex flex-wrap gap-1.5 pt-0.5 ${pill ? "px-1" : "px-0.5"}`}>
      {attachments.map(file => <span key={file.id}
        className={`flex h-6.5 items-center gap-1.5 bg-field py-1 pr-1 pl-1.5 text-[11.5px] text-ink-2 shadow-hairline ${pill ? "rounded-full" : "rounded-chip"}`}
        style={{ animation: "pop-in 200ms cubic-bezier(0.23,1,0.32,1) both" }}>
        {file.preview ? <button type="button" aria-label={`Preview ${file.name}`} aria-haspopup="dialog"
          className="flex min-w-0 items-center gap-1.5 rounded focus-visible:outline-2 focus-visible:outline-accent"
          onClick={() => setPreviewId(file.id)}>
          {/* eslint-disable-next-line @next/next/no-img-element */}
          <img src={file.preview} alt="" className="-my-1 size-6 rounded-[4px] object-cover" />
          <span className="max-w-36 truncate">{file.name}</span>
        </button> : <><Icon size={12}>{GLYPHS.file}</Icon><span className="max-w-36 truncate">{file.name}</span></>}
        <button type="button" aria-label={`Remove ${file.name}`} onClick={() => onRemove(file.id)}
          className={`-my-1 flex size-6 items-center justify-center text-ink-3 transition-colors duration-100 hover:bg-line/70 hover:text-ink ${pill ? "rounded-full" : "rounded-[5px]"}`}>
          <Icon size={10} strokeWidth={2.5}><path d="M18 6L6 18M6 6l12 12" /></Icon>
        </button>
      </span>)}
      {failed.map(file => <span key={file.id}
        className={`flex h-6.5 max-w-full items-center gap-1 bg-field py-1 pr-1 pl-1.5 text-[11.5px] text-red shadow-hairline ${pill ? "rounded-full" : "rounded-chip"}`}
        role="status">
        <span className="max-w-36 truncate" title={file.error}>{file.name}</span>
        {onRetryFailed && <button type="button" aria-label={`Retry ${file.name}`} onClick={() => onRetryFailed(file.id)}
          className={`flex h-6 items-center px-1.5 text-[11px] text-ink-2 hover:bg-hover hover:text-ink ${pill ? "rounded-full" : "rounded-[5px]"}`}>Retry</button>}
        <button type="button" aria-label={`Remove ${file.name}`} onClick={() => (onDismissFailed ?? onRemove)(file.id)}
          className={`-my-1 flex size-6 items-center justify-center text-ink-3 transition-colors duration-100 hover:bg-line/70 hover:text-ink ${pill ? "rounded-full" : "rounded-[5px]"}`}>
          <Icon size={10} strokeWidth={2.5}><path d="M18 6L6 18M6 6l12 12" /></Icon>
        </button>
      </span>)}
    </div>}
    {failed.length > 0 && <p className={`text-[11.5px] text-red ${pill ? "px-2" : "px-1"}`} role="status">{failed[failed.length - 1]?.error}</p>}
    {preview && <AttachmentPreview key={preview.id} file={preview} onClose={() => setPreviewId(null)} />}
  </>;
}

function AttachmentPreview({ file, onClose }: { file: Attachment; onClose(): void }) {
  const dialog = useRef<HTMLDialogElement>(null);
  const title = useId();
  const [failed, setFailed] = useState(false);
  useLayoutEffect(() => {
    const element = dialog.current;
    element?.showModal();
    return () => element?.close();
  }, []);
  return createPortal(<dialog ref={dialog} role="dialog" aria-modal="true" aria-labelledby={title}
    onCancel={event => { event.preventDefault(); event.stopPropagation(); onClose(); }}
    onKeyDown={event => event.stopPropagation()}
    onClick={event => { if (event.target === event.currentTarget) onClose(); }}
    className="m-auto max-h-[90dvh] w-fit max-w-[calc(100vw-32px)] overflow-auto rounded-xl border border-line bg-surface p-0 text-ink shadow-overlay backdrop:bg-black/50">
    <div className="p-3">
      <header className="mb-3 flex items-center gap-6">
        <h2 id={title} className="min-w-0 flex-1 truncate text-sm font-medium">{file.name}</h2>
        <button type="button" aria-label="Close image preview" onClick={onClose}
          className="size-7 shrink-0 rounded text-ink-3 hover:bg-hover focus-visible:outline-auto">×</button>
      </header>
      {failed ? <p role="alert" className="p-4 text-sm">Could not display this image. Your attachment is still in the draft.</p> :
        /* eslint-disable-next-line @next/next/no-img-element */
        <img src={file.preview} alt={file.name} onError={() => setFailed(true)} className="max-h-[70dvh] max-w-full rounded object-contain" />}
    </div>
  </dialog>, document.body);
}
