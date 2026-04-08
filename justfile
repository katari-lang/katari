set shell := ["bash", "-euo", "pipefail", "-c"]

[private]
default:
    @just --list

rust_dir := justfile_directory() / "rust"

# --- 全体 ---

# ビルド（Haskell + Rust）
build: build-hs build-rust

# テスト（Haskell + Rust）
test: test-hs test-rust

# クリーン（Haskell + Rust）
clean: clean-hs clean-rust

# フォーマット（Haskell + Rust）
fmt: fmt-hs fmt-rust

# --- Haskell ---

# 全 Haskell パッケージをビルド
build-hs:
    stack build

# コンパイラのみビルド
build-compiler:
    stack build katari-compiler

# CLI のみビルド
build-cli:
    stack build katari-cli

# LSP のみビルド
build-lsp:
    stack build katari-lsp

# 全 Haskell テスト
test-hs:
    stack test

# 特定パッケージのテスト（例: just test-hs-pkg katari-compiler）
test-hs-pkg pkg:
    stack test {{ pkg }}

# katari CLI を実行
run-cli *args:
    stack run katari -- {{ args }}

# LSP サーバーを実行
run-lsp:
    stack run katari-lsp

# Haskell ビルドキャッシュを削除
clean-hs:
    stack clean

# Haskell をファイル変更監視でビルド
watch-hs:
    stack build --file-watch

# stylish-haskell でフォーマット
fmt-hs:
    find haskell -name "*.hs" -not -path "*/.stack-work/*" -exec stylish-haskell -i {} \;

# hlint でリント
lint-hs:
    hlint haskell

# --- Rust ---

# Rust ビルド（デバッグ）
build-rust:
    cargo build --manifest-path {{ rust_dir }}/Cargo.toml

# Rust ビルド（リリース）
build-rust-release:
    cargo build --release --manifest-path {{ rust_dir }}/Cargo.toml

# Rust テスト
test-rust:
    cargo test --manifest-path {{ rust_dir }}/Cargo.toml

# ランタイムを実行
run-runtime *args:
    cargo run --manifest-path {{ rust_dir }}/Cargo.toml -p katari-runtime -- {{ args }}

# Rust ビルドキャッシュを削除
clean-rust:
    cargo clean --manifest-path {{ rust_dir }}/Cargo.toml

# cargo fmt でフォーマット
fmt-rust:
    cargo fmt --manifest-path {{ rust_dir }}/Cargo.toml

# clippy でリント
lint-rust:
    cargo clippy --manifest-path {{ rust_dir }}/Cargo.toml -- -D warnings

# Rust 型チェックのみ（高速）
check-rust:
    cargo check --manifest-path {{ rust_dir }}/Cargo.toml
