#!/usr/bin/env python3
"""Create deterministic synthetic Curve QA data, without reading a real browser profile."""
from pathlib import Path
import argparse, json, time
ROOT = Path(__file__).resolve().parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--profile', type=Path, default=ROOT.parents[1] / '.build' / 'qa-fixture' / 'profile')
PROFILE = parser.parse_args().profile.expanduser().resolve()
PROFILE.mkdir(parents=True, exist_ok=True)
def uid(n): return f'00000000-0000-4000-8000-{n:012d}'
now = time.time() - 978307200 # Swift JSONEncoder's seconds since 2001-01-01.
studio, research, focus = map(uid, [101,102,103])
resources, reading, research_folder = map(uid,[301,302,303])
base = 'http://127.0.0.1:8765/'
def tab(n,title,path,kind='today',space=studio,folder=None):
    url = path if '://' in path else base + path
    result = dict(id=uid(n),title=title,url=url,kind=kind,spaceID=space,lastAccessed=now-n,createdAt=now-1800)
    if kind!='today': result['savedURL']=url
    if folder: result['folderID']=folder
    return result
tabs = [
 tab(201,'QA Home','index.html?tab=favorite','favorite'),
 tab(202,'QA Find','find.html','favorite'),
 tab(203,'QA Pinned Home','index.html?tab=pinned','pinned'),
 tab(210,'QA Roadmap','controls.html?tab=roadmap','pinned'),
 tab(204,'Reading Alpha','second.html?tab=alpha','pinned',folder=reading),
 tab(205,'Reading Beta','third.html?tab=beta','pinned',folder=reading),
 tab(206,'QA Navigation','index.html?tab=navigation'),
 tab(207,'QA Draft','drafts.html'),
 tab(208,'QA Controls','controls.html'),
 tab(209,'QA Drag Me','third.html?tab=drag'),
 tab(211,'QA Drag Tail','second.html?tab=tail'),
 tab(212,'Research Pin','index.html?tab=research-pin','pinned',research),
 tab(213,'Research Notes','second.html?tab=research','today',research),
 tab(214,'Curve Start','curve://start','today',focus)
]
state = dict(
 spaces=[dict(id=studio,name='Studio',emoji='◈',colorHex='6CBADA',theme=dict(baseColors=[dict(red=.4236151,green=.7285774,blue=.8512416,alpha=1),dict(red=.4996583,green=.4958839,blue=.8625748,alpha=1)],overlayColors=[dict(red=0,green=0,blue=0,alpha=0),dict(red=.3605607,green=.8486551,blue=.7209937,alpha=1)],intensity=.80140099,noise=.2,isVibrant=True,isDark=False,ink=dict(red=.0002524,green=.1123221,blue=.1473138,alpha=1)),selectedTabID=uid(206),splitVertical=False),dict(id=research,name='Research',emoji='✳',colorHex='C8C2E2',selectedTabID=uid(213),splitVertical=False),dict(id=focus,name='Focus',emoji='☀',colorHex='E5C8AD',selectedTabID=uid(214),splitVertical=False)],
 tabs=tabs,
 folders=[dict(id=resources,spaceID=studio,name='Resources',isExpanded=True),dict(id=reading,spaceID=studio,name='Resources / Reading',isExpanded=True),dict(id=research_folder,spaceID=research,name='Research Library',isExpanded=False)],
 archive=[dict(id=uid(401),tab=tab(215,'Restorable QA Tab','third.html?tab=archived'),closedAt=now-60)],
 activeSpaceID=studio,sidebarWidth=224,sidebarVisible=True,autoArchiveHours=12,maxLiveTabs=6,searchEngine='duckduckgo',appearanceVersion=2
)
(PROFILE/'state.json').write_text(json.dumps(state,indent=2))
(PROFILE/'history.json').write_text('[]')
for p in [PROFILE/'state.backup.json', PROFILE/'history.backup.json']:
    if p.exists(): p.unlink()
print(PROFILE/'state.json')
