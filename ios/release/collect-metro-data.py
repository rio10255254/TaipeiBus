"""Bounded official metro snapshot collection. Credentials never enter output."""
import argparse, datetime, gzip, json, os, time, urllib.error, urllib.parse, urllib.request
from pathlib import Path

BASE = 'https://tdx.transportdata.tw'
NAMES = ['Line', 'Route', 'Station', 'StationOfRoute', 'StationExit', 'StationTransfer', 'LineTransfer',
         'Shape', 'S2STravelTime', 'Frequency', 'FirstLastTimetable', 'LiveBoard']

def read(url, headers=None, data=None):
    with urllib.request.urlopen(urllib.request.Request(url, data=data, headers=headers or {}), timeout=45) as response:
        raw = response.read(12 * 1024 * 1024 + 1)
        if len(raw) > 12 * 1024 * 1024: raise ValueError('Metro snapshot size limit')
        if response.headers.get('Content-Encoding') == 'gzip' or raw[:2] == b'\x1f\x8b': raw = gzip.decompress(raw)
        return raw

def main():
    parser = argparse.ArgumentParser(); parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--endpoints', default='')
    args = parser.parse_args(); args.out.mkdir(parents=True, exist_ok=True)
    cid, secret = os.environ['TDX_CLIENT_ID'], os.environ['TDX_CLIENT_SECRET']
    payload = urllib.parse.urlencode({'grant_type':'client_credentials','client_id':cid,'client_secret':secret}).encode()
    answer = json.loads(read(BASE+'/auth/realms/TDXConnect/protocol/openid-connect/token', {'Content-Type':'application/x-www-form-urlencoded'}, payload))
    token = answer['access_token']; del cid, secret, answer, payload
    headers = {'Authorization':'Bearer '+token,'Accept-Encoding':'gzip'}
    report = {'schema':1,'generatedAt':datetime.datetime.now(datetime.timezone.utc).isoformat(),
              'source':'MOTC TDX official metro metadata','license':'Open Government Data License 1.0',
              'operators':{},'missing':[],'requests':0,'decodedBytes':0}
    for operator in ['TRTC','NTMC']:
        result = {}
        names = [x for x in args.endpoints.split(',') if x] or NAMES
        if any(x not in NAMES for x in names): raise ValueError('Unknown metro endpoint')
        for name in names:
            if report['requests']: time.sleep(12.2)
            url = BASE+'/api/basic/v2/Rail/Metro/'+name+'/'+operator+'?$format=JSON'
            report['requests'] += 1
            try:
                raw = read(url, headers); report['decodedBytes'] += len(raw)
                rows = json.loads(raw)
                if isinstance(rows,dict) and isinstance(rows.get('StationTransfers'),list): rows = rows['StationTransfers']
                if not isinstance(rows,list):
                    report['missing'].append({'operator':operator,'name':name,'shape':list(rows)[:10] if isinstance(rows,dict) else type(rows).__name__,
                                              'message':str(rows.get('Message',rows.get('message','')))[:240] if isinstance(rows,dict) else ''})
                    print(operator,name,'non-array response',flush=True)
                else:
                    result[name] = rows
                    print(operator,name,len(rows),flush=True)
            except urllib.error.HTTPError as error:
                report['missing'].append({'operator':operator,'name':name,'http':error.code})
                print(operator,name,'unavailable',error.code,flush=True)
            if report['decodedBytes'] > 24 * 1024 * 1024: raise ValueError('Metro collection budget exceeded')
            report['operators'][operator] = result
            (args.out/'metro-raw.json').write_text(json.dumps(report,ensure_ascii=False,separators=(',',':'))+'\n',encoding='utf-8')
        report['operators'][operator] = result
    for operator, rows in report['operators'].items():
        if not args.endpoints and (not rows.get('Line') or not rows.get('Station') or not rows.get('StationOfRoute')):
            raise ValueError('Required official network metadata incomplete for '+operator)
    (args.out/'metro-raw.json').write_text(json.dumps(report,ensure_ascii=False,separators=(',',':'))+'\n',encoding='utf-8')
    print('Saved validated official metadata; no credentials in artifact.',flush=True)

if __name__ == '__main__': main()
