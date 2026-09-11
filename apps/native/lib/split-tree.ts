export type SplitAxis = 'row' | 'column';
export type SplitTree = number | { key: string; axis: SplitAxis; ratio: number; first: SplitTree; second: SplitTree };
export type SplitBox = { left: number; top: number; width: number; height: number };
let sequence = 0;
export const splitIds = (tree: SplitTree): number[] => typeof tree === 'number' ? [tree] : [...splitIds(tree.first), ...splitIds(tree.second)];
export function joinSplit(first: SplitTree, second: SplitTree, axis: SplitAxis, ratio = .5): SplitTree {
  return { key: `split-${++sequence}`, axis, ratio, first, second };
}
export function flatSplit(ids: number[], axis: SplitAxis): SplitTree {
  if (!ids.length) throw Error('A split needs a chat');
  return ids.slice(1).reduce<SplitTree>((tree,id,index) => joinSplit(tree,id,axis,(index+1)/(index+2)),ids[0]);
}
export function pruneSplit(tree: SplitTree, live: ReadonlySet<number>): SplitTree | null {
  if (typeof tree === 'number') return live.has(tree) ? tree : null;
  const first=pruneSplit(tree.first,live), second=pruneSplit(tree.second,live);
  if (first===null) return second;
  if (second===null) return first;
  return first===tree.first&&second===tree.second ? tree : {...tree,first,second};
}
export function insertSplit(tree: SplitTree, target: number, source: SplitTree, edge: 'left'|'right'|'top'|'bottom'): SplitTree {
  if (typeof tree==='number') {
    if (tree!==target) return tree;
    const before=edge==='left'||edge==='top', axis=edge==='left'||edge==='right'?'row':'column';
    return joinSplit(before?source:tree,before?tree:source,axis);
  }
  const first=insertSplit(tree.first,target,source,edge),second=insertSplit(tree.second,target,source,edge);
  return first===tree.first&&second===tree.second?tree:{...tree,first,second};
}
export function resizeSplit(tree: SplitTree, key: string, ratio: number): SplitTree {
  if(typeof tree==='number')return tree;
  if(tree.key===key)return {...tree,ratio:Math.max(.1,Math.min(.9,ratio))};
  const first=resizeSplit(tree.first,key,ratio),second=resizeSplit(tree.second,key,ratio);
  return first===tree.first&&second===tree.second?tree:{...tree,first,second};
}
export function resizeChatSplit(tree: SplitTree, chat: number, delta: number): SplitTree {
  if(typeof tree==='number')return tree;
  if(tree.first===chat)return {...tree,ratio:Math.max(.15,Math.min(.85,tree.ratio+delta))};
  if(tree.second===chat)return {...tree,ratio:Math.max(.15,Math.min(.85,tree.ratio-delta))};
  const first=resizeChatSplit(tree.first,chat,delta),second=resizeChatSplit(tree.second,chat,delta);
  return first===tree.first&&second===tree.second?tree:{...tree,first,second};
}
export function balanceSplit(tree: SplitTree): SplitTree {
  if (typeof tree === 'number') return tree;
  const uniform = (node: SplitTree): boolean => typeof node === 'number' || node.axis === tree.axis && uniform(node.first) && uniform(node.second);
  const ratio = uniform(tree) ? splitIds(tree.first).length / splitIds(tree).length : .5;
  return {...tree,ratio,first:balanceSplit(tree.first),second:balanceSplit(tree.second)};
}
export function splitGeometry(tree: SplitTree) {
  const panes: {id:number;box:SplitBox}[]=[], dividers: {node:Exclude<SplitTree,number>;box:SplitBox}[]=[];
  const visit=(node:SplitTree,box:SplitBox)=>{
    if(typeof node==='number'){panes.push({id:node,box});return;}
    dividers.push({node,box});
    if(node.axis==='row') {
      visit(node.first,{...box,width:box.width*node.ratio});
      visit(node.second,{...box,left:box.left+box.width*node.ratio,width:box.width*(1-node.ratio)});
    } else {
      visit(node.first,{...box,height:box.height*node.ratio});
      visit(node.second,{...box,top:box.top+box.height*node.ratio,height:box.height*(1-node.ratio)});
    }
  };
  visit(tree,{left:0,top:0,width:1,height:1});return {panes,dividers};
}
export function paneStyle(box:SplitBox) {
  const x=box.left>1e-6?5:0,y=box.top>1e-6?5:0;
  return {left:`calc(${box.left*100}% + ${x}px)`,top:`calc(${box.top*100}% + ${y}px)`,
    width:`calc(${box.width*100}% - ${x+(box.left+box.width<.999999?5:0)}px)`,
    height:`calc(${box.height*100}% - ${y+(box.top+box.height<.999999?5:0)}px)`};
}
export function dividerStyle(node:Exclude<SplitTree,number>,box:SplitBox) {
  return node.axis==='row'?{left:`calc(${(box.left+box.width*node.ratio)*100}% - 5px)`,top:`${box.top*100}%`,width:'10px',height:`${box.height*100}%`}
    :{left:`${box.left*100}%`,top:`calc(${(box.top+box.height*node.ratio)*100}% - 5px)`,width:`${box.width*100}%`,height:'10px'};
}
