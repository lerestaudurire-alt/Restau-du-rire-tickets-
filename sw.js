const V="lrr-v124",KEEP=[V,"lrr-posters","lrr-img","lrr-data"],SHELL=["./","index.html","manifest.json","icon-192.png","icon-512.png","logo-horizontal.png","apple-touch-icon.png"],QRLIB=["https://cdnjs.cloudflare.com/ajax/libs/jsQR/1.4.0/jsQR.min.js","https://cdn.jsdelivr.net/npm/jsqr@1.4.0/dist/jsQR.js"];
self.addEventListener("install",e=>{e.waitUntil(caches.open(V).then(c=>c.addAll(SHELL).then(()=>Promise.all(QRLIB.map(u=>c.add(u).catch(()=>{}))))).then(()=>self.skipWaiting()))});
self.addEventListener("activate",e=>{e.waitUntil(caches.keys().then(k=>Promise.all(k.filter(x=>KEEP.indexOf(x)<0).map(x=>caches.delete(x)))).then(()=>self.clients.claim()))});
/* Affiches et logos (Supabase Storage public) : copie locale d'abord, mise à jour en arrière-plan */
async function img(e){
 const url=e.request.url,c=await caches.open("lrr-img");
 const m=(await c.match(url))||(await caches.match(url));
 const net=fetch(url,{mode:"cors",credentials:"omit"}).catch(()=>fetch(e.request)).then(r=>{if(r&&r.ok&&r.status===200)c.put(url,r.clone());return r});
 if(m){e.waitUntil(net.catch(()=>{}));return m}
 try{return await net}catch(x){return Response.error()}
}
self.addEventListener("fetch",e=>{
 const u=new URL(e.request.url);
 if(e.request.method!=="GET")return;
 if(new URL(e.request.url).pathname.indexOf("/evenement/")>-1)return;
 if(u.hostname.endsWith("supabase.co")){
  if(u.pathname.indexOf("/storage/v1/object/public/")>-1&&!e.request.headers.get("range"))e.respondWith(img(e));
  return;
 }
 if(QRLIB.indexOf(e.request.url)>-1){e.respondWith(caches.match(e.request,{ignoreVary:true}).then(m=>m||fetch(e.request).then(r=>{const c=r.clone();caches.open(V).then(x=>x.put(e.request,c));return r})));return}
 if(u.origin!==location.origin&&u.hostname!=="cdnjs.cloudflare.com")return;
 e.respondWith(fetch(e.request).then(r=>{const c=r.clone();caches.open(V).then(x=>x.put(e.request,c));return r}).catch(()=>caches.match(e.request).then(m=>m||caches.match("index.html"))));
});
