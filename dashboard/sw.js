/* ═══════════════════════════════════════════════════════════════════════════
   LevelGas · Service Worker · red primero para el documento
   ───────────────────────────────────────────────────────────────────────────
   POR QUE EXISTE ESTE ARCHIVO (2026-09-08)

   La version anterior no interceptaba nada ("passthrough"), con la idea de
   dejar que el navegador se encargara de traer index.html actualizado. En la
   practica eso deja el HTML en manos de la cache HTTP del navegador, y Safari
   en iOS la retiene durante semanas. Un iPhone quedo sirviendo una copia
   anterior al 23-ago: sin los parches de seguridad de agosto, y con la logica
   vieja que ofrecia "crear una clave nueva" a un equipo que ya tenia clave.
   El cliente ve eso y asume que perdio su cuenta.

   ESTRATEGIA: solo se intercepta el DOCUMENTO HTML de este directorio, y con
   red primero. Siempre se pide la version de red saltando la cache HTTP
   (cache:'no-store'); la copia guardada se usa unicamente si la red falla, de
   modo que el dashboard siga abriendo sin señal. Todo lo demas —Supabase, los
   CDN, las fuentes, los iconos, el manifest— pasa sin tocarse.

   SI ALGO SALE MAL: publicar un sw.js cuyo 'install' llame a
   self.registration.unregister() y recargue los clientes. skipWaiting() +
   clients.claim() hacen que el reemplazo tome control en la siguiente visita.
   ═══════════════════════════════════════════════════════════════════════════ */

const CACHE = 'levelgas-v10-red-primero-2026-09-08';

self.addEventListener('install', () => {
    // Sin precarga: no queremos volver a fijar una version del HTML.
    self.skipWaiting();
});

self.addEventListener('activate', (event) => {
    event.waitUntil((async () => {
        if (self.caches) {
            const claves = await caches.keys();
            await Promise.all(
                claves.filter(k => k.startsWith('levelgas-') && k !== CACHE)
                      .map(k => caches.delete(k))
            );
        }
        await self.clients.claim();
    })());
});

/* Solo el documento: una navegacion, o un GET que pide text/html. */
function esDocumento(req){
    if (req.mode === 'navigate') return true;
    const accept = req.headers.get('accept') || '';
    return req.method === 'GET' && accept.includes('text/html');
}

self.addEventListener('fetch', (event) => {
    const req = event.request;
    if (req.method !== 'GET') return;

    let url;
    try { url = new URL(req.url); } catch(e){ return; }

    // Otro origen (Supabase, jsdelivr, cdnjs, Google Fonts): no intervenir.
    if (url.origin !== self.location.origin) return;
    if (!esDocumento(req)) return;

    /* Clave canonica: sin querystring. Asi ?device=...&v=... reutiliza la
       misma entrada en vez de llenar la cache de copias identicas. */
    const clave = new Request(url.origin + url.pathname);

    event.respondWith((async () => {
        try {
            const fresca = await fetch(url.href, {
                cache: 'no-store',            // salta la cache HTTP del navegador
                credentials: 'same-origin'
            });
            if (fresca && fresca.ok && fresca.type === 'basic' && self.caches) {
                try {
                    const c = await caches.open(CACHE);
                    await c.put(clave, fresca.clone());
                } catch(e){ /* cuota llena o modo privado: no es critico */ }
            }
            return fresca;
        } catch (eRed) {
            /* Sin red: servir la ultima copia buena si la hay. El acceso a
               caches va en su propio try porque en modo privado puede lanzar,
               y una excepcion aqui dejaria la navegacion en pantalla blanca:
               peor que el problema que este worker viene a resolver. */
            try {
                if (self.caches) {
                    const guardada = await caches.match(clave);
                    if (guardada) return guardada;
                }
            } catch(e){ /* sin respaldo disponible */ }
            throw eRed;
        }
    })());
});
