# Realtime Synchronised Internet Radio: Protocols & Architecture Guide

## Executive Summary

The core tension in synchronised internet radio is between the **pull model** (HLS, MPEG-DASH, Icecast) where clients independently fetch segments and inevitably diverge, and the **push/clock model** where a shared reference time drives playback across all listeners simultaneously. True "traditional radio" synchronisation — where all listeners hear the same sample at the same instant — requires abandoning segment-pull delivery and instead anchoring playback to a shared wallclock. The approaches below are ranked from tightest to loosest synchronisation.

***

## Why HLS Cannot Be "Super-Realtime"

HLS (and its low-latency variant LL-HLS) is fundamentally a segment-pull protocol. Clients periodically poll an `.m3u8` playlist, download partial segments (as short as 200–500 ms in LL-HLS), and begin playback independently. Even with parts as small as 200 ms and preload hints, `glass-to-glass` latency of LL-HLS in production sits at **1.5–3 seconds**, and Cloudflare's own LL-HLS implementation targets under 10 seconds. The crucial problem isn't aggregate latency — it's that each client buffers at a different offset, so two listeners are never guaranteed to play the same sample simultaneously. Shrinking segments to 10 ms (your "0.01 seconds" idea) would shatter compatibility: m3u8 parsers, CDN caches, and media players all assume segments in the hundreds-of-milliseconds range. Below 200 ms, segment overhead (HTTP round-trips, playlist polling) exceeds the segment duration itself, causing perpetual stalls.[^1][^2][^3]

***

## The Right Mental Model: Clock Synchronisation vs. Stream Buffering

Traditional AM/FM radio achieves perfect synchronisation by transmitting a **single electromagnetic signal** that all receivers decode simultaneously. Internet radio must replicate the "single reference time" property via software. There are two main strategies:

1. **Deterministic offset approach**: Server calculates "what sample should be playing right now" as a function of wallclock time. Clients ask this question, seek to the answer, and periodically re-sync. No shared state, fully stateless — but requires reliable `NTP`/`SNTP` on both client and server, and seekable media files.[^4]

2. **Timestamped packet push**: Server tags every audio packet with an absolute timestamp (NTP/PTP wall time). Clients buffer a small amount and schedule playback at the exact timestamp, adjusting playback rate by tiny amounts (removing/duplicating single samples) to stay locked.[^5][^6]

Both work. Strategy 1 is simpler and browser-compatible; Strategy 2 achieves sub-millisecond precision but requires native client support.

***

## Protocol Deep-Dive

### 1. RTP/RTCP — The Gold Standard for Tight Sync

**Real-Time Transport Protocol (RTP)** with its companion **RTCP** (RTP Control Protocol) is the closest internet equivalent to broadcast timing. RTP embeds a monotonic timestamp on every packet; RTCP Sender Reports (SRs) periodically provide a **NTP↔RTP timestamp mapping** that lets any receiver calculate the absolute wallclock time of every sample. This is exactly how WebRTC achieves audio/video lip sync internally.[^7][^8][^9][^10]

Key synchronisation properties:
- RTCP SR messages correlate RTP stream timestamps to NTP wallclock every few seconds (configurable)[^7]
- Receivers use the NTP/RTP mapping to compute absolute delivery timestamps per-packet[^7]
- Synchronisation across independently clocked devices is theoretically achievable to the RTP clock resolution (1/48000 s ≈ 20 µs for 48 kHz audio)[^9]

**The scalability catch**: Raw RTP/RTCP is a UDP unicast or multicast protocol. IP multicast works inside a single LAN/datacenter efficiently but is generally blocked or not supported at ISP level for public internet. Unicast RTP to thousands of listeners requires per-connection server load comparable to unicast UDP, with no CDN cacheability.[^11]

**GStreamer** has excellent RTP sync support, including RFC 6051 rapid sync that injects NTP/RTP mappings into packet headers for instant receiver synchronisation without waiting for RTCP.[^7]

***

### 2. AES67 — Professional Broadcast AoIP

**AES67** is the audio engineering industry's open standard for high-performance audio over IP. It sits on top of RTP and adds:[^12]

- **IEEE 1588v2 PTP** (Precision Time Protocol) for system-wide clock distribution — achieves **< 2 ms** synchronisation accuracy across the network, with theoretical nanosecond-range precision using hardware timestamping[^13][^14][^15]
- Uncompressed 24-bit, 48 kHz audio (or 44.1/96 kHz variants)[^16]
- 1 ms packet intervals[^16]
- Interoperability with RAVENNA, Dante, Livewire, Q-LAN[^12]

AES67 is used in professional radio studios, broadcast chains, and live events. It is **not** designed for internet-scale delivery — it assumes a controlled LAN/WAN with PTP-capable switches. It's relevant to your workflow as the ingest and internal production protocol, with a separate internet delivery mechanism for the public stream.

***

### 3. Snapcast — Sub-Millisecond LAN/VPN Sync

**Snapcast** is an open-source synchronous multiroom audio player specifically designed to keep all clients time-locked to the server. Its approach is elegant:[^6][^5]

- Server captures PCM audio, chunks it, and **tags each chunk with the local server time**[^5]
- Each client continuously synchronises its clock against the server[^6]
- Clients buffer chunks and schedule playback at the tagged timestamp using ALSA/PipeWire[^5]
- Drift correction works by removing or duplicating single audio samples (at 48 kHz, one sample = ~0.02 ms)[^6]
- **Typical synchronisation deviation: < 0.2 ms**[^17]

Supported codecs: PCM (lossless, high bandwidth), FLAC (lossless compressed), Vorbis, Opus. Opus is excellent for internet delivery — it has only 26.5 ms algorithmic delay by default and can be tuned to as low as 5 ms.[^18][^5]

Snapcast's limitation: it's a **TCP-based custom protocol** without native browser support. Clients need the `snapclient` binary (Linux/macOS/Windows/Android). For a public internet radio station, you'd either run Snapcast for native client users or bridge it to a web-compatible delivery for browser users.

***

### 4. Bark — UDP Multicast with Built-In PTP-like Sync

**Bark** is a newer Rust-based open-source project that transmits uncompressed 48 kHz float32 audio over **UDP multicast** with built-in time synchronisation. It claims synchronisation accuracy of **hundreds of microseconds under ideal conditions, typically within 1 ms**. It uses a Speex-based resampler to adjust playback rate and keep receivers locked without requiring a high-precision NTP server.[^19][^20]

Like Snapcast, Bark is designed for **LAN/controlled networks** — UDP multicast is generally blocked on public internet routers. However, over a VPN (WireGuard, Tailscale) it works across sites. For a public-facing internet radio, Bark is a strong choice for the studio/internal distribution layer but needs a different last-mile protocol.[^11]

***

### 5. WebRTC (with SFU) — Sub-Second, Scalable, Browser-Native

**WebRTC** is natively browser-supported and uses RTP/RTCP internally, giving it strong timing semantics. Latency is typically **< 500 ms end-to-end**, with some implementations at **< 200 ms**. WebRTC uses RTCP Sender Reports for inter-stream sync (the same NTP/RTP mapping as pure RTP).[^21][^22][^10][^23]

The scalability problem: WebRTC is peer-to-peer — a broadcaster cannot maintain thousands of outbound peer connections. The solution is a **Selective Forwarding Unit (SFU)**:[^24][^25]
- Broadcaster sends **one stream** to the SFU
- SFU duplicates and forwards it to all connected listeners
- Each listener gets a separate peer connection from the SFU
- Mediasoup and Janus can sustain **< 50 ms latency** at a few hundred simultaneous users[^26]

For cross-client synchronisation, WebRTC alone doesn't guarantee that all connected clients are at the same playback position — it only guarantees low latency per client. To achieve synchrony, you must layer the deterministic offset approach on top: clients request "what should be playing at time T?" from a shared API and adjust their WebRTC stream accordingly.

**CDN support for WebRTC is limited or non-existent** compared to HLS, making it expensive to scale to tens of thousands of listeners. Consider WebRTC for the ultra-low-latency "interactive" tier (call-ins, competitions) and LL-HLS for the mass-audience delivery tier.[^27]

***

### 6. Icecast / SHOUTcast (HTTP ICY) — Simple but Unsynchronised

**Icecast** and **SHOUTcast** serve audio over HTTP with ICY metadata headers. They're the workhorse of internet radio — virtually every media player supports them. However:[^28]

- Latency for a 128 kbps MP3 stream: **~1.5 s without burst-on-connect, ~3 s with**[^29][^30]
- Each client connects at a slightly different time and buffers independently
- There is **no cross-client synchronisation mechanism** — two listeners connecting 5 seconds apart will always be 5 seconds out of phase
- The `queue-size` and `burst-size` parameters can be tuned to reduce latency but never eliminate the fundamental asynchrony[^31][^32]

Icecast is excellent for general internet radio where listeners don't need to be in sync with each other. For a "super-realtime" synchronised station, it is not suitable as the primary delivery protocol, though it can serve as a fallback for clients that can't handle RTP or WebRTC.

***

### 7. The Deterministic Offset Pattern (Clock-Anchored HTTP)

An elegant solution that sidesteps the need for specialised streaming protocols entirely:[^4]

1. **Pre-schedule your playlist** with a fixed epoch (e.g., `2024-01-01 00:00:00 UTC`)
2. Server computes `offset = (now - epoch) mod total_playlist_duration` — purely deterministic, stateless
3. Client fetches this offset and seeks to it in the audio file, then plays
4. Client periodically re-syncs (correcting for `offset + request_round_trip_time/2`)
5. Any number of clients computing the same function at the same wallclock time will be **mathematically at the same playback position**

This can be delivered over plain HTTP with any media file format — no special streaming protocol needed. The only dependency is **client and server clocks being reasonably synchronised** (NTP accuracy of ±50 ms is typically sufficient for audio that doesn't require sample-level sync). This is how some modern virtual radio stations achieve robust cross-client sync without infrastructure complexity.[^4]

The limitation is **join latency** (initial seek) and the fact that synchronisation is only as good as client NTP accuracy — typically ±5–50 ms on modern systems, which is good but not sub-millisecond.[^33]

***

## Synchronisation Accuracy Summary

| Protocol | Typical Sync Accuracy | Browser Support | Internet Scalable | CDN-Friendly |
|---|---|---|---|---|
| AES67 / PTP | < 1 µs (hardware), < 2 ms (software)[^15] | ✗ | ✗ (LAN/WAN only) | ✗ |
| Bark (UDP multicast) | ~1 ms[^19] | ✗ | ✗ (LAN/VPN) | ✗ |
| Snapcast | < 0.2 ms[^6] | ✗ | TCP, needs port-forward | ✗ |
| Raw RTP/RTCP | ~1–5 ms | ✗ | Unicast only | ✗ |
| WebRTC + SFU | ~50–200 ms (per-client)[^26] | ✓ (native) | ✓ (SFU scales) | ✗ |
| Deterministic offset | ±NTP accuracy (~5–50 ms)[^33] | ✓ | ✓ (static files + CDN) | ✓ |
| LL-HLS | 2–3 s, not synchronised[^1] | ✓ | ✓ | ✓ |
| Icecast/SHOUTcast | 1.5–3 s, not synchronised[^29] | ✓ | ✓ | Partial |
| RTMP | 2–5 s, not synchronised[^34] | ✗ (Flash-era) | ✓ | Partial |

***

## Recommended Architecture for a "Super-Realtime" Internet Radio Station

A layered approach handles both the synchronisation requirement and real-world internet scalability:

### Layer 1 — Studio/Ingest (Sub-millisecond)
Use **AES67** internally between studio equipment, mixing desk, and encoder. PTP-locked clocks across all studio gear. If your studio is fully software-based (Linux), use **Snapcast or Bark on the LAN** to distribute the master stream to any internal monitoring/playout systems.[^35][^19][^16][^5]

### Layer 2 — Internet Delivery (< 50–200 ms, synchronised)
For a public audience that needs to be synchronised:

**Option A — WebRTC SFU + Deterministic Offset**
- Run a **Mediasoup** or **Janus**-based SFU for browser-native playback at < 200 ms latency[^26]
- Pair with a `/now-playing` API endpoint that returns the expected playback offset calculated from a fixed epoch[^4]
- JavaScript Web Audio API on the client can schedule playback with sample-level precision using `AudioContext.currentTime`[^36][^37]
- Clients periodically call the API and adjust their audio node start offset: `startTime = serverOffset + (roundTripTime / 2)`

**Option B — Deterministic Offset over HTTP/CDN (Simplest)**
- Pre-encode playlist segments or continuous stream file
- Serve `/now-playing` API (can be stateless, serverless)[^4]
- Clients fetch, seek, and play — synchronisation across all clients is mathematically guaranteed to ±NTP accuracy (typically ±10–50 ms)[^33]
- Falls behind WebRTC on per-client latency but is trivially CDN-scalable

**Option C — SRT Ingest + WebRTC Egress**
- **SRT** (Secure Reliable Transport) for ingest/contribution links: minimum 120 ms latency over short links, designed for high-bitrate transport over unpredictable networks[^38]
- SFU repackages to WebRTC for browser delivery

### Layer 3 — Fallback (Wide Compatibility)
Maintain an **Icecast** mount for listeners on devices that can't handle WebRTC — smart TVs, old media players, etc.. Accept that these listeners will not be synchronised with the primary audience.[^28]

***

## Codec Choices

- **Opus** is the best codec for synchronised internet radio: 26.5 ms algorithmic delay (configurable down to 5 ms), excellent quality at 64–128 kbps, open standard, widely supported in browsers via WebRTC and MSE. Used natively by WebRTC.[^18]
- **FLAC** for lossless delivery over Snapcast or LAN segments where bandwidth isn't constrained.[^5]
- **AAC** as fallback for HLS/LL-HLS delivery since HLS requires H.264/AAC for broad compatibility.[^39]
- Avoid **MP3** for low-latency work — its encoder lookahead introduces fixed latency of ~576 samples (~13 ms at 44.1 kHz).

***

## Key Takeaways

- **HLS with 10 ms segments is not viable** — the HTTP/m3u8 model is fundamentally incompatible with sub-100 ms synchronisation, even with LL-HLS.
- **The closest thing to traditional radio sync** over the internet is the **deterministic offset pattern** (stateless, CDN-friendly, ±50 ms) or **RTP/RTCP with RTCP Sender Reports** (tight timestamps, needs native client).
- **WebRTC + SFU** is the best compromise for browser-native delivery: sub-second latency, scalable via SFU, and JavaScript Web Audio API allows precise per-client scheduling.[^36]
- **Snapcast** achieves the tightest sync (< 0.2 ms) of any open-source system but requires native clients.[^6]
- **AES67** is the broadcast-grade standard for studio infrastructure but is LAN-only.[^12][^16]
- For maximum synchronisation at internet scale, the right answer is **WebRTC SFU for delivery + a deterministic offset API** so that every browser client, regardless of when it connected, can independently calculate "what millisecond of audio should be playing right now" and seek to it.

---

## References

1. [A Practical Guide to Optimizing LL-HLS & LL-DASH for ...](https://www.muvi.com/blogs/a-practical-guide-to-optimizing-ll-hls-ll-dash-for-ultra-low-latency/) - How to optimize low latency live streaming for your platform? Get in-depth analysis on what truly ma...

2. [Low Latency HLS with CDN: The Ultimate Production Guide](https://blog.cdnsun.com/low-latency-hls-with-cdn-the-ultimate-production-guide/) - Cut stream lag to 2–3s with Low-Latency HLS and CDN best practices. Learn parts, preload hints, FFmp...

3. [Introducing Low-Latency HLS Support for Cloudflare Stream](https://blog.cloudflare.com/low-latency-hls-support-for-cloudflare-stream/) - LL-HLS will reduce the latency a viewer may experience on their player from highs of around 30 secon...

4. [Building a Synchronised Internet Radio System with PHP ...](https://dev.to/iammastercraft/building-a-synchronised-internet-radio-system-with-php-js-and-zero-streaming-infrastructure-13l) - All listeners are synchronised, everyone hears the same content at the same position; It should work...

5. [Snapcast – Synchronous multiroom audio server - HL2GO.COM](https://hl2go.com/downloads/snapcast-synchronous-multiroom-audio-server/) - Snapcast – Synchronous multiroom audio server. GPL-3.0 C++ Snapcast is a multiroom client-server aud...

6. [GitHub - badaix/snapcast: Synchronous multiroom audio player](https://github.com/badaix/snapcast/) - Synchronous multiroom audio player. Contribute to badaix/snapcast development by creating an account...

7. [Instantaneous RTP synchronization & retrieval of absolute ...](https://coaxion.net/blog/2022/05/instantaneous-rtp-synchronization-retrieval-of-absolute-sender-clock-times-with-gstreamer/)

8. [Microsoft Word - 081022.docx](https://koreascience.kr/article/CFKO200915536389380.pdf)

9. [RFC 3550 - RTP: A Transport Protocol for Real-Time Applications](https://datatracker.ietf.org/doc/html/rfc3550) - This memorandum describes RTP, the real-time transport protocol. RTP provides end-to-end network tra...

10. [Lip synchronization and WebRTC applications](https://bloggeek.me/lip-synchronization-webrtc/) - Discover the fascinating world of lip synchronization technology and its impact on WebRTC applicatio...

11. [Live radio streaming with MPD, part 2: multicast RTP](https://anarc.at/blog/2013-02-03-live-radio-streaming-mpd-part-1-multicast-rtp/) - In this article we introduce RTP-based streaming system, (unfortunately based on Pulseaudio and mult...

12. [AES67](https://en.wikipedia.org/wiki/AES67) - AES67 is a technical standard for audio over IP and audio over Ethernet (AoE) interoperability. The ...

13. [PTP for broadcast networks](https://www.bodet-time.com/resources/blog/1913-ptp-for-broadcast-networks.html) - PTP (Precision Time Protocol) is a time synchronisation protocol which offers excellent guarantees a...

14. [NTP Vs. PTP: Decoding Time Synchronization](https://www.etherwan.com/support/featured-articles/ntp-vs-ptp-decoding-time-synchronization) - PTP enables server time synchronization with sub-microsecond to nanosecond precision, surpassing the...

15. [Introduction to AES67](https://www.magewell.com/blog/98/detail) - 3. Accurate synchronization mechanism: AES67 uses the PTPv2 (IEEE 1588-2008) standard for clock sync...

16. [Introduction to AES67](https://www.cardinalpeak.com/blog/intro-to-aes67) - AES67 is a standard for transport of high performance audio over IP networks. High performance, as A...

17. [3pp-mirror/snapcast: Synchronous multiroom audio player ...](https://git.1in9.net/3pp-mirror/snapcast) - Synchronous multiroom audio player

18. [Opus (audio format) - Wikipedia](https://en.wikipedia.org/wiki/Opus_(audio_format))

19. [Hailey Somerville's Bark, a Rust-Based Live-Sync Audio ...](https://www.hackster.io/news/hailey-somerville-s-bark-a-rust-based-live-sync-audio-streamer-is-like-sonos-but-open-source-f18db0d941a7) - Low-latency multicast audio server spits out uncompressed 48kHz audio with built-in time synchroniza...

20. [GitHub - haileys/bark: live sync audio streaming for local networks](https://github.com/haileys/bark) - live sync audio streaming for local networks. Contribute to haileys/bark development by creating an ...

21. [Streaming Protocols for Live Broadcasting (2026)](https://www.dacast.com/blog/streaming-protocols/) - In 2026, video is a default way people learn, buy, and communicate online. Multiple industry roundup...

22. [How does audio and video in a webrtc peerconnection stay in sync?](https://stackoverflow.com/questions/66479379/how-does-audio-and-video-in-a-webrtc-peerconnection-stay-in-sync) - How does audio and video in a webrtc peerconnection stay in sync? I am using an API which publishes ...

23. [RFC 8834 - Media Transport and Use of RTP in WebRTC](https://datatracker.ietf.org/doc/rfc8834/) - This memo describes how the RTP framework is to be used in the WebRTC context. It proposes a baselin...

24. [WebRTC - scalable live stream broadcasting / multicasting](https://stackoverflow.com/questions/18318983/webrtc-scalable-live-stream-broadcasting-multicasting) - PROBLEM: WebRTC gives us peer-to-peer video/audio connections. It is perfect for p2p calls, hangouts...

25. [Scalable Broadcasting Using WebRTC](https://dev.to/aminarria/scalable-broadcasting-using-webrtc-2984) - Making a scalable broadcasting service using WebRTC

26. [[PDF] Comparative Study of WebRTC Open Source SFUs for Video ...](https://mediasoup.org/resources/CoSMo_ComparativeStudyOfWebrtcOpenSourceSfusForVideoConferencing.pdf)

27. [LL-HLS solution for radio broadcast · bluenviron mediamtx · Discussion #1765](https://github.com/bluenviron/mediamtx/discussions/1765) - Hello, I've been looking for a solution for a radio broadcast for a while now. What I want to accomp...

28. [Internet radio streaming](https://support.spinetix.com/wiki/Internet_radio_streaming) - Internet radio streaming feature, introduced in DSOS 4.7.0, lets HMP400/W, iBX410/W, iBX440, and thi...

29. [Icecast 2.3.1 Docs — Config File](http://icecast.org/docs/icecast-2.3.1/config-file.html) - The latency is bitrate-dependent, but as an example, for a 128kbps stream, the latency between the s...

30. [Icecast 2.1.0 Docs — Config File](http://icecast.org/docs/icecast-2.1.0/config-file.html) - The latency is bitrate-dependent, but as an example, for a 128kbps stream, the latency between the s...

31. [Reducing Icecast playback delay : r/linuxquestions](https://www.reddit.com/r/linuxquestions/comments/299e3e/reducing_icecast_playback_delay/) - I would like to reduce audio delay as much as possible. Currently I'm getting around 2 to 3 seconds ...

32. [Decoding HTTP Audio Stream from Icecast with minimal ...](https://stackoverflow.com/questions/54147319/decoding-http-audio-stream-from-icecast-with-minimal-latency) - I'm using Icecast to stream live audio from internal microphones and want the listener to have as sm...

33. [What Is NTP? A Beginner's Guide to Network Time Protocol](https://www.galsys.co.uk/news/what-is-ntp-a-beginners-guide-to-network-time-protocol/) - NTP is an internet protocol that's used to synchronise the clocks on computer networks to within a f...

34. [What's the best protocol for live audio (radio) streaming for mobile and web?](https://stackoverflow.com/questions/30184520/whats-the-best-protocol-for-live-audio-radio-streaming-for-mobile-and-web) - I am trying to build a website and mobile app (iOS, Android) for the internet radio station. Website...

35. [IP SHOWCASE 23 Timing & Synchronization in AES67 & ...](https://www.youtube.com/watch?v=pxzXWJrD9TQ) - Andreas Hildebrand, ALC NetworX AES67 and SMPTE ST 2110 are based on a precise system-wide synchroni...

36. [A tale of two clocks | Articles](https://web.dev/articles/audio-scheduling) - This tutorial has been helpful in explaining clocks, timers and how to build great timing into web a...

37. [Understanding The Web Audio Clock -](https://sonoport.github.io/web-audio-clock.html) - This clock can be used to schedule audio events or parameters using the start(), stop() or setValueA...

38. [Low Latency Streaming Protocols SRT, WebRTC, LL-HLS, UDP ...](https://ottverse.com/low-latency-streaming-srt-webrtc-ll-hls-udp-tcp-rtmp/) - We will analyze current market offers in terms of low-latency broadcasting by looking at WebRTC, RTM...

39. [Streaming Protocol Comparison: RTMP, WebRTC, FTL, SRT](https://restream.io/blog/streaming-protocols/) - Everything you need to know about video streaming protocols. Describing the main features of the mos...

