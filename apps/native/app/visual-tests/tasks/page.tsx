import { notFound } from "next/navigation";
import TaskRowsFixture from "./fixture";

export const dynamic = "force-dynamic";

export default function TasksPage() {
  if (process.env.GRAFF_VISUAL_TESTS !== "1") notFound();
  return <TaskRowsFixture />;
}
