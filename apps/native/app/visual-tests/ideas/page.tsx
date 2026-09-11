import { notFound } from 'next/navigation';
import IdeasFixture from './ideas-fixture';
export const dynamic = 'force-dynamic';
export default function IdeasPage() {
  if (process.env.GRAFF_VISUAL_TESTS !== '1') notFound();
  return <IdeasFixture />;
}
