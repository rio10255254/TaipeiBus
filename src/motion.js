export function meters(a,b) { return Math.hypot((a[0]-b[0])*Math.cos(a[1]*Math.PI/180),a[1]-b[1])*111320; }
export function heading(a,b) { return (Math.atan2((b[0]-a[0])*Math.cos(a[1]*Math.PI/180),b[1]-a[1])*180/Math.PI+360)%360; }
export function pointAtDistance(path,distance) {
  for(let i=1;i<path.length;i++) {
    const length=meters(path[i-1],path[i]);
    if(distance<=length) { const t=length?distance/length:0;return {position:[path[i-1][0]+(path[i][0]-path[i-1][0])*t,path[i-1][1]+(path[i][1]-path[i-1][1])*t],heading:heading(path[i-1],path[i])}; }
    distance-=length;
  }
  return {position:path.at(-1),heading:path.length>1?heading(path.at(-2),path.at(-1)):0};
}
export class VehicleMotion {
  constructor() { this.states=new Map(); }
  ingest(vehicles,now=performance.now()) {
    const ids=new Set();
    for(const bus of vehicles) {
      ids.add(bus.id);const old=this.states.get(bus.id);
      if(old && bus.observedAt===old.bus.observedAt && !bus.demo) { old.bus=bus;continue; }
      const path=old && bus.path?.length>1 && bus.routeId===old.bus.routeId && bus.direction===old.bus.direction && Date.now()-bus.observedAt<120000?bus.path:[bus.position];
      const length=path.slice(1).reduce((sum,p,i)=>sum+meters(path[i],p),0);
      const duration=length>1?Math.min(12000,Math.max(1800,(bus.observedAt-(old?.bus.observedAt||bus.observedAt))*.65)):0;
      this.states.set(bus.id,{bus,path,length,duration,start:now});
    }
    for(const id of this.states.keys()) if(!ids.has(id)) this.states.delete(id);
  }
  at(id,now=performance.now()) {
    const state=this.states.get(id);if(!state)return null;
    if(state.bus.demo && state.bus.demoTrack) {
      const bus=state.bus;
      const distance=(bus.startDistance+Math.max(0,now-bus.demoStart)/1000*bus.speed/3.6)%bus.demoLength;
      return {...bus,...pointAtDistance(bus.demoTrack,distance)};
    }
    if(!state.duration||Date.now()-state.bus.observedAt>120000)return {...state.bus,position:state.bus.position};
    const t=Math.max(0,Math.min(1,(now-state.start)/state.duration));
    const p=pointAtDistance(state.path,state.length*t);
    return {...state.bus,position:p.position,heading:state.bus.speed>2?p.heading:state.bus.heading};
  }
}
