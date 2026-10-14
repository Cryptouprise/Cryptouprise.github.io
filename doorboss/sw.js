/* DoorBoss service worker — notifications only. No offline caching here on purpose: the app already queues
   knocks in localStorage, and caching the shell would make AI Studio deploys look stale. Serve this at /sw.js. */
self.addEventListener('install', () => self.skipWaiting());
self.addEventListener('activate', e => e.waitUntil(self.clients.claim()));

self.addEventListener('push', e => {
  let data = {};
  try { data = e.data ? e.data.json() : {}; } catch (_) { data = { title: 'DoorBoss', body: e.data ? e.data.text() : '' }; }
  const title = data.title || 'DoorBoss';
  e.waitUntil(self.registration.showNotification(title, {
    body: data.body || '', tag: data.tag || 'doorboss', icon: 'icon.png', badge: 'icon.png',
    data: { url: data.url || '/doors', propertyId: data.propertyId || null }, renotify: !!data.renotify
  }));
});

self.addEventListener('notificationclick', e => {
  e.notification.close();
  const url = (e.notification.data && e.notification.data.url) || '/doors';
  e.waitUntil(self.clients.matchAll({ type: 'window', includeUncontrolled: true }).then(list => {
    for (const c of list) { if ('focus' in c) { c.navigate ? c.navigate(url) : null; return c.focus(); } }
    return self.clients.openWindow(url);
  }));
});
