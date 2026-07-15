(() => {
  let joined = false;
  let heartbeat = null;
  let leaveTimer = null;
  const leaveGraceMilliseconds = 15000;

  const leaveLabels = ["leave call", "leave meeting", "end call"];
  const isJoined = () => Array.from(document.querySelectorAll("button,[role='button']")).some((element) => {
    const label = `${element.getAttribute("aria-label") || ""} ${element.getAttribute("data-tooltip") || ""}`.toLowerCase();
    return leaveLabels.some((candidate) => label.includes(candidate));
  });
  const title = () => document.title.replace(/\s*-\s*Google Meet\s*$/i, "").trim() || "Google Meet";
  const send = (kind) => chrome.runtime.sendMessage({
    type: "murmur-meet-event",
    event: { kind, title: title(), url: location.href }
  }).catch(() => {});

  const update = () => {
    const nowJoined = isJoined();
    if (nowJoined && !joined) {
      clearTimeout(leaveTimer);
      leaveTimer = null;
      joined = true;
      send("joined");
      heartbeat = setInterval(() => send("heartbeat"), 3000);
    } else if (nowJoined && joined) {
      clearTimeout(leaveTimer);
      leaveTimer = null;
    } else if (!nowJoined && joined && !leaveTimer) {
      // Meet frequently removes/rebuilds its controls during layout and device changes. Only
      // treat a continuously absent leave button as a real departure.
      leaveTimer = setTimeout(() => {
        if (isJoined()) { leaveTimer = null; return; }
        joined = false;
        clearInterval(heartbeat);
        heartbeat = null;
        leaveTimer = null;
        send("left");
      }, leaveGraceMilliseconds);
    }
  };

  new MutationObserver(update).observe(document.documentElement, { subtree: true, childList: true, attributes: true });
  setInterval(update, 1500);
  addEventListener("pagehide", () => {
    clearTimeout(leaveTimer);
    clearInterval(heartbeat);
    if (joined) send("left");
  });
  update();
})();
