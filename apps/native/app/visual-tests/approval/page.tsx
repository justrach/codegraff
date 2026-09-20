import { notFound } from "next/navigation";
import ApprovalFixture from "./fixture";

export const dynamic = "force-dynamic";

export default function ApprovalVisualTest() {
  if (process.env.GRAFF_VISUAL_TESTS !== "1") notFound();
  return <ApprovalFixture />;
}
