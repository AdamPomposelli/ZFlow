# README demo

The source of `Brand/readme/demo.webp`, the animation at the top of the
README: ZFlow used to prompt an AI agent from a code editor. It is a [HyperFrames](https://github.com/heygen-com/hyperframes)
composition, built with the
[Herk Edit Kit](https://github.com/nateherkai/herk-edit-kit) and its motion
rules. Nothing here is part of the app.

| File | What it is |
|---|---|
| `index.template` | The composition: scenes, timeline, per-frame driver. |
| `build.py` | Fills the template's slots and writes `index.html`. |
| `lockup.py` | The Zippy/ZFlow lockup as an SVG whose parts can move. |
| `DESIGN.md` | Palette, type and what not to do. |

## Re-render

You need Node 22+, FFmpeg, Chrome, Python with `fonttools` and `brotli`, and
the Zippy `brand-kit` checked out next to this repository.

1. In a Herk Edit Kit checkout: `npm ci`, then `npm run new-video -- zflow-demo`.
   Copy this folder's files into `video-projects/zflow-demo/`.
2. Fonts: copy Plus Jakarta Sans 500/700/800 and JetBrains Mono 400 from
   `brand-kit/fonts/` into `assets/fonts/`.
3. `python3 lockup.py ../../../brand-kit assets && python3 build.py`
4. `npx hyperframes lint`, then
   `npx hyperframes render --quality high --fps 30 --output renders/zflow-demo.mp4`
5. Convert:

   ```bash
   ffmpeg -i renders/zflow-demo.mp4 -vf "fps=20,scale=960:-1:flags=lanczos" -c:v libwebp -lossless 0 -q:v 70 -loop 0 -an demo.webp
   ```

An animated WebP rather than a video, so the README plays it on its own, with
no play button, and rather than a GIF, which is four times heavier.
