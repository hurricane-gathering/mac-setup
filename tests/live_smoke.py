#!/usr/bin/env python3
"""Opt-in real integration tests: isolated workspace, temporary Redis and ROS containers.
Does not install applications, alter shell files, replace databases or accept licenses.
"""
import pathlib,subprocess,os,json,time,socket,tempfile,concurrent.futures,shutil
BASE=pathlib.Path(__file__).resolve().parent
WORK=BASE/'live';WORK.mkdir(exist_ok=True)
results=[]
def run(args,*,cwd=None,env=None,timeout=180):
 p=subprocess.run(args,cwd=cwd,env=env,capture_output=True,text=True,timeout=timeout)
 if p.returncode: raise RuntimeError(' '.join(args[:3])+f' exit={p.returncode}\n'+p.stdout[-1000:]+p.stderr[-2000:])
 return p.stdout+p.stderr
def test(name,fn):
 start=time.monotonic()
 try: detail=fn();r=dict(test=name,ok=True,seconds=round(time.monotonic()-start,2),detail=detail)
 except Exception as e:r=dict(test=name,ok=False,seconds=round(time.monotonic()-start,2),detail=str(e))
 print(json.dumps(r,ensure_ascii=False),flush=True)
 return r
def uv():
 uv=shutil.which('uv'); py=shutil.which('python3.13') or shutil.which('python3')
 d=WORK/'python';d.mkdir(exist_ok=True)
 output=''
 if not (d/'pyproject.toml').exists(): output+=run([uv,'init','--bare','--python',py],cwd=d)
 if not (d/'.venv').exists():output+=run([uv,'venv','--python',py,'.venv'],cwd=d)
 output+=run([uv,'pip','install','--python',str(d/'.venv/bin/python'),'--index-url','https://pypi.org/simple/','packaging'],cwd=d)
 output+=run([str(d/'.venv/bin/python'),'-c','import packaging; print(packaging.__version__)'])
 return output

def redis():
 with tempfile.TemporaryDirectory(prefix='msredis-',dir='/private/tmp') as d:
  path=pathlib.Path(d); sock=path/'r.sock';config=path/'redis.conf'
  config.write_text(f'bind 127.0.0.1\nprotected-mode yes\nport 0\nunixsocket {sock}\nunixsocketperm 700\ndir {path}\nappendonly yes\ndaemonize no\n')
  log=open(path/'redis.log','w')
  p=subprocess.Popen([shutil.which('redis-server'),str(config)],stdout=log,stderr=log)
  try:
   for _ in range(50):
    if sock.exists():break
    if p.poll() is not None:raise RuntimeError((path/'redis.log').read_text())
    time.sleep(.1)
   output=run([shutil.which('redis-cli'),'-s',str(sock),'ping'])
   assert output.strip()=='PONG',output
   return output+'temporary Unix socket; public TCP disabled'
  finally:
   p.terminate();p.wait(timeout=10);log.close()

def ros():
 docker=shutil.which('docker');name='macsetup-smoke-'+str(os.getpid());ws=WORK/'ros2_ws';ws.mkdir(exist_ok=True)
 token='persist-'+str(time.time_ns());(ws/'probe').write_text(token)
 try:
  info=run([docker,'image','inspect','ros:jazzy-ros-base','--format','{{.Architecture}}'])
  assert info.strip()=='arm64',info
  output=run([docker,'run','-d','--name',name,'--network','none','--mount',f'type=bind,source={ws},target=/workspace/ros2_ws','-w','/workspace/ros2_ws','ros:jazzy-ros-base','sleep','infinity'])
  output+=run([docker,'exec',name,'bash','-lc','source /opt/ros/jazzy/setup.bash; ros2 --help; test "$ROS_DISTRO" = jazzy'])
  run([docker,'stop','-t','2',name]);run([docker,'start',name])
  assert run([docker,'exec',name,'cat','/workspace/ros2_ws/probe']).strip()==token
  run([docker,'rm','-f',name])
  assert run([docker,'run','--rm','--network','none','--mount',f'type=bind,source={ws},target=/workspace/ros2_ws','ros:jazzy-ros-base','cat','/workspace/ros2_ws/probe']).strip()==token
  return output+'\nstop/start and recreated-container bind persistence passed'
 finally:subprocess.run([docker,'rm','-f',name],capture_output=True)

def flutter():
 flutter=shutil.which('flutter');d=WORK/'flutter_smoke'
 output=''
 if not d.exists():output+=run([flutter,'create','--platforms=web',str(d)],timeout=180)
 start=time.monotonic();output+=run([flutter,'build','web'],cwd=d,timeout=300)
 assert (d/'build/web/index.html').exists()
 return f'build_seconds={time.monotonic()-start:.2f}\n'+output[-3500:]


def mysql():
 docker=shutil.which('docker'); name='macsetup-smoke-mysql-'+str(os.getpid());volume=name+'-data'
 run([docker,'volume','create',volume])
 env=dict(os.environ,MYSQL_ROOT_PASSWORD='root',MYSQL_PWD='root')
 args=[docker,'exec','-e','MYSQL_PWD',name,'mysql','--no-defaults','--protocol=tcp','-h','127.0.0.1','-u','root','-Nse','SELECT VERSION(),CURRENT_USER();']
 try:
  run([docker,'run','-d','--name',name,'--network','none','--mount',f'type=volume,source={volume},target=/var/lib/mysql','-e','MYSQL_ROOT_PASSWORD','mysql:8.4','--bind-address=127.0.0.1','--mysqlx=0','--innodb-buffer-pool-size=64M'],env=env)
  def ready():
   for _ in range(80):
    try:return run(args,env=env,timeout=4)
    except RuntimeError:time.sleep(.5)
   raise RuntimeError('MySQL did not become ready')
  out=ready();run([docker,'restart','-t','5',name]);out+=ready()
  return 'MySQL 8.4 isolated Docker SQL/TCP auth and restart persistence passed; native launchd not exercised.\n'+out
 finally:
  subprocess.run([docker,'rm','-f',name],capture_output=True)
  subprocess.run([docker,'volume','rm',volume],capture_output=True)

with concurrent.futures.ThreadPoolExecutor(max_workers=5) as pool:
 futures=[pool.submit(test,name,fn) for name,fn in [('mysql-isolated-engine',mysql),('uv-real-project',uv),('redis-native-isolated',redis),('ROS-real-container',ros),('flutter-real-web-build',flutter)]]
 results=[f.result() for f in futures]
(BASE/'live-results.json').write_text(json.dumps(results,ensure_ascii=False,indent=2))
raise SystemExit(0 if all(r['ok'] for r in results) else 1)
