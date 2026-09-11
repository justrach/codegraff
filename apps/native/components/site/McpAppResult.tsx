"use client";
import SnapshotView from "./SnapshotView";

export default function McpAppResult({id}: {id: string}) {
  return <SnapshotView kind="mcp-app" id={id} />;
}
