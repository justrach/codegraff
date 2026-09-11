import {test,expect} from 'bun:test';
import {flatSplit,insertSplit,splitIds,splitGeometry,pruneSplit,resizeSplit,resizeChatSplit,balanceSplit} from './split-tree';
test('balancing keeps rows equal and closing a branch expands only its sibling',()=>{
  expect(splitGeometry(balanceSplit(flatSplit([1,2,3,4],'row'))).panes.map(p=>p.box.width)).toEqual([.25,.25,.25,.25]);
  const mixed=insertSplit(insertSplit(insertSplit(1,1,2,'right'),1,3,'bottom'),2,4,'bottom');
  const boxes=splitGeometry(pruneSplit(mixed,new Set([1,2,4]))!).panes;
  expect(boxes.find(p=>p.id===1)?.box.height).toBe(1);
  expect(boxes.find(p=>p.id===2)?.box.height).toBe(.5);
  expect(boxes.find(p=>p.id===4)?.box.height).toBe(.5);
  expect(splitIds(pruneSplit(mixed,new Set([2,4]))!)).toEqual([2,4]);
});
test('left/right/down/down makes four independent quadrants',()=>{
  let tree=insertSplit(1,1,2,'right');tree=insertSplit(tree,1,3,'bottom');tree=insertSplit(tree,2,4,'bottom');
  expect(splitIds(tree)).toEqual([1,3,2,4]);
  expect(splitGeometry(tree).panes.map(p=>p.box)).toEqual([
    {left:0,top:0,width:.5,height:.5},{left:0,top:.5,width:.5,height:.5},
    {left:.5,top:0,width:.5,height:.5},{left:.5,top:.5,width:.5,height:.5},
  ]);
  expect(splitIds(pruneSplit(tree,new Set([1,2,4]))!)).toEqual([1,2,4]);
});
test('mixed layouts survive repeated resize, removal and balancing without overlap',()=>{
  for(let i=0;i<200;i++) {
    let tree=insertSplit(insertSplit(1,1,2,'left'),1,3,'bottom');
    const branch=splitGeometry(tree).dividers[0].node;
    tree=resizeSplit(tree,branch.key,(i%100)/100);
    tree=resizeChatSplit(tree,3,.05);
    const boxes=splitGeometry(tree).panes;
    expect(boxes.reduce((n,p)=>n+p.box.width*p.box.height,0)).toBeCloseTo(1);
    for(const a of boxes)for(const b of boxes)if(a.id!==b.id) {
      const overlap=Math.min(a.box.left+a.box.width,b.box.left+b.box.width)-Math.max(a.box.left,b.box.left);
      const vertical=Math.min(a.box.top+a.box.height,b.box.top+b.box.height)-Math.max(a.box.top,b.box.top);
      expect(overlap>1e-8&&vertical>1e-8).toBe(false);
    }
    expect(splitIds(balanceSplit(tree))).toEqual(splitIds(tree));
  }
  expect(pruneSplit(flatSplit([1,2,3],'row'),new Set([2]))).toBe(2);
  expect(pruneSplit(1,new Set())).toBeNull();
});
