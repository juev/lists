// The service worker of the web interface. It shows what the server sends through Web Push (R144)
// and keeps the page for when the server cannot be reached (R147). Answers of `/api/` are never kept.
"use strict";
const CACHE = "lists-shell-1";
const SHELL = ["/", "/manifest.json", "/icon.svg", "/icon-32.png", "/icon-180.png", "/icon-192.png", "/icon-512.png"];

self.addEventListener("install", e => {
  e.waitUntil(caches.open(CACHE).then(c => c.addAll(SHELL)).catch(() => {}).then(() => self.skipWaiting()));
});
self.addEventListener("activate", e => {
  e.waitUntil(caches.keys().then(keys => Promise.all(keys.filter(k => k !== CACHE).map(k => caches.delete(k)))).then(() => self.clients.claim()));
});

// The network first, so that a new version of the page is taken at once; the copy is for when there is no answer.
self.addEventListener("fetch", e => {
  const url = new URL(e.request.url);
  if (e.request.method !== "GET" || url.origin !== location.origin || !SHELL.includes(url.pathname)) return;
  e.respondWith(fetch(e.request).then(res => {
    if (res.ok) { const copy = res.clone(); e.waitUntil(caches.open(CACHE).then(c => c.put(url.pathname, copy))); }
    return res;
  }).catch(() => caches.match(url.pathname).then(hit => hit || Response.error())));
});

const RU = {
  "Due": "Срок", "Today": "сегодня", "Tomorrow": "завтра", "Yesterday": "вчера",
  "Tasks due today or overdue": "Задач на сегодня и просроченных", "Notifications from Lists come like this.": "Так приходят уведомления Lists."
};
const ru = (self.navigator.language || "en").toLowerCase().startsWith("ru");
const t = s => (ru && RU[s]) || s;
const locale = ru ? "ru" : "en";
const pad = n => String(n).padStart(2, "0");
const iso = d => `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`;
const parseDay = v => { const [y, m, d] = v.slice(0, 10).split("-").map(Number); return new Date(y, m - 1, d); };

// R36, #280: the day is named as it is now, when the notification is shown: "Due: today, 18:30".
function dueText(v) {
  const diff = Math.round((parseDay(v) - parseDay(iso(new Date()))) / 86400000);
  const day = diff === 0 ? t("Today") : diff === 1 ? t("Tomorrow") : diff === -1 ? t("Yesterday")
    : parseDay(v).toLocaleDateString(locale, { weekday: "short", day: "numeric", month: "short" });
  return `${t("Due")}: ${day.toLowerCase()}${v.length > 10 ? ", " + v.slice(11, 16) : ""}`;
}

self.addEventListener("push", e => {
  let m = {};
  try { m = e.data ? e.data.json() : {}; } catch {}
  let title = "Lists", body = "", url = "/#scope=today";
  if (m.kind === "summary") body = `${t("Tasks due today or overdue")}: ${m.count}`;
  else if (m.kind === "test") body = t("Notifications from Lists come like this.");
  else {
    title = m.title || "Lists";
    body = m.due ? dueText(m.due) : "";
    if (m.task) url = "/#" + new URLSearchParams([["scope", "all"], ["open", m.task]]);
  }
  // A notification with the same key replaces the one shown before.
  e.waitUntil(self.registration.showNotification(title, { body, tag: m.key || "lists", icon: "/icon-192.png", data: { url } }));
});

// The page that is open goes to the task; without one, a new window opens there.
self.addEventListener("notificationclick", e => {
  e.notification.close();
  const url = new URL((e.notification.data && e.notification.data.url) || "/", location.origin).href;
  e.waitUntil(self.clients.matchAll({ type: "window", includeUncontrolled: true }).then(list => {
    const open = list.find(c => new URL(c.url).origin === location.origin);
    if (!open) return self.clients.openWindow(url);
    return open.navigate(url).then(c => (c || open).focus()).catch(() => open.focus());
  }));
});

const keyBytes = text => Uint8Array.from(atob(text.replace(/-/g, "+").replace(/_/g, "/")), c => c.charCodeAt(0));

// The browser replaced the subscription: the server learns the new one, with the settings of the old.
self.addEventListener("pushsubscriptionchange", e => {
  e.waitUntil((async () => {
    const { key } = await fetch("/api/notifications/key").then(r => r.json());
    const sub = e.newSubscription || await self.registration.pushManager.subscribe({ userVisibleOnly: true, applicationServerKey: keyBytes(key) });
    await fetch("/api/notifications/subscribe", {
      method: "POST", headers: { "Content-Type": "application/json", "X-Lists": "1" },
      body: JSON.stringify({ ...sub.toJSON(), zone: Intl.DateTimeFormat().resolvedOptions().timeZone || "", offset: -new Date().getTimezoneOffset(), replaces: e.oldSubscription ? e.oldSubscription.endpoint : null })
    });
  })().catch(() => {}));
});
