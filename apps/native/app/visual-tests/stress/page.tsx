import { notFound } from 'next/navigation';
import StressFixture from './stress-fixture';
export const dynamic = 'force-dynamic';
export default function StressPage() {
  if (process.env.GRAFF_VISUAL_TESTS !== '1') notFound();
  return <StressFixture />;
}
