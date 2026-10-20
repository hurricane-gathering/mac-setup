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
h=pathlib.Path(os.environ['HOME']); root=h/'Developer/mac-setup'; prefix=pathlib.Path(os.environ['MOCK_PREFIX']); state=prefix/'mockstate'; state.mkdir(exist_ok=True)
if cmd=='brew':
 if a==['shellenv']: print('export PATH="'+str(prefix/'bin')+':$PATH"')
 elif a==['--prefix']: print(prefix)
 elif a[:2]==['list','--formula']: sys.exit(0 if (state/a[-1]).exists() else 1)
 elif a[:1]==['install']:
  (state/a[-1]).touch()
  if a[-1]=='mysql@8.4' and not (prefix/'bin/mysql').exists(): (prefix/'bin/mysql').symlink_to(prefix/'bin/mock')
 elif a==['doctor'] and os.environ.get('MOCK_DOCTOR_FAIL'): sys.exit(1)
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
elif cmd=='lsof': sys.exit(1)
elif cmd in ('open','sleep','launchctl'): pass
elif cmd=='mysqld':
 if '--initialize-insecure' in a:
  (root/'state/mysql/mysql').mkdir(parents=True,exist_ok=True)
  import socket
  s=socket.socket(socket.AF_UNIX);s.bind(str(root/'state/mysql.sock'));s.close()
elif cmd=='mysql': print('mock SQL success')
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
elif cmd in ('node','npm','dart'): print('mock '+cmd+' version')
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
 for name in ['brew','uname','sysctl','df','sw_vers','xcode-select','xcrun','curl','git','lsof','open','sleep','launchctl','redis-cli','docker','uv','flutter','dart','node','npm','fzf','starship']:
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
  p=subprocess.run(['/bin/bash',str(path),'auto'],env=dict(env,**(extra or {})),text=True,errors="replace",stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=25)
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
 check('existing MySQL is not reset','MySQL\t待人工操作' in latest,latest)
 check('existing Redis is preserved','Redis\t部分完成' in latest,latest)
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
print(json.dumps({'passed':len(results),'tests':results},ensure_ascii=False,indent=2))
