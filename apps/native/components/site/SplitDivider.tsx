import {useEffect,useMemo,useRef,useState} from 'react';
import {createFrameBatch} from '@/lib/frame-batch';
import {dividerStyle,paneStyle,resizeSplit,splitGeometry,splitIds,type SplitBox,type SplitTree} from '@/lib/split-tree';

function paint(root:HTMLElement,tree:SplitTree) {
  const {panes,dividers}=splitGeometry(tree);
  for(const {id,box} of panes) { const pane=root.querySelector<HTMLElement>(`[data-chat="${id}"]`);if(pane)Object.assign(pane.style,paneStyle(box)); }
  for(const {node,box} of dividers) {
    const divider=root.querySelector<HTMLElement>(`[data-split-node="${node.key}"]`);
    if(divider){Object.assign(divider.style,dividerStyle(node,box));divider.setAttribute('aria-valuenow',String(Math.round(node.ratio*100)));}
  }
}
export default function SplitDivider({node,box,tree,onChange,index}:{
  node:Exclude<SplitTree,number>;box:SplitBox;tree:SplitTree;onChange(tree:SplitTree):void;index:number;
}) {
  const vertical=node.axis==='row';
  const drag=useRef<{root:HTMLElement;start:number;extent:number;tree:SplitTree;next:SplitTree}|null>(null);
  const [dragging,setDragging]=useState(false);
  const preview=useMemo(()=>createFrameBatch<{root:HTMLElement;tree:SplitTree}>(value=>paint(value.root,value.tree)),[]);
  useEffect(()=>()=>preview.cancel(),[preview]);
  const move=(position:number)=>{
    const state=drag.current;if(!state)return;
    const minimum=Math.min(vertical?180:120,state.extent/3)/state.extent;
    const ratio=Math.max(minimum,Math.min(1-minimum,node.ratio+(position-state.start)/state.extent));
    state.next=resizeSplit(state.tree,node.key,ratio);preview.update({root:state.root,tree:state.next});
  };
  const finish=(cancel=false)=>{
    const state=drag.current;if(!state)return;
    preview.cancel();paint(state.root,cancel?state.tree:state.next);drag.current=null;setDragging(false);
    if(!cancel)onChange(state.next);
  };
  return <div role="separator" tabIndex={0} aria-label={`Resize chat panes ${index+1} and ${index+2}`}
    data-chat-divider data-split-node={node.key} data-resize-first={splitIds(node.first)[0]}
    aria-orientation={vertical?'vertical':'horizontal'} aria-valuemin={0} aria-valuemax={100} aria-valuenow={Math.round(node.ratio*100)}
    title="Drag to resize · Double-click to balance" style={dividerStyle(node,box)}
    className={`group absolute z-10 flex touch-none items-center justify-center outline-none ${vertical?'cursor-col-resize':'cursor-row-resize'}`}
    onPointerDown={event=>{
      if(event.button!==0)return;
      const root=event.currentTarget.parentElement!;const bounds=root.getBoundingClientRect();
      event.preventDefault();event.currentTarget.focus({preventScroll:true});
      drag.current={root,start:vertical?event.clientX:event.clientY,extent:vertical?bounds.width*box.width:bounds.height*box.height,tree,next:tree};
      event.currentTarget.setPointerCapture(event.pointerId);setDragging(true);
    }}
    onPointerMove={event=>move(vertical?event.clientX:event.clientY)}
    onPointerUp={event=>{move(vertical?event.clientX:event.clientY);finish();if(event.currentTarget.hasPointerCapture(event.pointerId))event.currentTarget.releasePointerCapture(event.pointerId);}}
    onPointerCancel={()=>finish(true)} onLostPointerCapture={()=>finish()}
    onDoubleClick={()=>onChange(resizeSplit(tree,node.key,.5))}
    onKeyDown={event=>{
      const delta=event.key===(vertical?'ArrowLeft':'ArrowUp')?-.05:event.key===(vertical?'ArrowRight':'ArrowDown')?.05:0;
      if(delta){event.preventDefault();event.stopPropagation();onChange(resizeSplit(tree,node.key,node.ratio+delta));}
    }}>
    <span className={`${vertical?'h-8 w-0.5':'h-0.5 w-8'} rounded-full ${dragging?'bg-accent':'bg-line-strong group-hover:bg-accent group-focus-visible:bg-accent'}`} />
  </div>;
}
