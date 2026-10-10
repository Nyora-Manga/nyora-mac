// This file is copied to each distribution repository. No application source is needed.
import {createHash} from 'node:crypto';
const upstream='Nyora-Manga/nyora-desktop';
const repository=process.env.GITHUB_REPOSITORY;
const platform={'Nyora-Manga/nyora-mac':'darwin','Nyora-Manga/nyora-windows':'win32','Nyora-Manga/nyora-linux':'linux'}[repository];
if(!platform||!process.env.GH_TOKEN)throw new Error('Unknown distribution repository or missing token');
async function api(repo,path,{method='GET',body,allowMissing=false}={}){
 const token=repo===upstream?process.env.UPSTREAM_TOKEN:process.env.GH_TOKEN;
 const response=await fetch(`https://api.github.com/repos/${repo}${path}`,{method,headers:{Accept:'application/vnd.github+json','X-GitHub-Api-Version':'2022-11-28',...(token?{Authorization:`Bearer ${token}`} : {}),'Content-Type':'application/json'},...(body?{body:JSON.stringify(body)}:{})});
 if(response.status===404&&allowMissing)return null;
 if(!response.ok)throw new Error(`GitHub API ${response.status} for ${repo}${path}`);
 return response.status===204?null:response.json();
}
await api(upstream,''); // Fail clearly if a private source repository needs a read token.
const source=await api(upstream,'/releases/latest',{allowMissing:true});
if(!source){console.log('No completed desktop release yet');process.exit(0);}
async function download(name){
 const asset=source.assets.find(a=>a.name===name);
 if(!asset)throw new Error(`Upstream release is missing ${name}`);
 const token=process.env.UPSTREAM_TOKEN;
 const response=await fetch(`https://api.github.com/repos/${upstream}/releases/assets/${asset.id}`,{headers:{Accept:'application/octet-stream',...(token?{Authorization:`Bearer ${token}`}:{})}});
 if(!response.ok)throw new Error(`Download failed (${response.status})`);
 return Buffer.from(await response.arrayBuffer());
}
const manifest=JSON.parse((await download('release-manifest.json')).toString('utf8'));
if(manifest.schema!==1||!manifest.complete||manifest.tag!==source.tag_name||!/^v\d+\.\d+\.\d+$/.test(manifest.tag)||!Array.isArray(manifest.targets)||manifest.targets.length!==6)throw new Error('Incomplete central release');
const wanted=manifest.targets.filter(t=>t.platform===platform);
if(wanted.length!==2||new Set(wanted.map(t=>t.arch)).size!==2||!wanted.every(t=>['x64','arm64'].includes(t.arch)))throw new Error('Both platform architectures are required');
let release=await api(repository,`/releases/tags/${manifest.tag}`,{allowMissing:true});
if(release&&!release.draft){
 const expected=wanted.flatMap(t=>t.files.map(f=>f.name)).concat(['SHA256SUMS.txt','release-manifest.json']);
 if(!expected.every(name=>release.assets.some(a=>a.name===name)))throw new Error('Existing published mirror is incomplete; refusing to overwrite it');
 console.log(`Already mirrored ${manifest.tag}`);process.exit(0);
}
const files=[];
for(const target of wanted)for(const file of target.files){
 if(!/^Nyora-[A-Za-z0-9._-]+$/.test(file.name)||!Number.isSafeInteger(file.bytes)||file.bytes<1||file.bytes>2_000_000_000)throw new Error('Unsafe release asset metadata');
 const bytes=await download(file.name);
 if(bytes.length!==file.bytes||createHash('sha256').update(bytes).digest('hex')!==file.sha256)throw new Error(`Checksum mismatch for ${file.name}`);
 files.push({name:file.name,bytes});
}
files.push({name:'SHA256SUMS.txt',bytes:Buffer.from(wanted.flatMap(t=>t.files.map(f=>`${f.sha256}  ${f.name}`)).sort().join('\n')+'\n')});
files.push({name:'release-manifest.json',bytes:Buffer.from(JSON.stringify(manifest,null,2)+'\n')});
const label={darwin:'macOS',win32:'Windows',linux:'Linux'}[platform];
const body=`Nyora ${manifest.tag} for ${label} — Electron desktop.\n\nDownload **x64** for Intel/AMD 64-bit or **arm64** for Apple Silicon/ARM devices. Java and Chromium are bundled; no separate server is required.\n\n[Installation and migration instructions](https://github.com/${repository}/blob/HEAD/INSTALL.md) · [Canonical release with all six builds](https://github.com/${upstream}/releases/tag/${manifest.tag})\n\nThese files are copied unchanged and SHA-256 verified against the canonical release. The older native desktop implementation is deprecated. Builds are unsigned/not notarized; verify SHA256SUMS.txt.\n\nSource commit: ${manifest.commit}.\n`;
if(!release)release=await api(repository,'/releases',{method:'POST',body:{tag_name:manifest.tag,name:`Nyora ${manifest.tag} — ${label}`,body,draft:true,prerelease:false}});
for(const asset of release.assets||[])await api(repository,`/releases/assets/${asset.id}`,{method:'DELETE'});
for(const file of files){
 const response=await fetch(`https://uploads.github.com/repos/${repository}/releases/${release.id}/assets?name=${encodeURIComponent(file.name)}`,{method:'POST',headers:{Authorization:`Bearer ${process.env.GH_TOKEN}`,'Content-Type':'application/octet-stream'},body:file.bytes});
 if(!response.ok)throw new Error(`Mirror upload failed (${response.status})`);
}
release=await api(repository,`/releases/${release.id}`,{method:'PATCH',body:{draft:false,make_latest:'true',body}});
console.log(release.html_url);
