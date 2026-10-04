import { XMLParser } from 'fast-xml-parser';
import { Resvg } from '@resvg/resvg-js';
import paper from 'paper';
import { validateSVG } from './assets.mjs';

const identity = () => [1, 0, 0, 1, 0, 0];
function multiply(a, b) {
  return [a[0]*b[0]+a[2]*b[1], a[1]*b[0]+a[3]*b[1], a[0]*b[2]+a[2]*b[3], a[1]*b[2]+a[3]*b[3], a[0]*b[4]+a[2]*b[5]+a[4], a[1]*b[4]+a[3]*b[5]+a[5]];
}
function transform(text) {
  let matrix = identity(), end = 0;
  const pattern = /([a-zA-Z]+)\(([^)]*)\)/g;
  for (const match of text.matchAll(pattern)) {
    if (text.slice(end, match.index).trim().replace(/,/g, '')) throw new Error('Invalid transform');
    const v = match[2].trim().split(/[\s,]+/).map(Number);
    if (v.some(n => !Number.isFinite(n))) throw new Error('Invalid transform numbers');
    let m;
    if (match[1] === 'matrix' && v.length === 6) m = v;
    else if (match[1] === 'translate' && [1, 2].includes(v.length)) m = [1,0,0,1,v[0],v[1] ?? 0];
    else if (match[1] === 'scale' && [1, 2].includes(v.length)) m = [v[0],0,0,v[1] ?? v[0],0,0];
    else if (match[1] === 'rotate' && [1, 3].includes(v.length)) {
      const a = v[0]*Math.PI/180, c = Math.cos(a), s = Math.sin(a), x = v[1] ?? 0, y = v[2] ?? 0;
      m = [c,s,-s,c,x-c*x+s*y,y-s*x-c*y];
    } else throw new Error(`Unsupported native transform: ${match[1]}`);
    matrix = multiply(matrix, m); end = match.index + match[0].length;
  }
  if (text.slice(end).trim()) throw new Error('Invalid transform suffix');
  return matrix;
}
const attributes = n => Object.fromEntries(Object.entries(n[':@'] ?? {}).map(([k,v]) => [k.slice(2),String(v)]));
const inheritedKeys = ['fill','stroke','fill-opacity','stroke-opacity','stroke-width','stroke-linecap','stroke-linejoin'];

export function convertCharacter(svg, entry, palette) {
  validateSVG(svg);
  const parsed = new XMLParser({ preserveOrder: true, ignoreAttributes: false, processEntities: false, parseAttributeValue: false }).parse(svg);
  const root = attributes(parsed[0]);
  let [x,y,w,h] = root.viewBox.split(/[\s,]+/).map(Number);
  if (root.overflow === 'visible') {
    const box = new Resvg(svg, { font: { loadSystemFonts: false } }).getBBox();
    if (box && (box.x < 0 || box.y < 0 || box.x+box.width > w || box.y+box.height > h)) {
      const left=Math.min(0,box.x)-1, top=Math.min(0,box.y)-1;
      const right=Math.max(w,box.x+box.width)+1, bottom=Math.max(h,box.y+box.height)+1;
      x+=left; y+=top; w=right-left; h=bottom-top;
    }
  }
  const scale = Math.min(200/w,200/h);
  const mapping = new Map(Object.entries(palette).map(([key,value]) => [value.toLowerCase(), `@${key}`]));
  const color = value => mapping.get(value.toLowerCase()) ?? value;
  const number = (a,k,fallback=0) => {
    const n = a[k] === undefined ? fallback : Number(a[k]);
    if (!Number.isFinite(n) || Math.abs(n)>100000) throw new Error(`Invalid geometry ${k}`);
    return n;
  };
  const clips = new Map();
  function collect(nodes) {
    for (const n of nodes) {
      if (n.clipPath) {
        const a=attributes(n), paths=n.clipPath.filter(c=>c.path);
        if (paths.length!==1 || n.clipPath.length!==1 || a.transform || attributes(paths[0]).transform) throw new Error('Only single-path clipping is supported');
        clips.set(a.id, attributes(paths[0]).d);
      }
      for (const [key,children] of Object.entries(n)) if (key!==':@' && Array.isArray(children)) collect(children);
    }
  }
  collect(parsed);
  paper.setup(new paper.Size(200,200));
  function convert(nodes, inherited={fill:'#000000',stroke:'none'}, clip=null) {
    const out=[];
    for (const raw of nodes) {
      const tag=Object.keys(raw).find(k=>k!==':@');
      if (tag==='defs') continue;
      if (tag==='#text') continue;
      const a=attributes(raw), resolved={...inherited};
      for (const key of inheritedKeys) if (a[key]!==undefined) resolved[key]=a[key];
      for (const unsupported of ['stroke-dasharray','stroke-dashoffset']) if (a[unsupported]) throw new Error(`Unsupported native style: ${unsupported}`);
      if (a['fill-rule']==='evenodd') throw new Error('Even-odd paths must be flattened first');
      const activeClip=a['clip-path'] ? clips.get(a['clip-path'].slice(5,-1)) : clip;
      if (a['clip-path'] && !activeClip) throw new Error('Missing clipping path');
      if (activeClip && a.transform) throw new Error('Transformed clipping must be flattened first');
      const style={};
      if (a.opacity!==undefined) style.o=number(a,'opacity');
      const node={t:tag,st:{idle:style}};
      if (a.transform) node.m=transform(a.transform);
      if (['svg','g'].includes(tag)) {
        node.k=convert(raw[tag],resolved,activeClip);
      } else {
        Object.assign(style,{f:color(resolved.fill),s:color(resolved.stroke)});
        for (const [key,alias] of [['fill-opacity','fo'],['stroke-opacity','so'],['stroke-width','sw']]) if (resolved[key]!==undefined) style[alias]=number(resolved,key);
        if (resolved['stroke-linecap']) style.cap=resolved['stroke-linecap'];
        if (resolved['stroke-linejoin']) style.join=resolved['stroke-linejoin'];
        if (activeClip) {
          if (tag!=='rect' || a.rx || a.ry || resolved.stroke!=='none') throw new Error('Only flat rectangle clip layers are supported');
          const boundary=new paper.Path(activeClip), rectangle=new paper.Path.Rectangle({point:[number(a,'x'),number(a,'y')],size:[number(a,'width'),number(a,'height')]});
          const intersection=boundary.intersect(rectangle,{insert:false});
          node.t='path'; node.d=intersection.pathData;
          boundary.remove(); rectangle.remove(); intersection.remove();
          if (!node.d) continue;
        } else if (tag==='path') node.d=a.d;
        else if (tag==='circle' || tag==='ellipse') Object.assign(node,{cx:number(a,'cx'),cy:number(a,'cy'),rx:number(a,tag==='circle'?'r':'rx'),ry:number(a,tag==='circle'?'r':'ry')});
        else if (tag==='rect') {
          Object.assign(node,{x:number(a,'x'),y:number(a,'y'),w:number(a,'width'),h:number(a,'height')});
          if (a.rx) node.rx=number(a,'rx');
          if (a.ry && a.ry!==a.rx) throw new Error('Unequal corner radii must be flattened first');
        } else throw new Error(`Unsupported native primitive: ${tag}`);
      }
      out.push(node);
    }
    return out;
  }
  const tree={t:'svg',st:{idle:{}},k:[{t:'g',rig:true,body:true,st:{idle:{}},k:[{t:'g',m:[scale,0,0,scale,(200-w*scale)/2-x*scale,(200-h*scale)/2-y*scale],st:{idle:{}},k:convert(parsed)}]}]};
  paper.project.remove();
  return {id:entry.id,name:entry.name,role:entry.role ?? entry.name,family:'classic',look:0,colors:{p:palette.p,s:palette.s ?? palette.p,a:palette.a ?? palette.p,bg:'#F4EFEA',ink:palette.ink ?? '#1C1A19',skin:'#F6CFB0'},tree};
}
