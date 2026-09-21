"use client";

import dynamic from "next/dynamic";

/** Panes that are off-screen at boot. Keep them out of the first renderer
 *  parse so idle RSS is the chat chrome, not xterm/agents/files/browser. */
export const ProjectsPane = dynamic(() => import("./ProjectsPane"));
export const TerminalPane = dynamic(() => import("./TerminalPane"), { ssr: false });
export const AgentsPane = dynamic(() => import("./AgentsPane"));
export const ChangesPane = dynamic(() => import("./ChangesPane"));
export const ReviewsPane = dynamic(() => import("./ReviewsPane"));
export const ConversationsPane = dynamic(() => import("./ConversationsPane"));
export const FilesPane = dynamic(() => import("./FilesPane"));
export const BrowserPane = dynamic(() => import("./DesktopBrowserPane"));
export const TasksSidebar = dynamic(() => import("./TasksSidebar"));
export const AppSettings = dynamic(() => import("./AppSettings"));
export const AccountChrome = dynamic(() => import("./AccountChrome"));
export const WorkspaceDialog = dynamic(() => import("./WorkspaceDialog"));
