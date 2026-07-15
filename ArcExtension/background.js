chrome.runtime.onMessage.addListener((message, _sender, sendResponse) => {
  if (message?.type !== "murmur-meet-event") return;
  fetch("http://127.0.0.1:49413/event", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(message.event)
  }).then(() => sendResponse({ ok: true }))
    .catch((error) => sendResponse({ ok: false, error: String(error) }));
  return true;
});
