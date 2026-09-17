import ActionMenu from "@/components/primitives/ActionMenu";

type Props = {
  className?: string;
  filesOpen: boolean;
  changesOpen: boolean;
  browserOpen: boolean;
  terminalVisible: boolean;
  pinCount: number;
  onFiles(): void;
  openChanges(): void;
  onBrowser(): void;
  toggleTerminal(): void;
};

export default function WorkspacePaneMenu({
  className = "",
  filesOpen, changesOpen, browserOpen, terminalVisible, pinCount,
  onFiles, openChanges, onBrowser, toggleTerminal,
}: Props) {
  return (
    <ActionMenu
      label="Workspace panes"
      className={className}
      text={
        <svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" aria-hidden>
          <rect x="3" y="4" width="18" height="16" rx="2" />
          <path d="M15 4v16" />
        </svg>
      }
    >
      <button type="button" aria-pressed={changesOpen} onClick={openChanges}>
        Review
      </button>
      <button type="button" aria-pressed={terminalVisible} onClick={toggleTerminal}>
        Terminal <span className="ml-auto text-ink-3">⌘J</span>
      </button>
      <button type="button" aria-pressed={browserOpen} onClick={onBrowser}>
        Browser{pinCount > 0 ? ` (${pinCount})` : ""}
      </button>
      <button type="button" aria-pressed={filesOpen && !changesOpen} onClick={onFiles}>
        Files
      </button>
    </ActionMenu>
  );
}
