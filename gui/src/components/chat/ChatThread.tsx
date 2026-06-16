import { LegendList } from "@legendapp/list/react";
import type {
  LegendListRef,
  NativeScrollEvent,
  NativeSyntheticEvent,
} from "@legendapp/list/react";
import { useCallback, useEffect, useRef } from "react";
import type { WheelEvent } from "react";

import { CHAT_BADGE_TEXT_CLASS } from "./constants/chatStyles";
import type { ChatThreadProps } from "./types/chatComponents";
import { buildChatThreadItems } from "./utils/chatThread";
import { renderChatThreadItem } from "./utils/chatThreadList";

const BOTTOM_LOCK_THRESHOLD = 8;

export function ChatThread({
  activeRequestIds,
  commandResults = [],
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
  const lastSeenPromptIdRef = useRef<string | null>(null);
  const latestSentPromptId = (() => {
    for (let index = messages.length - 1; index >= 0; index -= 1) {
      const message = messages[index];
      if (message.kind === "user") {
        return message.id;
      }
    }
    return null;
  })();
  const items = [
    ...buildChatThreadItems(messages, activeRequestIds),
    ...commandResults.map((result, index) => ({
      kind: "command_result" as const,
      key: `command-result:${index}:${result.title}`,
      result,
    })),
  ];

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

  // The thread re-renders on every streaming update, so keep locked chats pinned
  // after both React commit and LegendList's follow-up layout measurements.
  useEffect(() => {
    if (isFollowingRef.current) {
      scheduleFollowToBottom();
    }
  });

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
    isFollowingRef.current = true;
    scheduleFollowToBottom();
  }, [latestSentPromptId, scheduleFollowToBottom]);

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
        isFollowingRef.current = false;
      }

      if (offset > (previousOffset ?? offset)) {
        userWantsFollowRef.current = true;
      }

      if (isAtBottom && userWantsFollowRef.current && !isFollowingRef.current) {
        isFollowingRef.current = true;
        scheduleFollowToBottom();
      }

      lastScrollOffsetRef.current = offset;
    },
    [scheduleFollowToBottom],
  );

  // Wheel intent gives immediate scroll-lock feedback for mouse and trackpad users.
  const handleWheel = useCallback((event: WheelEvent) => {
    if (event.deltaY < 0) {
      userWantsFollowRef.current = false;
      isFollowingRef.current = false;
      return;
    }
    if (event.deltaY > 0) {
      userWantsFollowRef.current = true;
    }
  }, []);

  return (
    <LegendList
      ref={listRef}
      data={items}
      renderItem={(props) =>
        renderChatThreadItem(props, {
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
  );
}
