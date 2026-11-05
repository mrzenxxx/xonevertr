import struct, subprocess, pathlib, base64, random, math, shutil
p=pathlib.Path(__file__).resolve().parent
ffmpeg=shutil.which('ffmpeg')
assert ffmpeg, 'ffmpeg is needed only to regenerate test fixtures'
for bits,ch,rate in [(16,1,22050),(24,2,48000)]:
    raw=bytearray()
    for i in range(32768):
        for c in range(ch):
            v=[-(1<<(bits-1)),(1<<(bits-1))-1,0,-1,1,12345,-12345][(i+c)%7]
            raw+=int(v).to_bytes(bits//8,'little',signed=True)
    (p/f'pcm{bits}.raw').write_bytes(raw)
    subprocess.run([ffmpeg,'-hide_banner','-loglevel','error','-y','-f',f's{bits}le','-ar',str(rate),'-ac',str(ch),'-i',str(p/f'pcm{bits}.raw'),'-c:a','flac',str(p/f'pcm{bits}.flac')],check=True)
cover=base64.b64decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aOioAAAAASUVORK5CYII=')
(p/'cover.png').write_bytes(cover)
f=p/'pcm24.flac'; data=f.read_bytes(); off=4; blocks=[]
while True:
    h=data[off:off+4]; n=int.from_bytes(h[1:],'big'); block=data[off+4:off+4+n]; off+=4+n
    if h[0]&127 not in (4,6): blocks.append((h[0]&127,block))
    if h[0]&128: break
comments=['TITLE=Тестовый трек','ARTIST=Archi Gene','ALBUM=Fixture Album','ALBUMARTIST=Various Artists','DATE=2026-11-03','GENRE=Techno','TRACKNUMBER=7','TRACKTOTAL=12','ORGANIZATION=Fixture Label','BPM=138','INITIALKEY=8A','CUSTOM_FIELD=Exact value']
v=b'xonevertr tests'; b=struct.pack('<I',len(v))+v+struct.pack('<I',len(comments))
for c in comments:
    c=c.encode(); b+=struct.pack('<I',len(c))+c
blocks.append((4,b))
mime=b'image/png'; desc='Обложка'.encode(); pic=struct.pack('>II',3,len(mime))+mime+struct.pack('>I',len(desc))+desc+struct.pack('>IIIII',1,1,8,0,len(cover))+cover
blocks.append((6,pic))
f.write_bytes(b'fLaC'+b''.join(bytes([t|(128 if i==len(blocks)-1 else 0)])+len(b).to_bytes(3,'big')+b for i,(t,b) in enumerate(blocks))+data[off:])

# Force different prediction and stereo coding modes, with a short final frame.
for name, bits, ch, rate, mode, lpc, pattern in [
    ('constant16',16,1,44100,0,'fixed','constant'),
    ('ramp16',16,1,12345,0,'fixed','ramp'),
    ('verbatim24',24,2,123450,0,'none','noise'),
    ('left24',24,2,96000,1,'levinson','sine'),
    ('right24',24,2,88200,2,'cholesky','sine'),
    ('mid24',24,2,176400,3,'levinson','sine'),
    ('mono24',24,1,192000,0,'levinson','sine'),
    ('stereo16',16,2,8000,3,'fixed','ramp'),
]:
    count=8195
    rng=random.Random(20261103)
    raw=bytearray()
    for i in range(count):
        for c in range(ch):
            if pattern=='constant': v=120
            elif pattern=='ramp': v=((i*7+c*11)%32000)-16000
            elif pattern=='noise': v=rng.randrange(-(1<<(bits-1)),1<<(bits-1))
            else: v=int((math.sin(i*0.015)+0.13*math.sin(i*0.101+c*0.003))*((1<<(bits-1))-1)*0.8)
            raw+=int(v).to_bytes(bits//8,'little',signed=True)
    (p/f'{name}.raw').write_bytes(raw)
    subprocess.run([ffmpeg,'-hide_banner','-loglevel','error','-y','-f',f's{bits}le','-ar',str(rate),'-ac',str(ch),'-i',str(p/f'{name}.raw'),'-c:a','flac','-compression_level','12','-ch_mode',str(mode),'-lpc_type',lpc,str(p/f'{name}.flac')],check=True)
