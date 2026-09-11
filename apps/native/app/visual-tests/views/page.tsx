import {notFound} from "next/navigation";
import SnapshotView from "@/components/site/SnapshotView";
export const dynamic = "force-dynamic";
export default async function Page({searchParams}: {searchParams:Promise<{id?:string}>}) {
  if (process.env.GRAFF_VISUAL_TESTS !== "1") notFound();
  const {id} = await searchParams;
  return <main style={{maxWidth:900,margin:"30px auto"}}><h1>Simulated rendered view</h1><SnapshotView kind="view" id={id ?? ""} /></main>;
}
