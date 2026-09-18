#!/usr/bin/env python3
"""Live-model recipient selection and child delivery in an isolated workspace."""
import argparse
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import tempfile


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--graff', default='./zig-out/bin/graff')
    ap.add_argument('--model', default='gpt-6-astra')
    ap.add_argument('--reverse', action='store_true')
    ap.add_argument('--output', required=True, help='Private local evidence JSON')
    args = ap.parse_args()
    roles = ['layout', 'storage'] if args.reverse else ['storage', 'layout']
    prompt = f'''Run a small coordination test using exactly two real background subagents.
Launch the {roles[0]} worker FIRST, then the {roles[1]} worker. Use descriptions
"layout" and "storage", and run_in_background true. Do not pin different models.
Give each child ONLY this instruction, substituting its role:
"You are the ROLE worker. First run bash: while [ ! -f release-workers ]; do sleep 0.1; done
After this tool completes, read any parent feedback. Reply with your role followed
by the exact feedback text you actually received, or NO_FEEDBACK if none. Do not
write files or call other tools."
After both launches return, send this feedback ONLY to the worker responsible
for screen layout: LAYOUT_LIVE_NOTE: preserve keyboard focus.
Send this feedback ONLY to the worker responsible for persistence:
STORAGE_LIVE_NOTE: preserve transaction ordering.
Use agent_message with each recipient's actual returned numeric handle. Do not
include these feedback notes in spawn prompts and do not send either to both.
Once both messages are acknowledged, run bash "touch release-workers", then
collect both with agent_output (wait_ms 1). Finish with their two reports.
This is a bounded fixture; do not inspect the workspace, delegate other tasks,
create goals, use peer messaging, or perform network/tool work beyond this test.
'''
    binary = str(Path(args.graff).resolve())
    with tempfile.TemporaryDirectory(prefix='graff-live-routing-') as tmp:
        config = Path(tmp, 'mcp-empty.json')
        config.write_text('{"mcpServers":{}}')
        env = dict(os.environ, GRAFF_MCP_CONFIG=str(config), PWD=tmp, GRAFF_NO_TELEMETRY='1', GRAFF_FLEET='off',
                   GRAFF_NO_SMOLIFY='1', GRAFF_LEARNING_PRIVACY='local', NO_COLOR='1')
        argv = [binary, '--json', '--yolo', '--old', '--model', args.model,
                '--no-subagent-tier', '--max-model-calls', '28', '--max-tool-calls', '16', '--no-telemetry']
        proc = subprocess.Popen(argv, cwd=tmp, env=env, stdin=subprocess.PIPE,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                text=True, start_new_session=True)
        timed_out = False
        try:
            stdout, stderr = proc.communicate(json.dumps({'type':'user', 'text':prompt})+'\n', timeout=240)
        except subprocess.TimeoutExpired:
            timed_out = True
            Path(tmp, 'release-workers').touch()
            os.killpg(proc.pid, signal.SIGTERM)
            stdout, stderr = proc.communicate(timeout=10)
        events=[]
        for line in stdout.splitlines():
            try: events.append(json.loads(line))
            except ValueError: pass
        calls=[e for e in events if e.get('type')=='tool_call']
        results=[e for e in events if e.get('type')=='tool_result']
        sends=[e for e in calls if e.get('name')=='agent_message']
        reports=[e for e in results if e.get('name')=='agent_output']
        receipts={}
        for e in results:
            if e.get('name')=='subagent':
                for handle,label in re.findall(r'\[agent (\d+) started: ([^\]]+)\]', e.get('text','')):
                    receipts[label]=int(handle)
        checks={'two_launches':set(receipts)=={'layout','storage'},'two_messages':len(sends)==2,
                'two_reports':len(reports)==2,'clean_exit':proc.returncode==0, 'within_deadline':not timed_out}
        for role,other in [('layout','storage'),('storage','layout')]:
            note=role.upper()+'_LIVE_NOTE'; foreign=other.upper()+'_LIVE_NOTE'
            target=receipts.get(role)
            sent=[e for e in sends if note in json.dumps(e.get('input',{}))]
            checks[role+'_recipient']=len(sent)==1 and sent[0].get('input',{}).get('id')==target and target is not None
            matched=[e for e in reports if re.search(r'\[agent '+str(target)+r': completed(?: in |\])',e.get('text',''))]
            checks[role+'_isolated_report']=len(matched)==1 and note in matched[0].get('text','') and foreign not in matched[0].get('text','') and not matched[0].get('is_error')
        evidence={'model':args.model,'order':roles,'checks':checks,'events':events,'stderr':stderr,'exit_code':proc.returncode}
        dest=Path(args.output); dest.parent.mkdir(parents=True,exist_ok=True)
        fd=os.open(dest,os.O_WRONLY|os.O_CREAT|os.O_TRUNC,0o600)
        with os.fdopen(fd,'w') as f: json.dump(evidence,f,indent=2)
        print(json.dumps({'model':args.model,'order':roles,'checks':checks,'events':len(events),'evidence':str(dest)},indent=2))
        if not all(checks.values()):
            print('FAIL: inspect private evidence for routing failure or startup errors')
            raise SystemExit(1)
        print('PASS: live model selected both intended recipients and both reports contain only their own feedback')

if __name__=='__main__': main()
