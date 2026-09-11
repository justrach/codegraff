import {notFound} from "next/navigation";
import McpAppResult from "@/components/site/McpAppResult";
export const dynamic = "force-dynamic";
export default async function Page({searchParams}: {searchParams:Promise<{id?:string}>}) {
  if (process.env.GRAFF_VISUAL_TESTS !== "1") notFound();
  const {id} = await searchParams;
  return <main style={{maxWidth:900,margin:"30px auto"}}><h1>Simulated MCP app</h1><McpAppResult id={id ?? ""} /></main>;
}
