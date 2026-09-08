# Linux toolchain for the parts of LocalGallery that are not Apple-only.
#
#   docker build -t localgallery-dev .
#   docker run --rm -it -v "$PWD":/work -w /work localgallery-dev
#   cd core && cargo test --workspace
#
# What this image can do:
#   - `cd core && cargo test --workspace` (host target; first run needs net
#     for crates.io and the ORT download-binaries cache)
#   - rustfmt / clippy / rust-analyzer against the pin in
#     `core/rust-toolchain.toml`
#   - `cargo run -p uniffi-bindgen` (the Rust bindgen; Swift output is just
#     text — assembling the xcframework is still macOS)
#   - `python3 scripts/gen_conformance_assets.py` (needs exiftool)
#   - `uv run scripts/generate_test_library.py` (Pillow / piexif pulled by uv)
#   - `scripts/prepare_pack.sh` once a pack exists under `build/model_packs/`
#   - the model-pack *venv* (`scripts/build_model_pack/requirements.txt`) —
#     torch is ~350 MB and is not baked in; create the venv when you need it
#
# What it cannot do (needs Xcode / an iOS SDK / Apple silicon link flags):
#   - `scripts/build_core.sh` (xcframework + libtool merge for iOS slices)
#   - `xcodegen` / `xcodebuild` / the Swift unit tests
#   - the Apple targets listed in `core/rust-toolchain.toml`
#     (`aarch64-apple-darwin`, `aarch64-apple-ios`, `aarch64-apple-ios-sim`)
#
# Do not COPY the repo. Mount it, or let Cursor check the commit out.

FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive \
    RUSTUP_HOME=/usr/local/rustup \
    CARGO_HOME=/usr/local/cargo \
    UV_INSTALL_DIR=/usr/local/bin \
    PATH=/usr/local/cargo/bin:${PATH} \
    RUST_VERSION=1.97.1 \
    RUSTUP_TOOLCHAIN=1.97.1

# RUSTUP_TOOLCHAIN pins rustup to the host std. Without it, `cd core && cargo`
# would read rust-toolchain.toml and try to download the Apple targets.

RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential \
        ca-certificates \
        clang \
        cmake \
        curl \
        fd-find \
        file \
        git \
        jq \
        libimage-exiftool-perl \
        libssl-dev \
        lld \
        ninja-build \
        pkg-config \
        python3 \
        python3-dev \
        python3-pip \
        python3-venv \
        ripgrep \
        sudo \
        unzip \
        xz-utils \
        libgtk-4-dev \
        libadwaita-1-dev \
        libgdk-pixbuf-2.0-dev \
    && ln -sf "$(command -v fdfind)" /usr/local/bin/fd \
    && rm -rf /var/lib/apt/lists/*

# Passwordless sudo for the default cloud-agent / interactive user.
RUN id -u ubuntu >/dev/null 2>&1 || useradd -m -s /bin/bash ubuntu \
    && usermod -aG sudo ubuntu \
    && echo "ubuntu ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/ubuntu \
    && chmod 0440 /etc/sudoers.d/ubuntu

# Pinned to core/rust-toolchain.toml. Host std only — the Apple targets in
# that file need the iOS SDK. rust-src + rust-analyzer are for editor work
# against the core crates.
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
        | sh -s -- -y --default-toolchain "${RUST_VERSION}" \
            --profile minimal --no-modify-path \
            -c rustfmt -c clippy -c rust-src -c rust-analyzer \
    && chmod -R a+w "${RUSTUP_HOME}" "${CARGO_HOME}" \
    && rustc --version && cargo --version && rust-analyzer --version

# uv runs `scripts/generate_test_library.py` (PEP 723 script deps) without
# a hand-rolled venv. Model-pack torch still goes in that script's own venv.
RUN curl --proto '=https' --tlsv1.2 -LsSf https://astral.sh/uv/install.sh \
        | env UV_INSTALL_DIR="${UV_INSTALL_DIR}" sh \
    && uv --version

USER ubuntu
WORKDIR /work
