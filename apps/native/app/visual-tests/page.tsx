import { notFound } from "next/navigation";
import TurnFixture from "./turn-fixture";
export const dynamic = "force-dynamic";
export default function VisualTests() {
  if (process.env.GRAFF_VISUAL_TESTS !== "1") notFound();
  return <TurnFixture />;
}
