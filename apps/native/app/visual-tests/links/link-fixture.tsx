"use client";

import { useEffect, useState } from "react";
import { UserBubble } from "@/components/site/ChatBubbles";

export default function LinkFixture() {
  const [target, setTarget] = useState("");
  useEffect(() => setTarget(new URLSearchParams(window.location.search).get("target") ?? ""), []);
  return <main data-link-message-fixture data-ready={target ? "true" : "false"} className="p-6">
    {target && <UserBubble text={`Open ${target}`} />}
  </main>;
}
