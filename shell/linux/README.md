This GTK runner is a **development convenience, not the product.**

Mira renders through flutter-pi straight to DRM/KMS, with no X11 and no
Wayland - that is the whole reason flutter-pi was chosen, and the DRM-master
constraint that follows from it drives the v1 architecture.

This directory exists only so the shell can be run and driven on a desktop
while the flutter-pi packaging is unresolved. Nothing here ships in the image,
and no code under `lib/` may depend on it.

    flutter run -d linux          # needs ninja, cmake, clang, gtk3 on the host
