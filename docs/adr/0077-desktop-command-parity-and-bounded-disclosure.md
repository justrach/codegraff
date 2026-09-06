# 0077. Keep desktop commands in parity and bound transcript disclosure

Status: accepted

## Decision

ACP advertises the entire shared REPL command catalog, including commands whose
presentation remains terminal-specific. The desktop consumes that advertisement
and shares it with new tabs before they create coding sessions. A catalog parity
test prevents commands from silently disappearing from one client. The GUI does
not maintain a second, independently edited command list.

Command menus fit the available viewport. Tool groups stay collapsed until the
user opens them and mount only the current page of rows. Individual output is
mounted only on disclosure; oversized previews retain their beginning and end
with an explicit omission marker. Restored conversation history initially mounts
its newest page, with earlier messages available on request.

Desktop shortcuts adapt chat and split actions from familiar terminal conventions.
They do not emit terminal control sequences. Native fullscreen state removes the
windowed title spacer and is republished after renderer reloads.

## Consequences

Engine behavior remains shared across clients. Terminal-only display settings do
not become GUI themes merely because they are discoverable. GUI previews are
bounded and clearly labeled; stored sessions and engine results remain intact.
Loading earlier pages increases mounted history, so this is not full transcript
virtualization. Synthetic tests cover navigation and disclosure without a model;
real coding remains a separate, opt-in integration check.
