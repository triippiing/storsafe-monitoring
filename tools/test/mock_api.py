import json, sys, re
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import urlparse, parse_qs
SID="abc-123"; state={"expire_once": "--expire" in sys.argv}
import time, gzip
NOW=int(time.time())
def loc(i):
    if i<2000: return {"type":"libslot","libstdid":15 if i<1500 else 22,"slotdriveno":i}
    if i<2100: return {"type":"vault"}
    return {"type":"replica"}
TAPES=[{"id":10000000+i,"name":f"VT-{i:05}","barcode":f"B{i:05}","sizemb":1024,"usedmb":0 if i%10==0 else 10,
        "location":loc(i),"parentlibvid":(15 if i<1500 else 22) if i<2000 else 0,"worm":i%50==0,
        "source":"VTL-SRC-1" if i>=2100 else "","replicated":(NOW-3600*(i-2100)) if i>=2105 else 0,
        "devicestatus":"online","dedupestatus":"failed" if i==7 else ("pending" if i==8 else "completed"),
        "vitstatus":"pure","encryptionstatus":"","replicationenabled":i<1500,
        "replstatus":"completedfailed" if i==9 else ""} for i in range(2500)]
EVENTS=[]  # (epoch, type, id, msg)
for k in range(30): EVENTS.append((NOW-86400+k*2000, "I" if k%5 else "W", 1000+k, f"Event message {k}, with comma"))
EVENTS.append((NOW-100,"E",7001,'Replication of "VT-1" failed'))
EVENTS.append((NOW-50,"C",9001,"Deduplication repository disk offline"))
def fmt(t): return time.strftime("%Y%m%d%H%M%S", time.localtime(t))
class H(BaseHTTPRequestHandler):
    def log_message(self,*a): pass
    def send(self,obj,code=200,cookie=None):
        b=json.dumps(obj).encode(); self.send_response(code); self.send_header("Content-Type","application/json")
        if cookie: self.send_header("Set-Cookie",f"session_id={cookie}; Path=/")
        self.end_headers(); self.wfile.write(b)
    def authed(self): return f"session_id={SID}" in (self.headers.get("Cookie") or "")
    def do_POST(self):
        n=int(self.headers.get("Content-Length") or 0); body=json.loads(self.rfile.read(n) or b"{}")
        p=urlparse(self.path).path
        if p=="/obd/auth/login":
            if body.get("password")!="pw": return self.send({"rc":10001})
            return self.send({"rc":0,"id":SID,"type":"user"},cookie=SID)
        if p=="/obd/auth/logout": return self.send({"rc":0})
        self.send({"rc":1},404)
    def do_PUT(self):
        n=int(self.headers.get("Content-Length") or 0); body=json.loads(self.rfile.read(n) or b"{}")
        if not self.authed(): return self.send({"rc":401},401)
        if urlparse(self.path).path!="/obd/server/event": return self.send({"rc":1},404)
        rng=body.get("range","")
        a,_,b=rng.partition("-")
        if len(a)!=14: return self.send({"rc":12345})
        b=b or "99999999999999"
        # one new event per call
        EVENTS.append((int(time.time()),"W",5000+len(EVENTS),f"New warning {len(EVENTS)}"))
        rows=["\"Type\",\"Date\",\"Time\",\"ID\",\"Event Message\""]
        if "--noheader" in sys.argv: rows=[]
        for t,ty,i,msg in EVENTS:
            if a<=fmt(t)<=b: rows.append('"%s","%s","%s","%d","%s"'%(ty,time.strftime("%m/%d/%Y",time.localtime(t)),time.strftime("%H:%M:%S",time.localtime(t)),i,msg.replace('"','""')))
        data=("\r\n".join(rows)+"\r\n").encode("latin-1")
        if "--gzip" in sys.argv: data=gzip.compress(data)
        self.send_response(200); self.send_header("Content-Type","application/csv;charset=ISO-8859-1")
        self.send_header("Content-Disposition","attachment; filename=EventLog.csv"); self.end_headers(); self.wfile.write(data)
    def do_GET(self):
        u=urlparse(self.path); p=u.path; q=parse_qs(u.query)
        if not self.authed(): return self.send({"rc":401},401)
        if state["expire_once"] and p=="/obd/dedupepolicy":
            state["expire_once"]=False; return self.send({"rc":401},401)

        EXTRA={
          "/obd/server/properties/version":{"rc":0,"data":{"product":"FalconStor Virtual Tape Library Server","version":"11.11","build":"12179-01","apiversion":"11.11"}},
          "/obd/server/failover/status":{"rc":0,"data":{"status":"normal"}},
          "/obd/physicalresource/storagepool":{"rc":0,"data":{"storagepools":[{"id":1,"name":"StoragePool-1","resourcetype":"all","size":1073727143936,"used":91271200768}]}},
          "/obd/physicalresource/physicaldevice":{"rc":0,"data":{"total":3,"physicaldevices":[
             {"id":"a","name":"DELL:MD38xxf","acsl":"101:0:0:0","type":"disk","category":"virtual","reservation":"deduplication","size":21474836480,"used":1000,"isforeign":False,"status":"online"},
             {"id":"b","name":"DELL \"MD\"","acsl":"101:0:0:1","type":"disk","category":"virtual","reservation":"tapes","size":21474836480,"used":0,"isforeign":False,"status":"offline"},
             {"id":"c","name":"partner","acsl":"101:0:0:2","type":"disk","category":"virtual","reservation":"tapes","size":1,"used":0,"isforeign":True,"status":"online"}]}},
          "/obd/server/storagethreshold":{"rc":0,"threshold":90},
          "/obd/vtl/activities/dedupequeue":{"rc":0,"data":[{"name":"VT-12","id":10000012,"barcode":"B00012","policy":"Nightly","state":"indexrepli","undedupedatamb":100,"throughputmbps":5,"progress":40},{"name":"VT-13","id":10000013,"barcode":"B00013","policy":"Nightly","state":"queued","undedupedatamb":50,"throughputmbps":0,"progress":0}]},
          "/obd/vtl/activities/dedupequeue/10000012":{"rc":0,"data":{"tape":"VT-12","barcode":"B00012","policy":"Nightly","policyid":2,"state":"indexrepli","trigger":"schedule","sourcedrive":"S16","destinationdrive":"","replicationmode":"single","undedupedatamb":100,"targetservers":[{"name":"VTL-B","ipaddress":"192.0.2.12","replicationstatus":"indexrepli","throughputmbps":2,"progress":40}]}},
          "/obd/vtl/activities/dedupequeue/10000013":{"rc":0,"data":{"tape":"VT-13","barcode":"B00013","policy":"Nightly","policyid":2,"state":"queued","trigger":"schedule","sourcedrive":"","destinationdrive":"","replicationmode":"","undedupedatamb":50,"targetservers":[]}},
          "/obd/vtl/activities/replicationqueue":{"rc":0,"data":[{"name":"VT-1","id":10000001,"barcode":"B00001","type":"typeclassic","mode":"moderegular","state":"running"},{"name":"VT-2","id":10000002,"barcode":"B00002","type":"typeclassic","mode":"moderegular","state":"waiting"}]},
          "/obd/vtl/activities/replicationqueue/10000001":{"rc":0,"data":{"tape":"VT-1","type":"typeclassic","mode":"moderegular","state":"running","trigger":"schedule","watermarkmb":0,"targetservers":[{"name":"VTL-B","ipaddress":"192.0.2.12"}],"retryinterval":60,"retrycount":1,"leftretrycount":1,"nextretrytime":0}},
          "/obd/vtl/activities/replicationqueue/10000002":{"rc":0,"data":{"tape":"VT-2","type":"typeclassic","mode":"moderegular","state":"waiting","trigger":"schedule","watermarkmb":0,"targetservers":[{"name":"VTL-B","ipaddress":"192.0.2.12"}],"retryinterval":60,"retrycount":1,"leftretrycount":1,"nextretrytime":NOW+300}},
          "/obd/vtl/activities/uniquereplicationqueue":{"rc":0,"data":[{"policy":"p1","sourceserver":"VTL-C","sourcebarcode":"C00001","replicabarcode":"C00001","lvittape":"VTL-C-VT-1","lvitid":10003568,"lvitbarcode":"C00001","starttime":NOW-900,"status":" running "}]},
          "/obd/vtl/activities/replicationqueue/setting":{"rc":0,"status":"suspended"},
        }
        EXTRA.update({
          "/obd/server/properties/time":{"rc":0,"data":{"systemtime":time.strftime("%Y-%m-%d %H:%M:%S",time.localtime()),"epochetime":str(int(time.time())+3)}},
          "/obd/physicalresource/physicaladapter":{"rc":0,"data":{"total":2,"physicaladapters":[{"vendor":"MegaRAID","id":"100","type":"scsi","mode":"","wwpn":"","paths":1},{"vendor":"QLogic","id":"102","type":"fc","mode":"dual","wwpn":"21-00-00-1b-32-07-b8-9b","paths":16}]}},
          "/obd/deduplication":{"rc":0,"data":{"enabled":True,"name":"Localcluster-OBD190","type":"standard","mode":"flexible","failoverenabled":False,"encryption":False,"nodetype":"active","objectstoragegb":0,
             "nodes":[{"ipaddress":"10.8.25.190","name":"OBD190","type":"active","datadisks":[{"id":3723,"name":"SIR_Data-000","size":951256612864},{"id":3724,"name":"SIR_Data-001","size":536859377664}],
               "indexes":[{"id":3719,"name":"SIR_Index-00","size":85383446528}],"folders":[{"id":3720,"name":"SIR_Folder-00","size":438889873408}]}]}},
          "/obd/physicallibrary/status":{"rc":0,"data":{"ptlstat":[{"id":181,"status":"online","tapes":60,"loadedtapes":1,"slots":4,"serialno":"122R400A0G","disabled":False,
             "ptdstat":[{"id":182,"status":"loaded","barcode":"001B0003","serialno":"1493955380","disabled":False},{"id":183,"status":"empty","barcode":"","serialno":"1493955381","disabled":False}]}],"acslsptlstat":[]}},
          "/obd/physicallibrary/181":{"rc":0,"data":{"name":"IBM-TS3100-181","status":"online","standardstat":{"ptdstat":[{"id":182,"name":"IBM-ULT3580-182"},{"id":183,"name":"IBM-ULT3580-183"}]}}},
          "/obd/activity/iejob":{"rc":0,"data":{"jobs":[{"jobid":60,"jobtype":"exportphysicaltapelib","status":"running","starttime":int(time.time())-600,"transferedmb":300},{"jobid":61,"jobtype":"exportphysicaltapelib","status":"failed","starttime":0}]}},
          "/obd/virtualdrive":{"rc":0,"data":[]},
          "/obd/tle/reclaim/tapes":{"rc":0,"data":{"libs":[{"id":166,"name":"L","tapes":[{"id":1},{"id":2}]}],"vault":[{"id":3}]}},
          "/obd/server/properties/info":{"rc":0,"data":{"isvirtualappliance":False,"osversion":"Red Hat Enterprise Linux Server release 7.6 (Maipo)","kernelversion":"Linux 3.10.0","processor":["x"]*8,"memory":16651386880,"swap":4294967296,"role":"storsafe","make":"Dell","model":"R740","location":"DC1","description":"","fmsinstalled":False,"fmsrunning":False}},
          "/obd/server/properties/host":{"rc":0,"data":{"hostname":"VTL-A"}},
          "/obd/patches":{"rc":0,"patches":[{"name":"update-is708211","desc":"Identification: patch fixing issues with snapshots.\n"}]},
          "/obd/server/options":{"rc":0,"data":{"configrepo":True,"failover":False,"fctarget":True,"iscsitarget":False,"emailalerts":False,"autosavetoftp":"true","ndmp":False,"guid":""}},
          "/obd/encryption":{"rc":0,"data":{"supportencrypt":True,"tapeencryptenabled":False,"dedupencryptenabled":True,"encryptionactive":True}},
          "/obd/server/failover":{"rc":0,"data":{"type":"none"}},
          "/obd/server/properties/network":{"rc":0,"data":{"domain":"lab","dns":["10.8.1.2"],"gateway":"10.8.1.1","ssh":True,"sftp":True,"nics":[{"name":"eth0","mtu":1500,"speed":1000,"dhcp":False,"ifgcfg":[{"number":-1,"ipaddress":"192.0.2.11","netmask":"255.255.255.0"}]},{"name":"eth1","mtu":9000,"speed":10000,"dhcp":False,"ifcfg":[]}]}},
          "/obd/network/bonding":{"rc":0,"groups":[]},
          "/obd/server/properties/ntp":{"rc":"0","data":["0.pool.ntp.org","1.pool.ntp.org"]},
          "/obd/dedupereplication":{"rc":0,"data":{"sources":[],"targets":[{"name":"VTL-B","vtls":True,"protocol":"TCP","tcpoptions":{"encryption":False,"timeout":5,"servers":[{"name":"VTL-B","ipaddress":"192.0.2.12"}]}}]}},
          "/obd/virtualtape/lvitsource":{"rc":0,"data":[]},
          "/obd/deduplication/reclamation":{"rc":0,"data":{"usage":{"enabled":True,"interval":10},"schedule":{"enabled":True,"weekdays":[0,3],"starttime":"19:00"}}},
          "/obd/deduplication/cleanup":{"rc":0,"cleandisk":False},
          "/obd/tle/properties":{"rc":0,"data":{"compression":True,"retaintape":False,"reclamationthreshold":92,"migrationthreshold":92}},
          "/obd/activity/iejob/properties":{"rc":0,"data":{"retry":True,"retrycount":2,"retryinterval":10}},
          "/obd/server/activitydatabase":{"rc":0,"maxsize":50,"maxdays":365},
          "/obd/client":{"rc":0,"data":{"total":2,"clients":[{"id":1,"name":"tsm1","fcenabled":True,"iscsienabled":False},{"id":2,"name":"tsm2","fcenabled":True,"iscsienabled":True}]}},
          "/obd/physicalresource/physicaladapter/fcclientinitiators":{"rc":0,"data":[{"wwpn":"1","assigned":"client"},{"wwpn":"2","assigned":""}]},
          "/obd/client/iscsitarget":{"rc":0,"data":{"total":0,"iscsitargets":[]}},
          "/obd/client/iscsiclientinitiators":{"rc":0,"data":[]},
          "/obd/client/hostedbackup":{"rc":0,"data":{"devices":[]}},
          "/obd/user/account":{"rc":0,"data":{"total":2,"users":[{"type":"A","user":"fsadmin","id":1},{"type":"R","user":"mon","id":2}]}},
          "/obd/objectstorage":{"rc":0,"data":{"accounts":[]}},
          "/obd/server/syslogalert":{"rc":0,"data":{"enabled":True,"frequency":60,"memorize":1440,"incidents":[{"pattern":"x","label":"y"}]}},
          "/obd/server/properties/autosavetoftp":{"rc":0,"data":{"enabled":False}},
        })
        m=re.match(r"/obd/logicalresource/status/(\d+)$",p)
        if m: return self.send({"rc":0,"status":"incomplete" if m.group(1)=="3724" else "online"})
        m=re.match(r"/obd/dedupepolicy/activestatus/(\d+)$",p)
        if m:
            if m.group(1)=="2": return self.send({"rc":0,"data":{"scan":[{"id":10000012,"name":"VT-12","barcode":"B00012","drivesn":"S16","parser":"tsm","datasize":2356,"scanned":1496,"throughput":3,"status":"running","progress":63}],"replication":[{"name":"VT-12","barcode":"B00012","phase":"index","replicated":100,"transmitted":40,"throughput":2,"remainingtime":120,"progress":40}]}})
            return self.send({"rc":0,"data":{"scan":[],"replication":[]}})
        m=re.match(r"/obd/dedupepolicy/runhistory/(\d+)$",p)
        if m:
            pid=int(m.group(1)); fromts=int(q.get("fromts",["0"])[0])
            runs=[] if pid==3 else [{"timestamp":NOW-h*3600,"trigger":"schedule","tapes":2,"dedupedata":1000+h,"uniquedata":100,"deduperatio":"10.0 : 1","dedupeduration":600,"repldata":100,"replunique":20,"repldeduperatio":"5.0 : 1","replduration":60,"status":"failed" if h==1 else "completed"} for h in range(0,72,6)]
            if pid==4: runs=[{"timestamp":NOW-10*86400,"trigger":"manual","tapes":1,"dedupedata":0,"uniquedata":0,"deduperatio":"N/A","status":"canceled"}]
            runs=[r for r in runs if r["timestamp"]>=fromts]
            return self.send({"rc":0,"total":len(runs),"data":runs})
        if p in EXTRA: return self.send(EXTRA[p])
        if p=="/obd/tle/tapecaching": return self.send({"rc":1},500)
        if p=="/obd/dedupepolicy":
            return self.send({"rc":0,"data":{"policies":[
              {"name":"Default_Policy","id":1,"status":"idle","suspended":False,"nextrun":0,"lastrun":0,"trigger":"inline","tapes":0},
              {"name":"Nightly","id":2,"status":"running","suspended":False,"nextrun":1481101200,"lastrun":1481097605,"trigger":"schedule","tapes":3},
              {"name":"Held","id":3,"status":"idle","suspended":True,"nextrun":0,"lastrun":0,"trigger":"schedule","tapes":1},
              {"name":"Weird","id":4,"status":"degraded","suspended":False,"nextrun":0,"lastrun":0,"trigger":"manual","tapes":1}]}})
        if p=="/obd/deduplication/reclamation/status":
            state["recl"]=state.get("recl",0)+1
            return self.send({"rc":0,"data":{"reclaimstatus":"running" if state["recl"]<=2 else "idle","prunestatus":""}})
        if p=="/obd/virtualtape":
            n=int(self.headers.get("Content-Length") or 0); raw=self.rfile.read(n) if n else b""
            if "application/json" not in (self.headers.get("Content-Type") or "") or json.loads(raw or b"{}").get("location")!="vtl":
                return self.send({"error":"Unsupported Media Type"},415)
            o=int(q["offset"][0]); l=int(q["limit"][0])
            return self.send({"rc":0,"data":{"total":len(TAPES),"tapes":TAPES[o:o+l]}})
        if p=="/obd/virtuallibrary":
            return self.send({"rc":0,"data":[{"id":15,"name":"LIB-A","slots":80,"drives":2,"loadeddrives":1,"tapes":15},
                                             {"id":22,"name":"LIB-B","slots":80,"drives":1,"loadeddrives":1,"tapes":2}]})
        m=re.match(r"/obd/virtuallibrary/drive/(\d+)$",p)
        if m:
            lid=int(m.group(1))
            drives=[{"id":16,"name":"DRV-16","serialno":"S16","status":"loaded","loadedtape":{"id":10000002,"name":"VT-2","barcode":"000F0001"}},
                    {"id":17,"name":"DRV-17","serialno":"S17","status":"empty"}] if lid==15 else [{"id":30,"name":"DRV-30","serialno":"S30","status":"empty"}]
            return self.send({"rc":0,"data":{"vendorid":"ADIC","productid":"Scalar 100","media":"ULTRIUM1","drives":drives}})
        self.send({"rc":1},404)
HTTPServer(("127.0.0.1",int(sys.argv[1])),H).serve_forever()
