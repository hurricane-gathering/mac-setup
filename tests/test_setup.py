#!/usr/bin/env python3
"""Exercise the real Bash entrypoint with fake external installers in a temporary HOME.
No application, service or real developer configuration is changed.
"""
import os, pathlib, subprocess, tempfile, json, time, zipfile, hashlib, plistlib
BASE=pathlib.Path(__file__).resolve().parents[1]
SOURCE=(BASE/'scripts/setup.sh').read_text()
MOCK=r'''#!/usr/bin/env python3
import os,sys,pathlib,json
cmd=pathlib.Path(sys.argv[0]).name; a=sys.argv[1:]
# Optional shared-clock event trace; one append syscall per record for concurrency safety.
import time,atexit
trace=os.environ.get('MOCK_TRACE')
def emit(phase):
 if trace:
  event=dict(phase=phase,pid=os.getpid(),cmd=cmd,args=a,time=time.time())
  fd=os.open(trace,os.O_WRONLY|os.O_CREAT|os.O_APPEND,0o600)
  os.write(fd,(json.dumps(event)+'\n').encode());os.close(fd)
emit('start');atexit.register(emit,'end')
if os.environ.get('MOCK_DELAY'):
 delay=0
 if cmd=='flutter' and a[:1]==['build']:delay=1.6
 elif cmd=='uv' and a[:2]==['pip','install']:delay=1.2
 elif cmd=='brew' and a[:1]==['install']:delay=.10
 elif cmd=='brew' and a[:1]==['fetch']:delay=.4
 elif cmd=='redis-cli':delay=.2
 if delay:time.sleep(delay)
if os.environ.get('MOCK_STALL') and cmd=='flutter' and a[:1]==['build']:
 import subprocess
 child=subprocess.Popen(['/bin/sleep','30'])
 pathlib.Path(os.environ['MOCK_STALL']).write_text(str(child.pid))
 child.wait()
h=pathlib.Path(os.environ['HOME']); root=h/'Developer/mac-setup'; prefix=pathlib.Path(os.environ['MOCK_PREFIX']); state=prefix/'mockstate'; state.mkdir(exist_ok=True)
if cmd=='brew':
 if a==['shellenv']: print('export PATH="'+str(prefix/'bin')+':$PATH"')
 elif a==['--prefix']: print(prefix)
 elif a[:2]==['list','--formula']: sys.exit(0 if (state/a[-1]).exists() else 1)
 elif a[:1]==['install']:
  if os.environ.get('MOCK_PERMISSION_FORMULA')==a[-1]: print('Error: Permission denied @ dir_s_mkdir - mock/ruby');sys.exit(1)
  if os.environ.get('MOCK_NETWORK_FORMULA')==a[-1] and not (state/'network-once').exists():
   (state/'network-once').touch();print('curl: (6) Could not resolve host');sys.exit(1)
  (state/a[-1]).touch()
  if a[-1]=='mysql@8.4' and not (prefix/'bin/mysql').exists(): (prefix/'bin/mysql').symlink_to(prefix/'bin/mock')
 elif a==['doctor'] and os.environ.get('MOCK_DOCTOR_FAIL'): print('Error: doctor failed');sys.exit(1)
 elif a==['doctor'] and os.environ.get('MOCK_DOCTOR_WARN'): print('Warning: You have unlinked kegs: ruby');sys.exit(1)
 elif a[:1]==['deps']: print('runtime-lib')
 elif a[:2]==['services','list']: print('Name Status User File')
 else: print('mock brew verified')
elif cmd=='uname': print('Darwin' if a==['-s'] else 'arm64')
elif cmd=='sysctl': print('0' if 'sysctl.proc_translated' in a else 'Mock Apple Silicon')
elif cmd=='df': print('Filesystem 1024-blocks Used Available Capacity Mounted\nmock 100000000 1000 90000000 1% /')
elif cmd=='sw_vers': print('mock macOS')
elif cmd=='xcode-select':
 if os.environ.get('MOCK_CLT_MISSING'): sys.exit(1)
 print('/mock/Xcode')
elif cmd=='xcrun': print('/mock/clang')
elif cmd=='curl':
 if '-w' in a: print('0.01' if 'formulae.brew.sh' in a[-1] or 'pypi.org' in a[-1] or 'googleapis.com' in a[-1] or 'pub.dev' in a[-1] else '0.02',end='')
 else:
  import shutil
  if os.environ.get('MOCK_DOWNLOAD'):
   src=os.environ['MOCK_META'] if any('releases_macos.json' in arg for arg in a) else os.environ['MOCK_ARCHIVE']
   shutil.copyfile(src,a[a.index('-o')+1])
  else:sys.exit(22)
elif cmd=='git': print('mock git')
elif cmd=='lsof':
 if '-Fn' in a:
  port=next(arg.split(':')[-1] for arg in a if arg.startswith('-iTCP:'))
  print('p123\nn'+('0.0.0.0:' if os.environ.get('MOCK_EXPOSED') else '127.0.0.1:')+port)
 else:sys.exit(1)
elif cmd=='sleep':time.sleep(min(float(a[0]),.02))
elif cmd in ('open','launchctl'):pass
elif cmd=='mysqld':
 if '--initialize-insecure' in a:
  (root/'state/mysql/mysql').mkdir(parents=True,exist_ok=True)
  import socket
  s=socket.socket(socket.AF_UNIX);s.bind(str(root/'state/mysql.sock'));s.close()
elif cmd=='mysql':
 if os.environ.get('MOCK_MYSQL_AUTH_FAIL'):print('Access denied');sys.exit(1)
 print('mock SQL success')
elif cmd=='redis-server': pass
elif cmd=='redis-cli': print('PONG')
elif cmd=='docker':
 if a[:2]==['image','inspect']: print('arm64')
 elif a[:2]==['container','inspect']: sys.exit(0 if (state/'ros').exists() else 1)
 elif a[:1]==['inspect']: print(str(h/'Developer/ros2_ws')+' /workspace/ros2_ws')
 elif a[:1]==['run']: (state/'ros').touch()
 elif a[:1]==['exec'] and 'cat' in a: print((h/'Developer/ros2_ws/.macsetup-persistence').read_text())
 else: print('mock docker success')
elif cmd=='uv':
 if a[:2]==['pip','install'] and os.environ.get('MOCK_UV_FAIL'):sys.exit(1)
 if a[:1]==['init']: pathlib.Path('pyproject.toml').touch()
 elif a[:1]==['venv']:
  p=pathlib.Path('.venv/bin/python'); p.parent.mkdir(parents=True,exist_ok=True);p.write_text('#!/bin/sh\necho mock-packaging\n');p.chmod(0o700)
 else: print('mock uv')
elif cmd=='flutter':
 if a[:1]==['create']: pathlib.Path(a[-1]).mkdir(parents=True,exist_ok=True)
 elif a[:1]==['build'] and os.environ.get('MOCK_BUILD_FAIL'): sys.exit(1)
 else: print('mock flutter')
elif cmd in ('node','npm','dart','pod'): print('mock '+cmd+' version')
elif cmd in ('fzf','starship'): pass
else: print('unhandled mock',cmd,a);sys.exit(1)
'''
results=[]
def check(label, value, detail=''):
 if not value: raise AssertionError(label+': '+detail)
 results.append(label);print('PASS',label)
for f in list((BASE/'scripts').glob('*.sh'))+list((BASE/'docker').glob('*.sh')):
 p=subprocess.run(['/bin/bash','-n',str(f)],capture_output=True,text=True)
 check('syntax '+f.name,p.returncode==0,p.stderr)
with tempfile.TemporaryDirectory(prefix='mst-',dir='/private/tmp') as temp:
 t=pathlib.Path(temp);home=t/'h';home.mkdir();prefix=t/'p';(prefix/'bin').mkdir(parents=True)
 mock=prefix/'bin/mock';mock.write_text(MOCK);mock.chmod(0o700)
 for name in ['brew','uname','sysctl','df','sw_vers','xcode-select','xcrun','curl','git','lsof','open','sleep','launchctl','redis-cli','docker','uv','flutter','dart','node','npm','fzf','starship','pod']:
  (prefix/'bin'/name).symlink_to(mock)
 for name,binary in [('python@3.13','python3.13'),('redis','redis-server'),('mysql@8.4','mysqld')]:
  d=prefix/'opt'/name/'bin';d.mkdir(parents=True)
  (d/binary).symlink_to(os.path.realpath(os.sys.executable) if name=='python@3.13' else mock)
 apps=t/'Applications';apps.mkdir()
 # Redirect absolute installation locations in the TEST COPY, keep production script unchanged.
 transformed=SOURCE.replace('/opt/homebrew',str(prefix)).replace('/Applications/',str(apps)+'/').replace('/usr/local/mysql/data',str(t/'oldmysql'))
 package=t/'package';(package/'scripts').mkdir(parents=True)
 entry=package/'scripts/setup.sh';entry.write_text(transformed)
 (package/'README.md').write_text('fixture documentation')
 env=dict(os.environ,HOME=str(home),PATH=str(prefix/'bin')+':/usr/bin:/bin:/usr/sbin:/sbin',MOCK_PREFIX=str(prefix))
 def run(extra=None,path=entry):
  p=subprocess.run(['/bin/bash',str(path),'auto'],env=dict(env,**(extra or {})),text=True,errors="replace",stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=60)
  (BASE/'tests'/('last-mock-run.log')).write_text(p.stdout)
  return p
 p=run();check('full fresh mock run',p.returncode==0,p.stdout[-5000:])
 root=home/'Developer/mac-setup'
 report=next((root/'logs').glob('*.tsv')).read_text()
 check('fresh database initialization executed','MySQL\t成功' in report and 'Redis\t成功' in report,report)
 check('ROS verification reached','ROS重建持久化\t成功' in report,report)
 p=run(path=root/'scripts/setup.sh');check('rerun installed entrypoint',p.returncode==0,p.stdout[-5000:])
 for service in ['mysql','redis']:
  plist=home/'Library/LaunchAgents'/('local.macsetup.'+service+'.plist')
  conf=plistlib.loads(plist.read_bytes())
  check('launchd plist '+service,conf['RunAtLoad'] and conf['KeepAlive'] and pathlib.Path(conf['ProgramArguments'][0]).is_absolute())

 for name in ['.zprofile','.zshrc']:
  lines=(home/name).read_text().splitlines();active=[x for x in lines if x.strip()]
  check('no duplicate source lines '+name,len(active)==len(set(active)))
 old=(root/'configs/env.zsh').read_bytes()
 p=run({'MOCK_CLT_MISSING':'1'});check('CLT exit code',p.returncode==3,p.stdout)
 check('early failure preserves env',old==(root/'configs/env.zsh').read_bytes())
 p=run({'MOCK_BUILD_FAIL':'1'});check('failed web build gives failure exit',p.returncode==1,p.stdout[-2000:])
 check('lock cleaned after failed run',not (root/'state/lock').exists())
 p=run({'MOCK_UV_FAIL':'1'});check('uv install failure propagates to report',p.returncode==1,p.stdout[-2000:])
 for svc in ['mysql','redis']:(root/('state/'+svc+'-owned')).unlink()
 (prefix/'var/mysql/mysql').mkdir(parents=True)
 p=run();check('preexisting database skip',p.returncode==0,p.stdout[-3000:])
 latest=max((root/'logs').glob('*.tsv'),key=lambda p:p.stat().st_mtime_ns).read_text()
 check('existing MySQL is not reset','MySQL\t成功' in latest,latest)
 check('existing Redis is preserved','Redis\t成功' in latest,latest)

 p=run({'MOCK_DOCTOR_WARN':'1'});check('doctor warnings do not fail setup',p.returncode==0,p.stdout[-1500:])
 latest=max((root/'logs').glob('*.tsv'),key=lambda p:p.stat().st_mtime_ns).read_text()
 check('doctor warnings remain visible','Homebrew doctor\t部分完成' in latest,latest)
 p=run({'MOCK_DOCTOR_FAIL':'1'});check('doctor real errors still fail',p.returncode==1,p.stdout[-1500:])
 p=run({'MOCK_MYSQL_AUTH_FAIL':'1'});check('existing password is never reset',p.returncode==0,p.stdout[-1500:])
 latest=max((root/'logs').glob('*.tsv'),key=lambda p:p.stat().st_mtime_ns).read_text()
 check('existing auth mismatch requests manual action','MySQL\t待人工操作' in latest,latest)
 p=run({'MOCK_EXPOSED':'1'});check('public listener fails validation',p.returncode==1,p.stdout[-1500:])
 latest=max((root/'logs').glob('*.tsv'),key=lambda p:p.stat().st_mtime_ns).read_text()
 check('public listener reported explicitly','MySQL监听\t失败' in latest and 'Redis监听\t失败' in latest,latest)
 # A local permission error must not masquerade as a mirror outage or trigger a retry.
 (prefix/'mockstate/git').unlink();permission_trace=t/'permission.jsonl'
 p=run({'MOCK_PERMISSION_FORMULA':'git','MOCK_TRACE':str(permission_trace)})
 check('permission error remains a hard failure',p.returncode==1,p.stdout[-1500:])
 events=[json.loads(line) for line in permission_trace.read_text().splitlines()]
 attempts=[e for e in events if e['phase']=='start' and e['cmd']=='brew' and e['args']==['install','git']]
 check('permission error never retries another mirror',len(attempts)==1,str(attempts))
 latest=max((root/'logs').glob('*.tsv'),key=lambda p:p.stat().st_mtime_ns).read_text()
 check('permission report gives an actionable cause','本地权限/链接错误' in latest and 'sudo/chown' in latest,latest)
 fetches=[e for e in events if e['phase']=='start' and e['cmd']=='brew' and e['args'][:1]==['fetch'] and '--formula' in e['args']]
 check('prefetch excludes source build dependencies',bool(fetches) and all('--deps' not in e['args'] and 'runtime-lib' in e['args'] for e in fetches),str(fetches))
 network_trace=t/'network.jsonl';p=run({'MOCK_NETWORK_FORMULA':'git','MOCK_TRACE':str(network_trace)})
 check('transient network fallback recovers',p.returncode==0,p.stdout[-1500:])
 events=[json.loads(line) for line in network_trace.read_text().splitlines()]
 attempts=[e for e in events if e['phase']=='start' and e['cmd']=='brew' and e['args']==['install','git']]
 check('network error retries exactly once',len(attempts)==2,str(attempts))
 check('working CocoaPods is reused without Ruby upgrade',not any(e['phase']=='start' and e['cmd']=='brew' and e['args']==['install','cocoapods'] for e in events))
 # Cover SDK metadata -> architecture -> checksum -> actual ditto extraction.
 (prefix/'bin/flutter').unlink();(prefix/'bin/dart').unlink()
 archive=t/'flutter.zip'
 with zipfile.ZipFile(archive,'w') as z:
  for binary in ['flutter','dart']:
   info=zipfile.ZipInfo('flutter/bin/'+binary);info.create_system=3;info.external_attr=0o100755<<16
   z.writestr(info,MOCK)
 sha=hashlib.sha256(archive.read_bytes()).hexdigest()
 meta=t/'releases.json';meta.write_text(json.dumps({'current_release':{'stable':'fixture'},'releases':[{'hash':'fixture','dart_sdk_arch':'arm64','archive':'stable/macos/fixture.zip','sha256':sha}]}))
 extra={'MOCK_DOWNLOAD':'1','MOCK_META':str(meta),'MOCK_ARCHIVE':str(archive)}
 p=run(extra);check('fresh Flutter SDK download and checksum',p.returncode==0,p.stdout[-4000:])
 check('SDK extraction executable',(home/'Developer/flutter/bin/flutter').stat().st_mode&0o111)

 # Trace real command invocations to verify DAG overlap, not just the use of '&'.
 def intervals(path):
  events=[json.loads(line) for line in path.read_text().splitlines()]
  starts={e['pid']:e for e in events if e['phase']=='start'}
  return [(starts[e['pid']],e['time']) for e in events if e['phase']=='end' and e['pid'] in starts]
 def overlaps(x,y):return max(x[0]['time'],y[0]['time'])<min(x[1],y[1])
 def select(rows,cmd,prefix):return [r for r in rows if r[0]['cmd']==cmd and r[0]['args'][:len(prefix)]==prefix]
 parallel_trace=t/'parallel.jsonl';serial_trace=t/'serial.jsonl'
 start=time.monotonic();p=run({'MOCK_TRACE':str(parallel_trace),'MOCK_DELAY':'1','MAC_SETUP_JOBS':'6'});parallel_seconds=time.monotonic()-start
 check('parallel DAG completes',p.returncode==0,p.stdout[-2500:])
 rows=intervals(parallel_trace)
 web=select(rows,'flutter',['build','web']);py=select(rows,'uv',['pip','install']);installs=select(rows,'brew',['install'])
 check('Flutter and uv actually overlap',any(overlaps(a,b) for a in web for b in py))
 check('Flutter overlaps foreground app install',any(overlaps(a,b) for a in web for b in installs))
 check('Homebrew installs never overlap',all(not overlaps(a,b) for i,a in enumerate(installs) for b in installs[i+1:]),json.dumps(installs,ensure_ascii=False))
 fetches=select(rows,'brew',['fetch'])
 check('independent prefetch batches overlap',any(overlaps(a,b) for i,a in enumerate(fetches) for b in fetches[i+1:]))
 latest_dir=max((root/'logs').glob('*-jobs'),key=lambda p:p.stat().st_mtime_ns)
 reports=list(latest_dir.glob('*.tsv'))
 check('workers have separate reports and logs',len(reports)>=8 and (latest_dir/'timeline.tsv').exists() and (latest_dir/'flutter-web.log').exists())
 timeline=(latest_dir/'timeline.tsv').read_text().splitlines()
 check('each task timeline is recorded',len(timeline)>=9 and all(len(row.split('\t'))==4 for row in timeline))
 start=time.monotonic();p=run({'MOCK_TRACE':str(serial_trace),'MOCK_DELAY':'1','MAC_SETUP_JOBS':'1'});serial_seconds=time.monotonic()-start
 check('serial compatibility mode',p.returncode==0,p.stdout[-2000:])
 serial_rows=intervals(serial_trace)
 check('serial mode has no Flutter/uv overlap',all(not overlaps(a,b) for a in select(serial_rows,'flutter',['build','web']) for b in select(serial_rows,'uv',['pip','install'])))
 (BASE/'tests/parallel-results.json').write_text(json.dumps(dict(parallel_seconds=round(parallel_seconds,3),serial_seconds=round(serial_seconds,3),simulated_workload=True,reason='controlled mock command delays; not an estimate of fresh Mac installation'),indent=2)+'\n')
 # Invalid budgets must be rejected before touching runtime state.
 p=run({'MAC_SETUP_JOBS':'9'});check('out-of-range worker budget rejected',p.returncode==2,p.stdout)
 p=run({'MAC_SETUP_DOWNLOADS':'0'});check('invalid download budget rejected',p.returncode==2,p.stdout)
 # Cancellation must terminate descendants and release the install lock.
 import signal
 stall=t/'stall-pid';out=t/'cancel.log'
 with out.open('w') as output:
  child=subprocess.Popen(['/bin/bash',str(entry),'auto'],env=dict(env,MAC_SETUP_JOBS='6',MOCK_STALL=str(stall)),stdout=output,stderr=subprocess.STDOUT)
  try:
   until=time.monotonic()+15
   while not stall.exists() and time.monotonic()<until:time.sleep(.05)
   check('cancellation reaches active descendant',stall.exists(),out.read_text()[-1500:])
   descendant=int(stall.read_text());child.send_signal(signal.SIGTERM);child.wait(timeout=8)
   check('TERM preserves interrupted exit code',child.returncode==143,str(child.returncode))
   check('TERM releases global lock',not (root/'state/lock').exists())
   alive=True
   for _ in range(40):
    try:os.kill(descendant,0)
    except ProcessLookupError:alive=False;break
    time.sleep(.05)
   check('TERM kills nested download/process',not alive,str(descendant))
  finally:
   if child.poll() is None:child.kill();child.wait()
 import shutil
 shutil.rmtree(home/'Developer/flutter')
 fixture=json.loads(meta.read_text());fixture['releases'][0]['sha256']='0'*64;meta.write_text(json.dumps(fixture))
 env_before=(root/'configs/env.zsh').read_bytes()
 p=run(extra);check('bad SDK checksum stops installation',p.returncode!=0,p.stdout[-2000:])
 check('checksum failure preserves active env',(root/'configs/env.zsh').read_bytes()==env_before)
 check('checksum failure never extracts SDK',not (home/'Developer/flutter').exists())


 (root/'state/lock').mkdir();p=run();check('concurrent lock rejected',p.returncode==2,p.stdout);(root/'state/lock').rmdir()
 p=subprocess.run(['/bin/bash',str(entry),'invalid'],env=env,capture_output=True,text=True)
 check('invalid mode rejected',p.returncode==2)
with tempfile.TemporaryDirectory(prefix='mschoose-',dir='/private/tmp') as temp:
 choose=SOURCE[SOURCE.index('choose() {'):SOURCE.index('\nruncheck()')]
 stub='curl() { case "${@: -1}" in https://official/*) printf 5000;; *) printf 9000;; esac; }'
 for mode,expected in [('auto','https://mirror'),('cn','https://mirror'),('global','https://official')]:
  script='TMP='+temp+'\nMODE='+mode+'\n'+stub+'\n'+choose+'\nchoose_transfer /archive https://official https://mirror'
  out=subprocess.check_output(['/bin/bash','-c',script],text=True)
  check('SDK throughput selector '+mode,out==expected,out)
fixture=BASE/'tests/flutter-releases-live.json'
if fixture.exists():
 import re
 code=re.search(r"<<'PY'\n(import json,sys.*?)(?:\nPY)",SOURCE,re.S).group(1)
 for arch,fragment in [('arm64','arm64'),('x86_64','flutter_macos_')]:
  out=subprocess.check_output([os.sys.executable,'-c',code,str(fixture),arch],text=True).splitlines()
  check('live release parser '+arch,len(out)==2 and fragment in out[0] and len(out[1])==64)
with tempfile.TemporaryDirectory(prefix='msios-',dir='/private/tmp') as temp:
 t=pathlib.Path(temp);(t/'apps/Xcode.app').mkdir(parents=True);(t/'root/state/flutter_smoke').mkdir(parents=True)
 stage=SOURCE[SOURCE.index('stage_flutter_platforms() {'):SOURCE.index('\nrecord "Homebrew 源"')].replace('/Applications/',str(t/'apps')+'/')
 for available in [True,False]:
  report=t/('ios-'+str(available)+'.tsv')
  stub="flutter() { return 0; }\nxcrun() { printf '%s\\n' '"+('iOS 26.5 - runtime-id' if available else '== Runtimes ==')+"'; }"
  script='set -Eeuo pipefail\nROOT='+str(t/'root')+'\nTMP='+str(t)+'\nHOME='+str(t)+'\nREPORT='+str(report)+"\nrecord() { printf '%s\\t%s\\t%s\\n' \"$1\" \"$2\" \"$3\" >> \"${REPORT}\"; }\n"+stub+'\n'+stage+'\nstage_flutter_platforms'
  out=subprocess.run(['/bin/bash','-c',script],capture_output=True,text=True)
  check('iOS existing Xcode '+('runtime ready' if available else 'runtime missing'),out.returncode==0 and ('iOS\t部分完成' if available else '完整 Xcode 已存在') in report.read_text(),out.stdout+out.stderr)
print(json.dumps({'passed':len(results),'tests':results},ensure_ascii=False,indent=2))
