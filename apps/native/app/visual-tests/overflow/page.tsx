import { notFound } from "next/navigation";
import OverflowFixture from "./overflow-fixture";

export const dynamic = "force-dynamic";

export default function OverflowPage() {
  if (process.env.GRAFF_VISUAL_TESTS !== "1") notFound();
  return <OverflowFixture />;
}
