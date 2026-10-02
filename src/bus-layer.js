import * as THREE from 'three';
import { RoundedBoxGeometry } from 'three/addons/geometries/RoundedBoxGeometry.js';

/** Real metre-sized meshes, rendered into the map's own WebGL framebuffer and shared depth buffer. */
export class BusLayer {
  constructor(engine,motion,{ selected=()=>null, filter=()=>true, clarity=()=>false }={}) {
    this.id='3d-buses';this.type='custom';this.renderingMode='3d';this.engine=engine;this.motion=motion;this.selected=selected;this.filter=filter;this.clarity=clarity;
    this.origin=engine.MercatorCoordinate.fromLngLat([121.55,25.04],0);this.scale=this.origin.meterInMercatorCoordinateUnits();this.meshes=new Map();this.renderedCount=0;
  }
  onAdd(map,gl) {
    this.map=map;this.camera=new THREE.Camera();this.scene=new THREE.Scene();
    this.scene.add(new THREE.AmbientLight(0xffffff,1.8));
    const sun=new THREE.DirectionalLight(0xffffff,2.2);sun.position.set(-200,-100,400);this.scene.add(sun);
    this.renderer=new THREE.WebGLRenderer({canvas:map.getCanvas(),context:gl,antialias:true});this.renderer.autoClear=false;this.renderer.outputColorSpace=THREE.SRGBColorSpace;
    this.geometry=new RoundedBoxGeometry(2.5,11.8,3.05,2,.18);
    this.bodyMaterial=new THREE.MeshStandardMaterial({color:0xa1a8ad,roughness:.95,metalness:0});
    this.focusBodyMaterial=new THREE.MeshStandardMaterial({color:0x697983,roughness:.95,depthTest:false,depthWrite:false});
    this.roofGeometry=new THREE.BoxGeometry(2.3,11.2,.12);this.roofMaterial=new THREE.MeshStandardMaterial({color:0xc0c5c8,roughness:1});
    this.focusRoofMaterial=new THREE.MeshStandardMaterial({color:0x919ea7,roughness:1,depthTest:false,depthWrite:false});
    this.frontGeometry=new THREE.BoxGeometry(2.13,.07,1.05);this.frontMaterial=new THREE.MeshStandardMaterial({color:0x747e84,roughness:1});
    this.wheelGeometry=new THREE.CylinderGeometry(.36,.36,.2,8);this.wheelMaterial=new THREE.MeshStandardMaterial({color:0x60686d,roughness:1});
    this.edgeGeometry=new THREE.EdgesGeometry(new THREE.BoxGeometry(2.68,11.96,3.22));this.edgeMaterial=new THREE.LineBasicMaterial({color:0x147be9,depthTest:true});
    this.shadowGeometry=new THREE.CircleGeometry(1,24);this.shadowMaterial=new THREE.MeshBasicMaterial({color:0x596369,opacity:.13,transparent:true,depthWrite:false});
    this.pickMaterial=new THREE.MeshBasicMaterial({side:THREE.DoubleSide});
  }
  createMesh(id) {
    const group=new THREE.Group();group.userData.busId=id;
    const body=new THREE.Mesh(this.geometry,this.bodyMaterial);body.position.z=1.95;group.add(body);group.userData.body=body;
    const roof=new THREE.Mesh(this.roofGeometry,this.roofMaterial);roof.position.z=3.48;group.add(roof);group.userData.roof=roof;
    const front=new THREE.Mesh(this.frontGeometry,this.frontMaterial);front.position.set(0,5.89,2.35);group.add(front);
    for(const x of [-1.22,1.22])for(const y of [-3.7,3.7]){const wheel=new THREE.Mesh(this.wheelGeometry,this.wheelMaterial);wheel.rotation.z=Math.PI/2;wheel.position.set(x,y,.4);group.add(wheel);}
    const shadow=new THREE.Mesh(this.shadowGeometry,this.shadowMaterial);shadow.scale.set(1.7,6.2,1);shadow.position.z=.025;group.add(shadow);
    const edge=new THREE.LineSegments(this.edgeGeometry,this.edgeMaterial);edge.position.z=1.95;edge.visible=false;group.add(edge);group.userData.edge=edge;
    this.scene.add(group);this.meshes.set(id,group);return group;
  }
  update(now) {
    const bounds=this.map.getBounds();const center=this.map.getCenter();
    const candidates=[];
    for(const state of this.motion.states.values()) {
      const bus=this.motion.at(state.bus.id,now);
      if(this.filter(bus)&&(bounds.contains(bus.position)||bus.id===this.selected()))candidates.push(bus);
    }
    candidates.sort((a,b)=>a.id===this.selected()?-1:b.id===this.selected()?1:Math.hypot(a.position[0]-center.lng,a.position[1]-center.lat)-Math.hypot(b.position[0]-center.lng,b.position[1]-center.lat));
    const visible=new Set();
    for(const bus of candidates.slice(0,220)) {
      visible.add(bus.id);const group=this.meshes.get(bus.id)||this.createMesh(bus.id);
      const coord=this.engine.MercatorCoordinate.fromLngLat(bus.position,0);
      group.position.set((coord.x-this.origin.x)/this.scale,-(coord.y-this.origin.y)/this.scale,0);group.rotation.z=-bus.heading*Math.PI/180;group.visible=true;group.userData.edge.visible=bus.id===this.selected();
      const focus=bus.id===this.selected()&&this.clarity();
      group.userData.body.material=focus?this.focusBodyMaterial:this.bodyMaterial;group.userData.roof.material=focus?this.focusRoofMaterial:this.roofMaterial;group.renderOrder=focus?100:0;
    }
    for(const [id,mesh] of this.meshes) {mesh.visible=visible.has(id);if(!this.motion.states.has(id)){this.scene.remove(mesh);this.meshes.delete(id);}}
    this.renderedCount=visible.size;
    this.edgeMaterial.depthTest=!this.clarity();this.edgeMaterial.depthWrite=!this.clarity();
  }
  render(first,second) {
    // MapLibre 6 uses (gl, render-input); Mapbox uses (gl, matrix).
    // mainMatrix accepts normalized Mercator coordinates. modelViewProjectionMatrix uses world pixels.
    const matrix=second?.defaultProjectionData?.mainMatrix||first.defaultProjectionData?.mainMatrix||second;
    if(!matrix||matrix.length!==16)return;
    this.update(performance.now());
    const projection=new THREE.Matrix4().fromArray(matrix);
    const local=new THREE.Matrix4().makeTranslation(this.origin.x,this.origin.y,this.origin.z).scale(new THREE.Vector3(this.scale,-this.scale,this.scale));
    this.camera.projectionMatrix.copy(projection.multiply(local));this.camera.projectionMatrixInverse.copy(this.camera.projectionMatrix).invert();
    this.renderer.resetState();this.renderer.render(this.scene,this.camera);this.renderer.resetState();
    // Never clear color/depth: map buildings and bus bodies participate in the same scene depth test.
    if(!document.hidden)this.map.triggerRepaint();
  }
  pick(point) {
    if(!this.camera)return null;
    const canvas=this.map.getCanvas(),x=point.x/canvas.clientWidth*2-1,y=1-point.y/canvas.clientHeight*2;
    const inverse=this.camera.projectionMatrixInverse;
    const near=new THREE.Vector3(x,y,-1).applyMatrix4(inverse),far=new THREE.Vector3(x,y,1).applyMatrix4(inverse);
    this.scene.updateMatrixWorld(true);
    const ray=new THREE.Raycaster(near,far.sub(near).normalize());
    const hits=ray.intersectObjects([...this.meshes.values()].filter(g=>g.visible),true);
    for(const hit of hits) {if(hit.object.geometry===this.shadowGeometry||hit.object.isLineSegments)continue;let object=hit.object;while(object&&!object.userData.busId)object=object.parent;if(object)return !(object.userData.busId===this.selected()&&this.clarity())&&this.isOccluded(ray,hit.distance,point)?null:object.userData.busId;}
    return null;
  }
  isOccluded(ray,distance,point) {
    const layers=this.map.getStyle().layers.filter(layer=>layer.type==='fill-extrusion').map(layer=>layer.id);
    if(!layers.length)return false;
    for(const feature of this.map.queryRenderedFeatures(point,{layers})) {
      const props=feature.properties;
      const paintHeight=this.map.getPaintProperty(feature.layer.id,'fill-extrusion-height');
      const paintBase=this.map.getPaintProperty(feature.layer.id,'fill-extrusion-base');
      const height=Number(typeof paintHeight==='number'?paintHeight:props.render_height??props.height??0);
      const base=Number(typeof paintBase==='number'?paintBase:props.render_min_height??props.min_height??0);
      if(height<=base||this.map.getPaintProperty(feature.layer.id,'fill-extrusion-opacity')===0)continue;
      const polygons=feature.geometry.type==='Polygon'?[feature.geometry.coordinates]:feature.geometry.type==='MultiPolygon'?feature.geometry.coordinates:[];
      for(const polygon of polygons) {
        const rings=polygon.map(ring=>ring.map(position=>{const coord=this.engine.MercatorCoordinate.fromLngLat(position);return new THREE.Vector2((coord.x-this.origin.x)/this.scale,-(coord.y-this.origin.y)/this.scale);}));
        const shape=new THREE.Shape(rings[0]);for(const ring of rings.slice(1))shape.holes.push(new THREE.Path(ring));
        const geometry=new THREE.ExtrudeGeometry(shape,{depth:height-base,bevelEnabled:false,steps:1});
        const building=new THREE.Mesh(geometry,this.pickMaterial);building.position.z=base;building.updateMatrixWorld(true);
        const intersection=ray.intersectObject(building)[0];geometry.dispose();
        if(intersection&&intersection.distance<distance-.05)return true;
      }
    }
    return false;
  }
  onRemove() {
    for(const key of ['geometry','roofGeometry','frontGeometry','wheelGeometry','edgeGeometry','shadowGeometry','bodyMaterial','roofMaterial','focusBodyMaterial','focusRoofMaterial','frontMaterial','wheelMaterial','edgeMaterial','shadowMaterial','pickMaterial'])this[key]?.dispose();
    this.renderer?.dispose();this.meshes.clear();
  }
}
