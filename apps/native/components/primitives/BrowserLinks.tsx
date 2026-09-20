import { Children, Fragment, type ReactNode } from "react";
import { browserLinkSegments } from "@/lib/browser-links";

export const BROWSER_LINK_CLASS =
  "cursor-pointer text-ink underline decoration-line underline-offset-2 transition-colors hover:decoration-ink";

export function BrowserLink({ href, children, className = BROWSER_LINK_CLASS }: {
  href: string;
  children: ReactNode;
  className?: string;
}) {
  return <a href={href} target="_blank" rel="noreferrer" className={className}>{children}</a>;
}

export function linkifyBrowserChildren(children: ReactNode): ReactNode {
  return Children.map(children, (child, childIndex) => {
    if (typeof child !== "string") return child;
    return browserLinkSegments(child).map((segment, segmentIndex) =>
      segment.kind === "text" ? (
        <Fragment key={`${childIndex}-text-${segmentIndex}`}>{segment.value}</Fragment>
      ) : (
        <BrowserLink key={`${childIndex}-link-${segmentIndex}`} href={segment.href}>
          {segment.label}
        </BrowserLink>
      ),
    );
  });
}

export function BrowserLinkText({ text }: { text: string }) {
  return <>{linkifyBrowserChildren(text)}</>;
}
