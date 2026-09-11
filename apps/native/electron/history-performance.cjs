const assert=require('node:assert/strict');
async function historyPerformance({wc,run,wait,output}) {
  const js=source=>wc.executeJavaScript(source);
  await js(`(()=>{
    const original=window.fetch;
    const row={name:'large-history',title:'Large saved history',updatedMs:100,model:null,provider:null,size:1};
    const code='\x60\x60\x60typescript\\n'+Array.from({length:300},(_,i)=>'export const sample'+i+' = (value: number) => value + '+i+'; // sample row\\n').join('')+'\x60\x60\x60';
    window.fetch=async(input,options)=>{
      const url=new URL(String(input),location.origin);
      if(url.pathname!=='/api/sessions')return original(input,options);
      const body=url.searchParams.has('name')?{...row,messages:Array.from({length:window.historyReplyCount??24},(_,i)=>[{role:'user',content:'Saved request '+i},{role:'assistant',content:'Saved reply '+i+'\\n\\n'+code}]).flat()}:{sessions:[row],total:1,nextCursor:null};
      return new Response(JSON.stringify(body),{headers:{'content-type':'application/json'}});
    };
  })()`);
  const result=await run('saved-history',async()=>{
    await js(`document.querySelector('[aria-label="Conversations"]').click()`);
    await wait(`document.querySelector('[data-conversation-library]')?.textContent.includes('Large saved history')`);
    await js(`Array.from(document.querySelectorAll('[data-conversation-library] li button')).find(e=>e.textContent.includes('Large saved history')).click()`);
    await wait(`document.body.textContent.includes('Saved reply 23')`);
    await wait(`!document.querySelector('[data-streamdown="code-block"] [data-loading="true"]')`);
    assert.ok(await js(`document.querySelectorAll('article').length>0`));
  });
  require('node:fs').writeFileSync(require('node:path').join(output,'saved-history.png'),(await wc.capturePage()).toPNG());
  if(process.env.GRAFF_BENCHMARK_REQUIRE_BOUNDED_HISTORY==='1') {
    assert.ok(await js(`document.querySelectorAll('article').length<=3`),'Initial code history must be bounded by content');
    assert.ok(result.memory.domNodes<50000,'Initial saved history must not create a giant DOM');
    await js(`document.querySelector('[data-chat-transcript]').scrollTop=0`);
    await new Promise(resolve=>setTimeout(resolve,100));
    await js(`Array.from(document.querySelectorAll('button')).find(b=>b.textContent.startsWith('Show earlier messages')).click()`);
    await wait(`document.body.textContent.includes('Saved reply 21')`);
    assert.ok(await js(`document.body.textContent.includes('Saved reply 23')`),'Revealing history keeps newer replies');
    assert.ok(await js(`document.querySelector('[data-chat-transcript]').scrollTop>0`),'Revealing history preserves the reading anchor');
    await js(`window.historyReplyCount=1;document.querySelector('[data-refresh-snapshot]').click()`);
    await wait(`document.querySelectorAll('article').length===1 && document.body.textContent.includes('Saved reply 0')`);
  }
  return result;
}
module.exports={historyPerformance};
