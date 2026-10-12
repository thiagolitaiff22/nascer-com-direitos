// Deixa o aplicativo (página de cadastro) abrir mesmo sem internet; o envio espera o sinal voltar
var CACHE = 'nascer-campo-v11', ARQS = ['campo.html', 'vendor/jspdf.umd.min.js', 'campo.webmanifest', 'img/logo-nascer.png', 'img/logo-nascer-t.png', 'img/icone-180.png', 'img/icone-192.png', 'img/icone-512.png'];
self.addEventListener('install', function(e){ e.waitUntil(caches.open(CACHE).then(function(c){ return c.addAll(ARQS); })); self.skipWaiting(); });
self.addEventListener('activate', function(e){ e.waitUntil(caches.keys().then(function(k){ return Promise.all(k.filter(function(n){ return n !== CACHE; }).map(function(n){ return caches.delete(n); })); })); self.clients.claim(); });
self.addEventListener('fetch', function(e){
  var u = new URL(e.request.url);
  if (e.request.method !== 'GET' || u.origin !== location.origin) return;
  // rede primeiro (pega versão nova); sem internet, usa a cópia guardada
  e.respondWith(fetch(e.request).then(function(r){ var c = r.clone(); caches.open(CACHE).then(function(x){ x.put(e.request, c); }); return r; })
    .catch(function(){ return caches.match(e.request, { ignoreSearch: true }); }));
});
