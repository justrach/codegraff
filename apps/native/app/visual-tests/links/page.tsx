import { notFound } from "next/navigation";
import LinkFixture from "./link-fixture";

export const dynamic = "force-dynamic";

export default function LinksPage() {
  if (process.env.GRAFF_VISUAL_TESTS !== "1") notFound();
  return <LinkFixture />;
}
