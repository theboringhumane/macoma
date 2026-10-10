# Window-management demo

[Watch the demo](window-management.mp4) · [Preview image](window-management.jpg)

The project owner recorded this 24-second clip with Screen Studio on an early
development build. It illustrates window movement and layout, not load testing
or release qualification.

Frame-tracked blur hides WhatsApp names and messages, the recording preview, and
private terminal content. Some transitions are fully blurred to cover moving
content. Audio and source metadata were removed. The original recording and
review contact sheets stay outside the repository.

All 722 output frames were reviewed in contact sheets, with full-resolution
checks of sensitive transitions and the poster. The H.264 video passed a full
decode check and contains one video stream, no audio, and a faststart header.
[verification.json](verification.json) records the file hashes and review scope.

[redact.py](redact.py) and [redaction.json](redaction.json) preserve the privacy
edit. To reproduce it with Python 3 and FFmpeg, set both paths to locations
outside this repository, then run from the repository root:

```sh
python3 docs/demos/redact.py "$PRIVATE_RECORDING" "$SANITIZED_OUTPUT"
```

The script requires the exact source hash and refuses to overwrite an existing
output. FFmpeg versions can produce different encoded bytes; review any new
export before publication. The checked-in poster comes from the sanitized video
at 20.4 seconds.
