import { LegendList } from "@legendapp/list/react";
import type {
  LegendListRef,
  NativeScrollEvent,
  NativeSyntheticEvent,
} from "@legendapp/list/react";
import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import type { WheelEvent } from "react";
import { ArrowDownIcon } from "lucide-react";

import { CHAT_BADGE_TEXT_CLASS } from "./constants/chatStyles";
import type { ChatThreadProps } from "./types/chatComponents";
import {
  buildChatThreadItemsWithCache,
  type ChatThreadItemBuildCache,
} from "./utils/chatThread";
import { renderChatThreadItem } from "./utils/chatThreadList";

const BOTTOM_LOCK_THRESHOLD = 8;

export function ChatThread({
  activeRequestIds,
  commandResults = [],
  conversationVersion,
  messages,
  requestTimingsById,
  workspaceLabel,
  workspacePath,
}: ChatThreadProps) {
  const listRef = useRef<LegendListRef>(null);
  const isFollowingRef = useRef(true);
  const userWantsFollowRef = useRef(true);
  const isProgrammaticScrollRef = useRef(false);
  const lastScrollOffsetRef = useRef<number | null>(null);
  const followFrameRefs = useRef<number[]>([]);
  const itemBuildCacheRef = useRef<ChatThreadItemBuildCache | null>(null);
  const lastSeenPromptIdRef = useRef<string | null>(null);
  const previousItemCountRef = useRef(0);
  // Mirror of isFollowingRef for rendering (the pill). Pending count tracks how
  // many new items landed while the user was scrolled up, so the pill can say
  // "3 new" instead of just "scroll to latest".
  const [isFollowing, setIsFollowing] = useState(true);
  const [pendingCount, setPendingCount] = useState(0);
  const latestSentPromptId = (() => {
    for (let index = messages.length - 1; index >= 0; index -= 1) {
      const message = messages[index];
      if (message.kind === "user") {
        return message.id;
      }
    }
    return null;
  })();
  const streamingTextLength = (() => {
    let totalLength = 0;
    for (const message of messages) {
      if (message.kind === "assistant" || message.kind === "reasoning") {
        totalLength += message.text.length;
      }
    }
    return totalLength;
  })();
  const activeRequestKey = activeRequestIds.join("\u0000");
  const items = useMemo(() => {
    const built = buildChatThreadItemsWithCache(
      messages,
      activeRequestIds,
      itemBuildCacheRef.current,
    );
    itemBuildCacheRef.current = built.cache;
    return [
      ...built.items,
      ...commandResults.map((result, index) => ({
        kind: "command_result" as const,
        key: `command-result:${index}:${result.title}`,
        result,
      })),
    ];
  }, [activeRequestIds, commandResults, conversationVersion, messages]);

  const setFollowing = useCallback((next: boolean) => {
    isFollowingRef.current = next;
    setIsFollowing(next);
    if (next) {
      setPendingCount(0);
    }
  }, []);

  const markProgrammaticScroll = useCallback(() => {
    isProgrammaticScrollRef.current = true;
    requestAnimationFrame(() => {
      requestAnimationFrame(() => {
        isProgrammaticScrollRef.current = false;
      });
    });
  }, []);

  const scrollToBottom = useCallback(() => {
    const list = listRef.current;
    if (list == null) {
      return;
    }

    markProgrammaticScroll();
    list.scrollToEnd({ animated: false });

    const node = list.getScrollableNode();
    if (node != null) {
      node.scrollTop = node.scrollHeight - node.clientHeight;
      lastScrollOffsetRef.current = node.scrollTop;
    }
  }, [markProgrammaticScroll]);

  const scheduleFollowToBottom = useCallback(() => {
    if (!isFollowingRef.current) {
      return;
    }

    for (const frame of followFrameRefs.current) {
      cancelAnimationFrame(frame);
    }
    followFrameRefs.current = [];

    const schedule = (callback: () => void) => {
      const frame = requestAnimationFrame(() => {
        followFrameRefs.current = followFrameRefs.current.filter(
          (activeFrame) => activeFrame !== frame,
        );
        callback();
      });
      followFrameRefs.current.push(frame);
    };

    schedule(() => {
      if (!isFollowingRef.current) {
        return;
      }
      scrollToBottom();
      schedule(() => {
        if (isFollowingRef.current) {
          scrollToBottom();
        }
      });
    });
  }, [scrollToBottom]);

  // Count new items that arrive while the user is scrolled up, so the
  // jump-to-latest pill can surface "N new" rather than silently accumulating
  // content off-screen.
  useEffect(() => {
    const previous = previousItemCountRef.current;
    previousItemCountRef.current = items.length;
    if (items.length > previous && !isFollowingRef.current) {
      setPendingCount((count) => count + (items.length - previous));
    }
  }, [items.length]);

  // Keep locked chats pinned after content changes without scheduling layout work
  // on unrelated renders.
  useEffect(() => {
    if (isFollowingRef.current) {
      scheduleFollowToBottom();
    }
  }, [activeRequestKey, items.length, streamingTextLength, scheduleFollowToBottom]);

  useEffect(
    () => () => {
      for (const frame of followFrameRefs.current) {
        cancelAnimationFrame(frame);
      }
      followFrameRefs.current = [];
    },
    [],
  );

  // Re-arm follow when the user sends a new message, including the first prompt.
  useEffect(() => {
    if (latestSentPromptId == null) {
      return;
    }
    if (lastSeenPromptIdRef.current === latestSentPromptId) {
      return;
    }
    lastSeenPromptIdRef.current = latestSentPromptId;
    userWantsFollowRef.current = true;
    setFollowing(true);
    scheduleFollowToBottom();
  }, [latestSentPromptId, scheduleFollowToBottom, setFollowing]);

  const handleScroll = useCallback(
    (event: NativeSyntheticEvent<NativeScrollEvent>) => {
      const { contentOffset, contentSize, layoutMeasurement } =
        event.nativeEvent;
      const offset = contentOffset.y;
      const previousOffset = lastScrollOffsetRef.current;
      const distanceFromBottom =
        contentSize.height - layoutMeasurement.height - offset;
      const isAtBottom = distanceFromBottom <= BOTTOM_LOCK_THRESHOLD;

      if (
        previousOffset != null &&
        offset < previousOffset - 1 &&
        !isProgrammaticScrollRef.current
      ) {
        userWantsFollowRef.current = false;
        setFollowing(false);
      }

      if (offset > (previousOffset ?? offset)) {
        userWantsFollowRef.current = true;
      }

      if (isAtBottom && userWantsFollowRef.current && !isFollowingRef.current) {
        setFollowing(true);
        scheduleFollowToBottom();
      }

      lastScrollOffsetRef.current = offset;
    },
    [scheduleFollowToBottom, setFollowing],
  );

  // Wheel intent gives immediate scroll-lock feedback for mouse and trackpad users.
  const handleWheel = useCallback((event: WheelEvent) => {
    if (event.deltaY < 0) {
      userWantsFollowRef.current = false;
      setFollowing(false);
      return;
    }
    if (event.deltaY > 0) {
      userWantsFollowRef.current = true;
    }
  }, [setFollowing]);

  const handleJumpToLatest = useCallback(() => {
    userWantsFollowRef.current = true;
    setFollowing(true);
    scrollToBottom();
  }, [scrollToBottom, setFollowing]);

  return (
    <div className="relative h-full">
      <LegendList
        ref={listRef}
        data={items}
        renderItem={(props) =>
          renderChatThreadItem(props, {
            activeRequestIds,
            requestTimingsById,
            workspacePath,
            itemCount: items.length,
          })
        }
        keyExtractor={(item) => item.key}
        getItemType={(item) =>
          item.kind === "message" ? item.message.kind : item.kind
        }
        onScroll={handleScroll}
        onWheel={handleWheel}
        initialScrollAtEnd={items.length > 0}
        estimatedItemSize={88}
        style={{ height: "100%" }}
        contentContainerStyle={{
          paddingTop: 20,
          paddingBottom: 24,
        }}
        ListEmptyComponent={
          <div className="mx-auto flex min-h-full w-full max-w-3xl items-center justify-center px-6 py-12">
            <div className="w-full rounded-3xl border border-black/5 bg-black/5 px-8 py-10 text-center dark:border-white/10 dark:bg-white/5">
              <p className={`${CHAT_BADGE_TEXT_CLASS} text-muted-foreground`}>
                New chat
              </p>
              <h2 className="mt-3 text-2xl font-semibold tracking-tight text-foreground">
                Ask anything about {workspaceLabel}
              </h2>
              <p className="mt-3 text-sm leading-6 text-muted-foreground">
                Start with a question, a task, or a change you want to make in
                this workspace.
              </p>
            </div>
          </div>
        }
      />
      {!isFollowing ? (
        <div className="pointer-events-none absolute inset-x-0 bottom-3 flex justify-center px-4">
          <button
            type="button"
            onClick={handleJumpToLatest}
            className="pointer-events-auto inline-flex items-center gap-1.5 rounded-full border border-border bg-card px-3 py-1.5 text-xs font-medium text-foreground shadow-[var(--elevation-md)] transition hover:bg-accent hover:text-accent-foreground"
          >
            <ArrowDownIcon className="size-3.5" />
            {pendingCount > 0 ? `${pendingCount} new` : "Scroll to latest"}
          </button>
        </div>
      ) : null}
    </div>
  );
}
