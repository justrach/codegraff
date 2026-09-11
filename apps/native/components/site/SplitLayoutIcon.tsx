import {splitGeometry,type SplitTree} from '@/lib/split-tree';
export default function SplitLayoutIcon({tree}:{tree:SplitTree}) {
  return <svg aria-hidden="true" className="mr-1 size-4 shrink-0 opacity-70" viewBox="0 0 20 20" fill="none" stroke="currentColor" strokeWidth="1.2">
    {splitGeometry(tree).panes.map(({id,box})=><rect key={id} x={1+box.left*18} y={1+box.top*18} width={box.width*18-2} height={box.height*18-2} rx="1"/>)}
  </svg>;
}
