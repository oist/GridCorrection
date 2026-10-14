# Grid Distortion Correction

A MATLAB App Designer application for measuring and correcting geometric distortion in
**momentum microscope** and **transmission electron microscope (TEM)** images.

It uses the shadow of a regular TEM grid — a copper mesh of known, uniform pitch — as the
distortion reference. Because the true geometry of the mesh is known, any departure of its
imaged shadow from a perfect lattice is instrument distortion, and can be measured and
inverted.

The app locates every grid crossing across a Z-stack of grid-shadow images, fits a
distortion model to the measured positions, and applies that correction to experimental
images.

Distortion is not constant through a stack: it varies with energy and focus, so each plane
is measured on its own and the variation across planes is modelled rather than assumed
away.

**`ImagePostProcessingDlgV11.m` is the current version.** Earlier versions are kept in the
repository as frozen snapshots; none of them is loaded or called by V11.

---

## Running it

```matlab
ImagePostProcessingDlgV11
```

Requires MATLAB R2025b with the Image Processing, Curve Fitting and Statistics and Machine
Learning toolboxes.

The microscope data (`.tiff`) and saved measurement files (`.mat`) are deliberately not in
this repository — they are instrument data, not source.

---

## What it does today

### Workflow

1. **Quick Setup** — choose a reference grid-shadow stack, then detect and populate the
   first plane automatically.
2. **Populate the Rest** — measure every remaining plane.
3. **Finish** — the distortion model is ready; apply it to experimental images.

### Measuring the grid

Each plane's lattice (spacing, orientation, phase) is detected from the image by 2D-FFT
peak-picking plus a projected-profile phase fit. Every crossing is then refined
**independently** by a bounded local Gaussian-dip search seeded from that global model, and
a robust 2D polynomial surface is fitted across the plane as the final position.

The independence matters: a bad seed can only fail to converge, it is never blindly trusted,
because every point is re-verified against the image regardless of where its seed came from.

### Grid point detection methods

| method | what it does |
|---|---|
| local fit only | The original path. Each crossing refined independently, then a per-plane surface fit. |
| **local fit + joint 3D fill** *(default)* | As above, but crossings that never converged are filled from a single fit over the **whole stack** rather than from their own plane's surface. Measured on three real stacks with contiguous holdouts on the degraded planes: better median error in 8 of 9 cases, often 3–6×. |

### Cross-plane consistency

- **Period survey across Z** — the lattice period is not constant through a stack. On one
  real dataset it grows 70% (20 px → 34 px) as the illuminated field opens up. Each plane is
  detected independently, a robust curve is fitted through the planes that agree, and each
  plane is given its own period.
- **Reference-plane selection** — the strongest plane is scored and measured first, then
  planes are populated **outward from it in both directions**. Earlier versions assumed
  plane 1 was the best; on real data it is sometimes the worst.
- **Anchor tracking** — a few central crossings are followed continuously down the stack at
  finer Z sampling than the output planes, so their identity is never in doubt. They verify
  that each plane's lattice model has not latched onto the wrong crossings.
- **Z-correlation** — points on a plane that could not be trusted on its own are corrected
  from the trend across planes that could.

### Consistency checks

- **Lattice phase check** — if a plane's model is a whole number of cells out of phase,
  every point it predicts lands on the wrong crossing and the result is perfectly
  self-consistent. The anchors catch this and correct it, with a warning in the log.
- **In-plane spacing check** — the gap between adjacent grid lines must equal that plane's
  period. Catches whole rows or columns slipping, which a smooth surface fit absorbs
  silently.
- **Z continuity** — a point that moves much further between planes than its neighbours has
  changed crossing, not moved.

### Reviewing and correcting by hand

The grid editor shows every crossing over the plane image, coloured by **where its position
came from**:

| colour | meaning |
|---|---|
| blue | measured — a converged fit to the image |
| pink | measured, then rejected as disagreeing with its plane |
| orange | inferred from other points (surface, Z trend, joint 3D fit, carried forward) |
| grey | not fitted (raw preview only) |

The legend shows a count for each and a "N of M measured" summary — the number that says
whether to trust a plane. Points can be dragged, individually re-fitted by right-click, and
the grid origin can be relocated onto a different crossing.

### Correction and verification

Seven transformation models: affine, projective, polynomial order 3 *(default)*, polynomial
order 4, piecewise-affine, piecewise-projective and piecewise-polynomial order 2.

**Correction Test**, **Compare All Models** and **Verify Overall Correction** panels measure
how well each model actually corrects the reference grid, including before/after vector maps
and intensity cross-sections. Compare All Models scores all seven using transform maths only,
with no re-fitting.

---

## Version history

### V1 → V2 — global lattice instead of sequential propagation

The original algorithm asked for four manual seed clicks, then walked the grid row by row,
estimating each crossing from its previously-fitted neighbour — so one bad fit propagated
outward across the plane.

V2 replaced that with the approach still in use: auto-detect the lattice per plane, refine
every crossing independently from that global model, then fit a robust global surface.
Manual 4-point clicking survives only as a fallback.

Also added **Z-history seeding** — each plane's first-pass seed comes from that point's own
history across previously-processed trusted planes. Measured plane 1 → plane 2: first-pass
convergence 66/100 → 92/100.

### V3 / V4 — dashboard and setup pages

Established the Home dashboard plus independent setup pages (Flatfield / Grid / Objective)
that the UI still follows. Load/Save Settings covers the whole setup bundle, so it belongs
with the setup steps rather than with the run action.

### V5 — the HTML interface

The dialog was rewritten from native MATLAB uicontrols into a single HTML component. MATLAB
pushes one view-model struct and the page repaints itself; the page sends back one action
per user gesture, which a single dispatcher routes to the existing callbacks. Page
navigation is entirely client-side.

### V6 — plain `.m`, one merged window

The `.mlapp` packaging was dropped entirely and the app became an editable `.m` file. The
grid editor moved **into** the dashboard window instead of a separate figure, and
**View / Edit Grid** was added so an existing grid can be reopened without re-running
detection from scratch.

Native ROI dragging was deliberately kept rather than reimplemented in JavaScript.

### V7 — accuracy work

- **Flatfield applied before detection**, not only at output time. Previously an
  illumination gradient was indistinguishable from real geometric distortion to the surface
  fit.
- **Sub-plane drift correction** — the slides averaged into one plane are registered to each
  other first.
- **Tiered Z-trend lattice seeding** — trend first, fresh FFT only when quality drops,
  bridging probes as a last resort.
- **Adaptive surface order**, chosen per plane by cross-validation.

### V8 — correction, verification and reporting

- Audited and fixed several bugs in the final batch image-correction step.
- **Correction Test** and **Compare All Models** panels — all seven transformation models
  scored on the real grid, transform-math only, no re-fitting.
- **Verify Overall Correction**, made ~19× faster and cancelable, with intensity-cross-section
  kymographs.
- `interp2` piecewise warp; compatibility with settings files saved by earlier versions.

### V9 — selectable detection method

Introduced `grid_DetectionMethod` so detection strategy became a user choice rather than a
code edit. This is the mechanism the current default method is selected through.

### V10 — phase locking, provenance, and the dialog

- **Anchor tracking** — central crossings followed down the stack at 2× Z sampling to verify
  each plane's lattice phase. On a real stack this turned a 100/100 whole-cell slip into
  2/100.
- **Joint 3D fill** added as a detection method (the current default).
- **Point colours by provenance** — previously a crossing that was never measured and one
  that converged were drawn identically, under a legend that said "measured". On a 16×16 grid,
  10 of 256 points sat where the image intensity is zero and were all painted as measured.
- **The dialog sizes itself to its content** instead of a fixed height.
- Fixed: changing the grid size left the grid off-centre; the anchors silently undid a
  deliberate origin re-labelling.

### V11 — current

- **Reference-plane selection and outward propagation** — score every plane, start from the
  strongest, work outward in both directions. On the test stack the scoring picks the last
  plane, matching what the images show.
- **Period survey across Z** — per-plane periods fitted robustly across the stack, outlier
  planes rejected.
- **In-plane spacing check** — catches grid lines inserted among correctly spaced ones, which
  no existing check could see.
- **Bounded phase corrections** — anchors claiming an implausible slip are refused and
  logged. They had been reporting offsets of 22 cells on a 10×10 grid and "correcting" by
  them.
- **Zero-padded version filenames** so they sort in order.
- **Setup dialog**: defaults are now joint-3D fill and polynomial order 3; the setup is
  remembered between sessions; a **Restore Defaults** button sits in the Grid Distortion
  Setup header.
- Removed the **Optimize Grid Crossings** option — unchecking it placed raw lattice positions
  with no fitting at all, which is a preview rather than a result. It is now always on.
- Fixed: switching dashboard pages did not resize the window, so the taller pages were
  clipped and the buttons near the bottom could not be clicked.

---

## Measured on real data

The repository's development used three real grid-shadow stacks. The most demanding is one
whose illuminated field grows from nothing to a third of the frame across the stack, so the
lattice period changes by 70% and the *last* planes are the sharpest.

On an eight-plane window of that stack, converged crossings out of 800:

| | V10 | V11 |
|---|---|---|
| local fit only | 690 | **800** |
| local fit + joint 3D fill | 690 | **800** |

Position spacing agrees with each plane's own measured period to 0.02–0.45 px.

---

## Repository layout

```
ImagePostProcessingDlgV11.m       current version -- this is the one to run
ImagePostProcessingDlgV10.m       recent versions, kept for reference
ImagePostProcessingDlgV09.m
ImagePostProcessingDlgV08.m
archive/                          versions older than V08
  ImagePostProcessingDlgV07.m
  ImagePostProcessingDlgV06.m
  ImagePostProcessingDlgV01.mlapp the original App Designer version
GridCorrection.prj                MATLAB project file
README.md
```

Each version is a self-contained `classdef`; none references another. Versions are branched
by copying the file and renaming the class, so a frozen version keeps working exactly as it
did.
