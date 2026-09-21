import { notFound } from "next/navigation";
import Fixture from "./fixture";

export const dynamic = "force-dynamic";

export default function AccountVisualTest() {
  if (process.env.GRAFF_VISUAL_TESTS !== "1") notFound();
  return <Fixture />;
}
