#!/bin/bash
# The guest mesa build configuration, in one place.
#
# ONE package, three Vulkan drivers. Until 2026-08-18 this was three packages built from three
# branches of Droid-VM/mesa, because the routes sat on unrelated upstream lines: gfxstream and
# venus on 26.0.3 (the gfxstream guest ICD and the host decoder are one codebase), drm2kgsl on
# 26.3.0-devel (where the tu/virtio work lives). Once every route was rebased onto the same
# upstream commit, the three trees turned out to touch disjoint files -- src/gfxstream/**,
# src/virtio/vulkan/vn_*, src/freedreno/** -- so they collapse into one branch and one build:
#
#   gfxstream   the gfxstream guest ICD, talking to the host gfxstream decoder over the
#               vulkan-command wire.
#   venus       the venus (vn) ICD, speaking the venus wire protocol to virglrenderer's vkr.
#   drm2kgsl    real turnip reaching the GPU through virglrenderer's DRM native context over
#               vdrm. -Dfreedreno-kmds=msm,virtio, so the same binary also runs on bare metal.
#
# The route is now chosen at RUN time, not install time: all three ICDs ship, VK_DRIVER_FILES
# lists all three, and the loader keeps whichever one enumerates a device. A DroidVM guest sees
# exactly one virtio-gpu capset, so exactly one ICD answers -- which is why the packages no
# longer have to Conflict with each other. (The old per-variant names are still named in
# Conflicts/Replaces so an upgrade REMOVES them; they installed to the same paths.)
#
# Sourced by the meta repo's lib_mesa_build.sh (numbered build scripts), by ci-build.sh (GitHub
# Actions) and, inside the container, by build-in-container.sh and package.sh. Everything in here
# is either pure data or works on a PATH it is given; nothing knows about worktrees or remotes.

# -Dglvnd=enabled is not a preference: a mixture of GLVND and non-GLVND layouts in one guest is
# the failure mode, and Droid-VM/mesa's own CI validates this configuration.
#
# -Dgallium-drivers=zink: the desktop composites through gallium, on top of whichever Vulkan
# driver answered. Without it GNOME Shell reports "virtio_gpu: driver missing", falls back to
# kms_swrast and dies with "No GPUs found" while Vulkan works the whole time.
#
# llvmpipe rides along because this package SHADOWS the distro mesa without falling back to it:
# /usr/local's GLVND vendor libs win the ld.so search, and post-dril mesa carries its drivers
# inside its own libgallium -- there is no path from our libGLX_mesa to the distro's software
# renderer. On a guest with no paravirt GPU (simplefb-only display, so no virtio-gpu and no
# render node) zink has no Vulkan device under it, GLX offers zero FBConfigs, and the greeter
# crash-loops ("Could not initialize GLX", sddm restarting the display forever). llvmpipe is
# the in-package software fallback that used to come from the distro build. Whether the zink
# override or the llvmpipe fallback is active on a given boot is decided by the packaged
# mesa-guest-env service (see package.sh), not at build time. -Dllvm=disabled makes a build
# where LLVM went missing fail at setup instead of quietly dropping llvmpipe.
MESA_MESON=(
    --buildtype release
    --prefix /usr/local
    --libdir lib/aarch64-linux-gnu
    -Dplatforms=x11
    -Dgallium-drivers=zink
    -Dvulkan-drivers=gfxstream,freedreno,virtio
    -Dfreedreno-kmds=msm,virtio
    -Dllvm=enabled
    -Dopengl=true -Dgbm=enabled -Dglx=dri -Degl=enabled
    -Dglvnd=enabled
    -Dshader-cache-default=true
    -Dvulkan-manifest-per-architecture=true
    -Dallow-fallback-for=perfetto
)

MESA_PKG=mesa-guest

# Every ICD the build installs, in the order the loader should try them. Delivered as
# VK_DRIVER_FILES/VK_ICD_FILENAMES because the package installs under /usr/local, which the
# loader does not scan on its own.
MESA_ICDS=(
    /usr/local/share/vulkan/icd.d/gfxstream_vk_icd.aarch64.json
    /usr/local/share/vulkan/icd.d/virtio_icd.aarch64.json
    /usr/local/share/vulkan/icd.d/freedreno_icd.aarch64.json
)

mesa_icd_list() { local IFS=:; printf '%s' "${MESA_ICDS[*]}"; }

# The per-route packages this one supersedes. Named individually, not just through the shared
# virtual name, because Conflicts+Replaces on a REAL package name is what makes dpkg remove it
# rather than refuse the install (Conflicts alone) or overwrite its files behind dpkg's back.
# mesa-guest-kgsl is the pre-rename name of the drm2kgsl package; guests provisioned before that
# rename still carry it, and a leftover is not harmless -- the routes shared ~60 install paths,
# so something that picks a route by asking whether a file exists then picks the wrong one.
MESA_SUPERSEDES=(mesa-guest-gfxstream mesa-guest-drm2kgsl mesa-guest-venus mesa-guest-kgsl)

mesa_supersedes_list() { local IFS=,; printf '%s' "${MESA_SUPERSEDES[*]}"; }

# The mesa branch to build is the CALLER's branch, not a hardcoded name: the repos move together,
# so a meta/mesa-cross branch describes which mesa goes with it. $BRANCH if set (the meta repo's
# lib_branch.sh sets it; ci-build.sh sets it from the workflow input), else the branch of the repo
# we are being sourced from.
#
# The variant suffixes are still stripped. They are gone from this repo, but a caller can still be
# sitting on wip/3d-accel-gfxstream from before the merge, and the mesa branch it wants is
# wip/3d-accel.
mesa_branch() {
    local b=${BRANCH:-$(git rev-parse --abbrev-ref HEAD 2>/dev/null)}
    b=${b%-gfxstream}; b=${b%-drm2kgsl}; b=${b%-kgsl}; b=${b%-venus}
    printf '%s' "$b"
}

# mesa_pkg_version <checkout> -- upstream mesa version + the commit it was built from, so a deb
# on a guest can be traced back to a tree. git is not usable inside the container (a worktree's
# .git is a file naming an absolute host path), so this runs on the host and is passed in.
#
# A commit count leads and the hash only identifies. A hash does not order: "+droidvm.cea49934" is
# LOWER than "+droidvm.f80a84b5" whichever was built first, so installing a newer build needed
# --allow-downgrades and apt would happily keep the older one. A count of commits only goes up, on
# a branch that is never rewritten. This is why a checkout handed to this function must carry the
# FULL commit history (a shallow clone counts 1); ci-build.sh clones with --filter=blob:none,
# which fetches every commit but no blobs beyond the ones checked out.
#
# The "r" is not decoration. Without it the new scheme would sort BELOW the old one already on
# guests -- dpkg compares the letters of "cea49934" against the empty run in front of "250" and
# letters win -- so every guest would need one more --allow-downgrades. A hash is hex, so it
# starts with 0-9 or a-f; any letter after 'f' beats all of them and the transition is ordinary.
#
# The dirty suffix exists because an uncommitted change otherwise rebuilds to the same filename
# with different contents. It sorts after that commit's clean build and before the next commit.
mesa_pkg_version() {
    local dir=$1 ver count sha dirty=""
    ver=$(tr -d '\n' < "$dir/VERSION")
    count=$(git -C "$dir" rev-list --count HEAD 2>/dev/null || echo 0)
    sha=$(git -C "$dir" rev-parse --short=8 HEAD 2>/dev/null || echo unknown)
    git -C "$dir" diff --quiet HEAD -- 2>/dev/null || dirty="+dirty$(LC_ALL=C date -u '+%Y%m%d%H%M%S')"
    echo "${ver}+droidvm.r${count}.g${sha}+deb13gaming1${dirty}"
}
