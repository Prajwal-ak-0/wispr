# Murmur for Google Meet

1. Open `arc://extensions` in Arc.
2. Turn on **Developer mode**.
3. Choose **Load unpacked** and select this `ArcExtension` folder.

The extension observes only `meet.google.com`. It sends join, heartbeat, and leave events to Murmur
on `127.0.0.1:49413`; it does not read or upload meeting audio or transcript content.
