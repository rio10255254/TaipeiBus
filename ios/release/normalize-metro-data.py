import json,re,math,heapq,pathlib,csv,networkx as nx
import argparse
parser=argparse.ArgumentParser(description='Normalize verified TDX snapshots and Taipei Metro CSVs without inventing geometry or times')
parser.add_argument('--input',type=pathlib.Path,required=True)
args=parser.parse_args()
root=args.input
raw=json.loads((root/'raw/metro-raw.json').read_text(encoding='utf-8'))
extra=json.loads((root/'extra/metro-raw.json').read_text(encoding='utf-8'))
def clean(s): return s.removeprefix('捷運').removesuffix('站').replace('臺','台')
latest={(clean(r['stationA']),clean(r['stationB'])):r for r in csv.DictReader((root/'travel.csv').read_text(encoding='cp950').splitlines())}
def distance(a,b): return math.hypot((a[0]-b[0])*111320*math.cos(math.radians((a[1]+b[1])/2)),(a[1]-b[1])*111320)
def c(p): return {'latitude':p[1],'longitude':p[0]}
def pos(p): return (p['PositionLon'],p['PositionLat'])
def wkt(text):
 return [[tuple(map(float,p.strip().split()[:2])) for p in g.split(',')] for g in re.findall(r'\(([^()]+)\)',text)]
lines=[];stations=[];patterns=[];transfers=[];audit={'unmatched':[],'counts':{}}
for op,rows in raw['operators'].items():
 ext=extra['operators'].get(op,{})
 coordinates={s['StationID']:pos(s['StationPosition']) for s in rows['Station']}
 names={s['StationID']:s['StationName'] for s in rows['Station']}
 prefix='metro:'+op+':'
 exits={}
 for e in rows.get('StationExit',[]):
  sid=e['StationID'];exits.setdefault(sid,[]).append({'id':prefix+sid+':exit:'+e['ExitID'],'name':e['ExitName'].get('Zh_tw',''),'englishName':e['ExitName'].get('En',''),'coordinate':c(pos(e['ExitPosition'])),'accessible':bool(e.get('Elevator'))})
 for s in rows['Station']:
  stations.append({'id':prefix+s['StationID'],'operatorID':op,'code':s['StationID'],'name':s['StationName']['Zh_tw'],'englishName':s['StationName'].get('En',''),'coordinate':c(coordinates[s['StationID']]),'exits':exits.get(s['StationID'],[])})
 graphs={}; anchors={}
 for row in rows['Line']:
  lid=row['LineID'];shape=next(x for x in rows['Shape'] if x['LineID']==lid)
  chunks=wkt(shape['Geometry']);g=nx.Graph()
  def key(p): return (round(p[0],7),round(p[1],7))
  for chunk in chunks:
   for a,b in zip(chunk,chunk[1:]):
    ka,kb=key(a),key(b)
    if ka!=kb:g.add_edge(ka,kb,weight=distance(ka,kb))
  # Join small source-segment endpoint gaps without connecting nearby parallel track interiors.
  ends=[n for n in g if g.degree(n)==1]
  for i,a in enumerate(ends):
   for b in ends[i+1:]:
    if distance(a,b)<5:g.add_edge(a,b,weight=distance(a,b))
  relevant={p['StationID'] for r in rows['StationOfRoute'] if r['LineID']==lid for p in r['Stations']}
  aa={}
  for sid in relevant:
   target=coordinates[sid];best=None
   for a,b in list(g.edges):
    scale=math.cos(math.radians(target[1]));dx=(b[0]-a[0])*scale;dy=b[1]-a[1]
    if dx*dx+dy*dy==0:continue
    t=max(0,min(1,((target[0]-a[0])*scale*dx+(target[1]-a[1])*dy)/(dx*dx+dy*dy)))
    point=key((a[0]+t*(b[0]-a[0]),a[1]+t*(b[1]-a[1])));d=distance(target,point)
    if best is None or d<best[0]:best=(d,a,b,point)
   if best is None:raise ValueError('No track anchor '+sid)
   d,a,b,point=best
   if d>350:audit['unmatched'].append({'station':prefix+sid,'meters':d})
   if point not in (a,b):
    g.remove_edge(a,b);g.add_edge(a,point,weight=distance(a,point));g.add_edge(point,b,weight=distance(point,b))
   aa[sid]=point
  graphs[lid]=g;anchors[lid]=aa
  lines.append({'id':prefix+lid,'operatorID':op,'code':lid,'name':row['LineName']['Zh_tw'],'englishName':row['LineName'].get('En',''),'color':row['LineColor'],'mode':'metro','coordinates':[]})
 for row in rows['StationOfRoute']:
  lid=row['LineID'];route=row['RouteID'];direction=str(row['Direction'])
  ids=[x['StationID'] for x in sorted(row['Stations'],key=lambda x:x['Sequence'])]
  travel=next((r for r in rows['S2STravelTime'] if r['RouteID']==route),None)
  if travel is None:raise ValueError('Official travel-time profile missing '+route)
  edges={(e['FromStationID'],e['ToStationID']):e for e in travel['TravelTimes']}
  # TDX StopTime belongs to FromStationID, not ToStationID. Map by station
  # identity so reversing a pattern cannot shift each station's dwell by one.
  stationDwell={e['FromStationID']:e.get('StopTime',0) for e in travel['TravelTimes']}
  sec=[];dwell=[];path=[]
  for a,b in zip(ids,ids[1:]):
   edge=edges.get((a,b)) or edges.get((b,a))
   # The newer published TRTC CSV carries actual directed pairs, including R01.
   # Prefer that direction's current profile to reversing an older TDX profile.
   directed=latest.get((clean(names[a]['Zh_tw']),clean(names[b]['Zh_tw']))) if op=='TRTC' else None
   if directed:
    edge={'RunTime':int(directed['traveltime']),'StopTime':int(directed['stoptime'])}
    stationDwell[a]=edge['StopTime']
   if not edge:
    rowtime=latest.get((clean(names[a]['Zh_tw']),clean(names[b]['Zh_tw']))) or latest.get((clean(names[b]['Zh_tw']),clean(names[a]['Zh_tw'])))
    if not rowtime:raise ValueError('Official time edge missing '+a+' -> '+b)
    edge={'RunTime':int(rowtime['traveltime']),'StopTime':int(rowtime['stoptime'])}
   sec.append(edge['RunTime']);dwell.append(edge.get('StopTime',0))
   try:segment=nx.shortest_path(graphs[lid],anchors[lid][a],anchors[lid][b],weight='weight')
   except nx.NetworkXNoPath:raise ValueError('Official track disconnected '+a+' -> '+b)
   if len(segment)<2:raise ValueError('Track edge collapsed '+a+' -> '+b)
   path+=segment if not path else segment[1:]
  freq=[f for f in rows.get('Frequency',[]) if f['RouteID']==route]
  periods=[]
  for f in freq:
   days=[i for i,k in enumerate(['Sunday','Monday','Tuesday','Wednesday','Thursday','Friday','Saturday']) if f['ServiceDay'].get(k)]
   for h in f.get('Headways',[]): periods.append({'weekdays':days,'holiday':bool(f['ServiceDay'].get('NationalHolidays')),'start':h['StartTime'],'end':h['EndTime'],'minimumSeconds':h['MinHeadwayMins']*60,'maximumSeconds':h['MaxHeadwayMins']*60})
  firstlast=[r for r in ext.get('FirstLastTimetable',[]) if r['StationID']==ids[0] and r.get('DestinationStaionID')==ids[-1]]
  opening=firstlast[0]['FirstTrainTime'] if firstlast else freq[0]['OperationTime']['StartTime'] if freq else ''
  closing=firstlast[0]['LastTrainTime'] if firstlast else freq[0]['OperationTime']['EndTime'] if freq else ''
  headway=min([x['maximumSeconds'] for x in periods] or [360])
  windows=[]
  for sid in ids:
   values=[r for r in ext.get('FirstLastTimetable',[]) if r['StationID']==sid and r.get('DestinationStaionID')==ids[-1]]
   if values:
    windows.append({'stationID':prefix+sid,'first':values[0]['FirstTrainTime'],'last':values[0]['LastTrainTime']})
  stationStops=[0]+[stationDwell.get(sid,30) for sid in ids[1:]]
  patterns.append({'id':prefix+route,'lineID':prefix+lid,'direction':direction,'stationIDs':[prefix+x for x in ids],'coordinates':[c(x) for x in path],'seconds':sec,'dwellSeconds':stationStops,'firstDeparture':opening,'lastDeparture':closing,'headwaySeconds':headway,'periods':periods,'stationWindows':windows})
 # Use only the full operating pattern for the base-map line, with shorter/branch paths in the route overlay.
 for l in lines:
  if l['operatorID']==op:
   ps=[p for p in patterns if p['lineID']==l['id'] and p['direction']=='0'];l['coordinates']=max(ps,key=lambda p:len(p['stationIDs']))['coordinates']
transferTimes={clean(r['station']):float(r['Time'])*60 for r in csv.DictReader((root/'transfers.csv').read_text(encoding='cp950').splitlines())}
for station in stations:
 if clean(station['name']) in ['北投','七張','大橋頭'] and clean(station['name']) in transferTimes:
  transfers.append({'from':station['id'],'to':station['id'],'seconds':transferTimes[clean(station['name'])],
                    'instructions':'站內轉乘 · '+station['name'],'external':False})
for a in stations:
 for b in stations:
  if a['id']==b['id'] or clean(a['name'])!=clean(b['name']):continue
  ap=(a['coordinate']['longitude'],a['coordinate']['latitude']);bp=(b['coordinate']['longitude'],b['coordinate']['latitude'])
  if distance(ap,bp)>600:continue
  seconds=transferTimes.get(clean(a['name']))
  if seconds:transfers.append({'from':a['id'],'to':b['id'],'seconds':seconds,'instructions':'站內轉乘 · '+b['name'],'external':False})
published=json.loads((root/'transfers/metro-raw.json').read_text(encoding='utf-8'))
codes={s['code']:s for s in stations}
for op,rows in published['operators'].items():
 for t in rows.get('LineTransfer',[]):
  a=codes.get(t['FromStationID']);b=codes.get(t['ToStationID'])
  if not a or not b:continue
  internal=bool(t['IsOnSiteTransfer']); seconds=transferTimes.get(clean(a['name'])) if internal and clean(a['name'])==clean(b['name']) else None
  value={'from':a['id'],'to':b['id'],'seconds':seconds or float(t['TransferTime'])*60,'instructions':('站內轉乘' if internal else '步行轉乘')+' · '+b['name'],'external':not internal}
  transfers=[x for x in transfers if (x['from'],x['to'])!=(a['id'],b['id'])];transfers.append(value)
network={'schema':1,'generatedAt':raw['generatedAt'],'source':'MOTC TDX; Taipei Metro and New Taipei Metro official routes, track geometry, exits and station-pair times','lines':lines,'stations':stations,'patterns':patterns,'transfers':transfers}
(root/'metro-normalized.json').write_text(json.dumps(network,ensure_ascii=False,separators=(',',':'))+'\n',encoding='utf-8')
audit['counts']={'lines':len(lines),'stations':len(stations),'patterns':len(patterns),'exits':sum(len(s['exits']) for s in stations)}
(root/'normalization-audit.json').write_text(json.dumps(audit,ensure_ascii=False,indent=2),encoding='utf-8');print(audit)
