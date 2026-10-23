# Third-party notices

Swipe & Sketch's own source is licensed under the PolyForm Shield License 1.0.0 (see [LICENSE](LICENSE)). It includes the following third-party software, which keeps its own license.

## Open CASCADE Technology

- **Version:** 8.0.1 (tag `V8_0_1`), from https://github.com/Open-Cascade-SAS/OCCT
- **License:** GNU Lesser General Public License version 2.1, with the Open CASCADE exception version 1.0
  - [LICENSES/LGPL-2.1.txt](LICENSES/LGPL-2.1.txt)
  - [LICENSES/OCCT-exception-1.0.txt](LICENSES/OCCT-exception-1.0.txt)
- **How it's used:** Open CASCADE is the modeling kernel behind every solid. `Scripts/build_kernel.sh` builds it from unmodified source, and it is statically linked into the app through the C facade in `SwipeAndSketch/Kernel`.

The app shows the same notice and both license texts on its About screen (on the Home rail, and **About Swipe & Sketch** in the project menu).

### Your rights under the LGPL

The full source of Swipe & Sketch is in this repository, so you can rebuild the app against a modified Open CASCADE. The steps are in [README.md](README.md#relinking-with-a-modified-open-cascade).

Whatever the App Store's standard license says, you may modify Swipe & Sketch for your own use and reverse engineer it to debug those modifications.
