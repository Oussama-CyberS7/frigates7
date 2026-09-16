# Test media (lab only)

The video files are not committed. `scripts/fetch-test-media.sh` downloads them, verifies the
sha256 values and prepares the box-sim streams.

| Stream | Source file (original sha256) | Content | Prepared as |
|---|---|---|---|
| `yard_cam` | `person-bicycle-car-detection.mp4` (`452b11b7…43140ef`) | Aerial view of a parking lot: cars, pedestrians, a cyclist | 768x432, 10 fps, GOP 10, no audio |
| `warehouse_cam` | `worker-zone-detection.mp4` (`b8b58b81…cbdcd284`) | Indoor warehouse floor with workers in safety vests | 1280x720, 10 fps, GOP 10, no audio |

## Attribution (CC BY 4.0)

- **Source:** "Sample Videos" by Intel IoT DevKit, <https://github.com/intel-iot-devkit/sample-videos>,
  retrieved 2026-09-16 from `https://raw.githubusercontent.com/intel-iot-devkit/sample-videos/master/<file>`.
- **License:** Creative Commons Attribution 4.0 International, <https://creativecommons.org/licenses/by/4.0/>.
- **Changes:** audio track removed, frame rate reduced to 10 fps, `worker-zone-detection.mp4` scaled to
  1280x720, re-encoded as H.264.

## Privacy note

The license covers copyright only. The people in these clips are still real data subjects.

- Use the clips for internal software testing only, and don't export clips or snapshots outside the lab.
- The same retention limits apply as for real footage.
- Face recognition and LPR stay disabled.
- None of these clips shows a truck. With the bundled model, a truck would be labelled `truck` only
  thanks to the `model.labelmap` override in `frigate/config/config.yml`.
