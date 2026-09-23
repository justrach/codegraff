#!/usr/bin/env python3
"""Offline ACP regression: a positive agent_output wait consumes one model turn."""
import importlib.util
import json
import re
import sys
import tempfile
import threading
import time
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('acp_load', REPO / 'scripts/test-acp-session-load.py')
load = importlib.util.module_from_spec(spec)
spec.loader.exec_module(load)


def tool_names(body):
    return [item.get('function', item).get('name') for item in body.get('tools', [])]


def wait_for_tool(client, title, timeout=5):
    deadline=time.monotonic()+timeout
    while time.monotonic()<deadline:
        if any(e.get('method')=='session/update' and
               e.get('params',{}).get('update',{}).get('sessionUpdate')=='tool_call' and
               e.get('params',{}).get('update',{}).get('title')==title for e in client.events):
            return
        time.sleep(.01)
    raise AssertionError(f'ACP {title} tool call did not start')


class DelayedChild(load.ScriptedModel):
    def __init__(self, delay=1.0, wait_ms=600000):
        super().__init__([], exhausted_text='unexpected extra model turn')
        self.delay = delay
        self.wait_ms = wait_ms
        self.wait_requested = threading.Event()
        self.third_root_call = threading.Event()
        self.child_started = threading.Event()
        self.child_finished = threading.Event()
        self.release_child = threading.Event() if delay is None else None
        self.root_calls = 0
        self.child_calls = 0
        self.aux_calls = 0
        self.wait_result = None

    def next_reply(self, body):
        with self._lock:
            self.requests.append(body)
            names=tool_names(body)
            if not names:
                self.aux_calls += 1
                kind, number = 'aux', self.aux_calls
            elif 'subagent' in names:
                self.root_calls += 1
                kind, number = 'root', self.root_calls
                if number >= 3:
                    self.third_root_call.set()
            else:
                self.child_calls += 1
                kind, number = 'child', self.child_calls
        if kind == 'child':
            self.child_started.set()
            if self.release_child is not None:
                assert self.release_child.wait(10), 'held child was not released'
            else:
                time.sleep(self.delay)
            self.child_finished.set()
            return {'text': 'child completed the local task'}
        if kind == 'aux':
            return {'text':'Local task'}
        if number == 1:
            return {'tool':'subagent','arguments':{
                'description':'Check local task','prompt':'Return a short completion report.',
                'isolation':'shared_cwd','run_in_background':True}}
        if number == 2:
            last = load.tool_text(body)[-1]
            found = re.search(r'\[agent (\d+)', last)
            assert found, 'missing background agent handle'
            self.wait_requested.set()
            return {'tool':'agent_output','arguments':{'id':int(found.group(1)),'wait_ms':self.wait_ms}}
        if number == 3:
            self.wait_result = load.tool_text(body)[-1]
            return {'text':'Parent observed completion.'}
        return {'text':'unexpected extra model turn'}


def run(binary):
    with tempfile.TemporaryDirectory(prefix='graff-acp-agent-wait-') as tmp:
        work=Path(tmp); home=work/'home'; home.mkdir()
        model=DelayedChild(delay=None); port=model.start(0)
        client=load.Acp(binary,work,home,port,extra_env={'GRAFF_NO_NATIVE_FOLD':'1'},
                        extra_args=('--max-model-calls','5','--max-run-tool-calls','8'))
        prompt_result={}
        prompt_thread=None
        try:
            client.request('initialize',{'protocolVersion':1})
            created=client.request('session/new',{'cwd':str(work),'mcpServers':[]})
            sid=created['result']['sessionId']
            def prompt():
                try:
                    prompt_result['response']=client.request('session/prompt',{'sessionId':sid,
                        'prompt':[{'type':'text','text':'Delegate once, wait for completion, then finish.'}]},timeout=15)
                except BaseException as exc:
                    prompt_result['error']=exc
            prompt_thread=threading.Thread(target=prompt,daemon=True); prompt_thread.start()
            assert model.child_started.wait(5), 'child did not start'
            assert model.wait_requested.wait(5), 'parent did not request agent_output'
            wait_for_tool(client,'agent_output')
            assert not model.child_finished.is_set(), 'child was not held during wait'
            assert not model.third_root_call.wait(.3), 'parent spent an extra model turn before child release'
            model.release_child.set()
            prompt_thread.join(timeout=10)
            assert not prompt_thread.is_alive(), 'ACP prompt did not finish after child release'
            assert 'error' not in prompt_result,prompt_result
            done=prompt_result['response']
            assert done['result']['stopReason']=='end_turn',done
        finally:
            model.release_child.set()
            if prompt_thread: prompt_thread.join(timeout=2)
            client.close(); model.stop()
        assert (model.root_calls,model.child_calls)==(3,1),\
            (model.root_calls,model.child_calls,model.aux_calls,[tool_names(body) for body in model.requests])
        assert model.wait_result and 'completed' in model.wait_result.lower(),model.wait_result
        assert '[agent 1: running]' not in model.wait_result.lower(),model.wait_result
        print('ACP agent_output positive wait returned completed held child; 3 root + 1 child model calls')


def run_snapshot(binary):
    with tempfile.TemporaryDirectory(prefix='graff-acp-agent-snapshot-') as tmp:
        work=Path(tmp); home=work/'home'; home.mkdir()
        model=DelayedChild(delay=None,wait_ms=0); port=model.start(0)
        client=load.Acp(binary,work,home,port,extra_env={'GRAFF_NO_NATIVE_FOLD':'1'},
                        extra_args=('--max-model-calls','5','--max-run-tool-calls','8'))
        try:
            client.request('initialize',{'protocolVersion':1})
            sid=client.request('session/new',{'cwd':str(work),'mcpServers':[]})['result']['sessionId']
            response=client.request('session/prompt',{'sessionId':sid,'prompt':[{'type':'text','text':'Delegate and snapshot.'}]},timeout=10)
            assert response.get('result',{}).get('stopReason')=='end_turn',response
            updates=[e.get('params',{}).get('update',{}) for e in client.events if e.get('method')=='session/update']
            assert any('[agent 1: running]' in json.dumps(u) for u in updates), 'zero-wait lost running snapshot'
            assert model.child_started.is_set() and not model.child_finished.is_set(), 'snapshot waited for child exit'
        finally:
            model.release_child.set()
            client.close(); model.stop()
        print('ACP agent_output zero wait returned running snapshot before held child exited')


def run_cancel(binary):
    with tempfile.TemporaryDirectory(prefix='graff-acp-agent-cancel-') as tmp:
        work=Path(tmp); home=work/'home'; home.mkdir()
        model=DelayedChild(delay=None); port=model.start(0)
        # Cancelling the client can close its SSE socket while the held child
        # emits its terminal frame; that expected disconnect is not a failure.
        model._server.handle_error=lambda *_: None
        client=load.Acp(binary,work,home,port,extra_env={'GRAFF_NO_NATIVE_FOLD':'1'},
                        extra_args=('--max-model-calls','5','--max-run-tool-calls','8'))
        cancel_thread=None
        cancel_errors=[]
        try:
            client.request('initialize',{'protocolVersion':1})
            sid=client.request('session/new',{'cwd':str(work),'mcpServers':[]})['result']['sessionId']
            def cancel():
                try:
                    assert model.wait_requested.wait(5), 'agent_output was not requested'
                    assert model.child_started.wait(5), 'child was not running'
                    wait_for_tool(client,'agent_output')
                    time.sleep(.2)
                    client.proc.stdin.write((json.dumps({'jsonrpc':'2.0','method':'session/cancel',
                        'params':{'sessionId':sid}})+'\n').encode())
                    client.proc.stdin.flush()
                except BaseException as exc:
                    cancel_errors.append(exc)
            cancel_thread=threading.Thread(target=cancel,daemon=True); cancel_thread.start()
            response=client.request('session/prompt',{'sessionId':sid,'prompt':[{'type':'text','text':'Delegate then wait.'}]},timeout=10)
            assert response.get('result',{}).get('stopReason')=='cancelled',response
            assert not model.child_finished.is_set(), 'cancel waited for child exit'
        finally:
            if cancel_thread: cancel_thread.join(timeout=2)
            model.release_child.set()
            client.close(); model.stop()
        assert not cancel_errors,cancel_errors
        print('ACP session/cancel interrupted positive wait before held child exited')


if __name__=='__main__':
    binary=Path(sys.argv[1] if len(sys.argv)>1 else REPO/'zig-out/bin/graff').resolve()
    run(binary)
    run_snapshot(binary)
    run_cancel(binary)
