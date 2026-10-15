"""Check the exact two compressed public addresses compiled into the app."""
import gzip, hashlib, json, time, urllib.request
BASES = [
    "https://github.com/rio10255254/TaipeiBus/releases/download/travel-time-data/",
    "https://cdn.jsdelivr.net/gh/rio10255254/TaipeiBus@phone-data/",
]
def read(url):
    with urllib.request.urlopen(url, timeout=40) as response:
        return response.read(33 * 1024 * 1024)
def verify():
    results=[]
    for base in BASES:
        for attempt in range(4):
            try:
                manifest=json.loads(read(base+"official-times-manifest.json"))
                packed=read(base+"official-times.json.gz")
                raw=gzip.decompress(packed)
                assert len(raw)==manifest["bytes"]
                assert hashlib.sha256(raw).hexdigest()==manifest["sha256"]
                assert len(packed)==manifest["gzipBytes"]
                data=json.loads(raw)
                assert data["generatedAt"]==manifest["generatedAt"]
                result={"source":base,"bytes":len(raw),"compressedBytes":len(packed),"profiles":len(data["routes"]),"sha256":manifest["sha256"],"generatedAt":data["generatedAt"]}
                results.append(result)
                print(json.dumps(result),flush=True)
                break
            except Exception as error:
                if attempt==3: raise
                print("Waiting for the public mirror:",type(error).__name__,flush=True)
                time.sleep(10)
    assert results[0]["sha256"]==results[1]["sha256"], "Public mirrors disagree"
    return results
if __name__=="__main__": verify()
