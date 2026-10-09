// Synthetic, deterministic cloud-compute benchmark. NO JAV source or user data.
import {createHash} from 'node:crypto';
import {cpus, freemem, totalmem} from 'node:os';
import {performance} from 'node:perf_hooks';

const mib=1024*1024;
const arg=process.argv.find(x=>x.startsWith('--memory-mib='));
const memoryMiB=arg?Number(arg.split('=')[1]):0;
if(!Number.isInteger(memoryMiB)||memoryMiB<0||memoryMiB>768)throw Error('Invalid memory target');
const cycles=400000;
const data=Buffer.alloc(128,0x6e);
const started=performance.now();
let hash=Buffer.alloc(32);
for(let i=0;i<cycles;i++){
  data.writeUInt32LE(i,0);
  hash=createHash('sha256').update(data).digest();
}
const cpuMs=Math.round(performance.now()-started);
const digest=hash.toString('hex');
console.log('CPU_BENCH',JSON.stringify({cycles,cpuMs,digest}));

let memoryMs=null,readback=0,peakRssMiB=Math.round(process.memoryUsage().rss/mib);
if(memoryMiB){
  const begin=performance.now();
  const slab=Buffer.allocUnsafe(memoryMiB*mib);
  for(let i=0;i<slab.length;i+=4096)slab[i]=i&255;
  for(let i=0;i<slab.length;i+=4096)readback^=slab[i];
  memoryMs=Math.round(performance.now()-begin);
  peakRssMiB=Math.max(peakRssMiB,Math.round(process.memoryUsage().rss/mib));
  console.log('MEM_BENCH',JSON.stringify({allocatedMiB:memoryMiB,peakRssMiB,memoryMs,readback}));
}
const result={cycles,cpuMs,digest,memoryMiB,memoryMs,peakRssMiB,cpus:cpus().length,osTotalMiB:Math.round(totalmem()/mib),osFreeMiB:Math.round(freemem()/mib),node:process.version,syntheticOnly:true};
console.log('BENCH_RESULT_JSON='+JSON.stringify(result));
