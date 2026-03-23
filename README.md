# Radio

`Radio` is a Swift executable that reads a JSON config and runs a standalone HTTP radio server. It serves one or more HLS stream endpoints (`.m3u8` + `.ts`) from local media folders using `ffmpeg`.

## Requirements

- Swift 6.2+
- `ffmpeg` available in `PATH` (or pass `--ffmpeg-path`)

## Config File Schema

The config file is a JSON object containing global options and a `streams` array:

```json
{
  "host": "0.0.0.0",
  "port": 8000,
  "protocol": "http",
  "bitrateKbps": 128,
  "sampleRate": 44100,
  "ffmpegPath": "/usr/local/bin/ffmpeg",
  "streams": [
    {
      "radioStreamName": "Diamond City Radio",
      "mediaDir": "./media/diamond-city",
      "playbackOrder": "random"
    }
  ]
}
```

### Root Config Options

- `host` (string, optional): Streaming server host. Default: `localhost`.
- `port` (number, optional): Streaming server port. Default: `8000`.
- `protocol` (string, optional): Only `http` is supported in standalone mode. Default: `http`.
- `bitrateKbps` (number, optional): AAC output bitrate for HLS. Default: `128`.
- `sampleRate` (number, optional): Output sample rate in Hz. Default: `44100`.
- `ffmpegPath` (string, optional): ffmpeg executable path/command. Default: `ffmpeg`.
- `streams` (array, required): List of stream objects.

### Stream Object Options

- `radioStreamName` (string, required): Display name for the stream. Also used to derive mount name.
- `mediaDir` (string, required): Directory containing audio files.
- `playbackOrder` (string, required): One of `random`, `az`, `za`. `random` shuffles playback order, `az` sorts by filename ascending, `za` sorts by filename descending.

## Supported Media File Extensions

The app scans `mediaDir` recursively and includes:

- `.mp3`
- `.aac`
- `.m4a`
- `.wav`
- `.flac`
- `.ogg`
- `.opus`

## CLI Options

Run with:

```bash
swift run Radio --config radio-config.example.json
```

Options:

- `--config <path>`: Path to config JSON file. Required.
- `--host <host>`: Overrides `host` from config.
- `--port <port>`: Overrides `port` from config.
- `--protocol <http>`: Overrides `protocol` from config.
- `--bitrate-kbps <int>`: Overrides `bitrateKbps` from config.
- `--sample-rate <int>`: Overrides `sampleRate` from config.
- `--ffmpeg-path <path-or-command>`: Overrides `ffmpegPath` from config.
- `--log-level <level>`: One of `trace`, `debug`, `info`, `notice`, `warning`, `error`, `critical`. Default: `info`.

## HLS Endpoints

Each stream is served at an HLS endpoint derived from `radioStreamName`:

- Lowercased
- Non-alphanumeric characters replaced with `-`
- Repeated dashes collapsed
- slug used as a folder path with `index.m3u8`

Example:

- `Diamond City Radio` -> `http://<host>:<port>/diamond-city-radio/index.m3u8`

`GET /` returns a simple index of all available stream URLs.
Segments are served from the same slug path (for example `.../diamond-city-radio/segment_000123.ts`).

## Notes

- This app does not require an external Icecast/SHOUTcast server.
- Clients connect directly to this process using normal HTTP and HLS playback support.
- HLS is generated as a rolling live window with 106-second segments (single shared `.m3u8` window per stream). Details in `ffmpeg` args in `RadioPublisher.swift`.
- Old segments are deleted over time; clients should stay near live edge. Only 2 segments are kept in the playlist at a time, and segments are deleted after 1 playlist cycle (20 seconds) to prevent clients from requesting deleted segments.
