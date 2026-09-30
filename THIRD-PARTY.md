# Third-party components

## FreeFlow

ZFlow began as a fork of FreeFlow, also MIT licensed. Reusing ZFlow means
reusing that code too, so keep this notice alongside ZFlow's own
[LICENSE](LICENSE):

```
MIT License

Copyright (c) 2026 Zach Latta

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## sherpa-onnx

The speaker models that tell the remote voices in a meeting apart run through
[sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx) (`sherpa-onnx-node`),
Apache-2.0 licensed, bundled in the settings front end.

The models themselves are downloaded on first use rather than shipped:

- **Segmentation** — `sherpa-onnx-pyannote-segmentation-3-0`, from the
  pyannote community model, MIT licensed.
- **Speaker embedding** — `3dspeaker_speech_campplus_sv_zh-cn_16k-common`, from
  the 3D-Speaker project, Apache-2.0 licensed.

Both are fetched from Hugging Face and kept in the app's own support folder.
They run on this machine; no audio is uploaded for them.

## OpenWhispr

The two-track approach to meeting capture — recording the microphone and the
system output separately so the two sides never have to be told apart by a
model — follows [OpenWhispr](https://github.com/OpenWhispr/openwhispr), MIT
licensed. No code was copied; the design was.
