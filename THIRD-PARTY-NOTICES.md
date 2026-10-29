# Third-party notices

Swipe & Sketch's own source is licensed under the PolyForm Shield License 1.0.0 (see [LICENSE](LICENSE)). It includes the following third-party software, which keeps its own license.

## Open CASCADE Technology

- **Version:** 8.0.1 (tag `V8_0_1`), from https://github.com/Open-Cascade-SAS/OCCT
- **License:** GNU Lesser General Public License version 2.1, with the Open CASCADE exception version 1.0
  - [LICENSES/LGPL-2.1.txt](LICENSES/LGPL-2.1.txt)
  - [LICENSES/OCCT-exception-1.0.txt](LICENSES/OCCT-exception-1.0.txt)
- **How it's used:** Open CASCADE is the modeling kernel behind every solid. `Scripts/build_kernel.sh` builds it from unmodified source, and it is statically linked into the app through the C facade in `SwipeAndSketch/Kernel`.

The app shows the same notice and both license texts on its About screen (on the Home rail, and **About Swipe & Sketch** in the project menu).

## openGrid

- **What:** openGrid, the wall and desk mounting system by **David D** (https://www.opengrid.world/)
- **License:** [Creative Commons Attribution 4.0 International](https://creativecommons.org/licenses/by/4.0/), as its core models are published
  - Core models: https://www.printables.com/model/1214361-opengrid-walldesk-mounting-framework-and-ecosystem
  - Metric screw snaps: https://www.printables.com/model/1217921-opengrid-metric-screw-snaps
- **How it's used:** the openGrid templates rebuild its boards in code from the published profile (`SwipeAndSketch/Core/OpenGridGeometry.swift`), and ship its official connector, wall mount, cover, and M3 nut snap solids, moved to center each on the origin and otherwise unchanged (`SwipeAndSketch/Core/OpenGridPartData.swift`). The official files they come from are kept, unchanged, in `Tests/Fixtures/OpenGrid`, with their sources and hashes. openGrid's material keeps its CC BY 4.0 license; Swipe & Sketch's PolyForm Shield license does not cover it. The templates that carry it are free in the app. Swipe & Sketch is not affiliated with or endorsed by the openGrid creators.

The app credits openGrid beside its templates and on the About screen.

### Your rights under the LGPL

The full source of Swipe & Sketch is in this repository, so you can rebuild the app against a modified Open CASCADE. The steps are in [README.md](README.md#relinking-with-a-modified-open-cascade).

Whatever the App Store's standard license says, you may modify Swipe & Sketch for your own use and reverse engineer it to debug those modifications.
