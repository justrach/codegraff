import { notFound } from "next/navigation";
import CodeFixture from "./code-fixture";
export const dynamic = "force-dynamic";
export default function CodePage() {
  if (process.env.GRAFF_VISUAL_TESTS !== "1") notFound();
  return <CodeFixture />;
}
