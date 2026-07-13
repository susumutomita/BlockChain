# ベースイメージに Alpine Linux を使用
FROM alpine:latest

# zig の公式バイナリをダウンロードするために必要なツールをインストール
# xz パッケージを追加して tar が .tar.xz を解凍できるようにする
RUN apk add --no-cache curl tar xz

# ZigとコンテナのCPUアーキテクチャを指定する
ARG ZIG_VERSION=0.14.0
ARG TARGETARCH
ENV ZIG_VERSION=${ZIG_VERSION}

# amd64とarm64のどちらでも、対応する公式バイナリを展開する
RUN case "${TARGETARCH}" in \
      amd64) ZIG_ARCH=x86_64 ;; \
      arm64) ZIG_ARCH=aarch64 ;; \
      *) echo "unsupported architecture: ${TARGETARCH}" >&2; exit 1 ;; \
    esac && \
    ZIG_DIST="zig-linux-${ZIG_ARCH}-${ZIG_VERSION}" && \
    curl -fLO "https://ziglang.org/download/${ZIG_VERSION}/${ZIG_DIST}.tar.xz" && \
    mkdir -p /opt/zig && \
    tar -xf "${ZIG_DIST}.tar.xz" -C /opt/zig --strip-components=1 && \
    rm "${ZIG_DIST}.tar.xz"
ENV PATH="/opt/zig:${PATH}"

# 一般ユーザー appuser を作成し、作業用ディレクトリを設定
RUN addgroup -S appgroup && \
  adduser -S appuser -G appgroup && \
  mkdir -p /app && chown -R appuser:appgroup /app

# 作業ディレクトリを /app に設定
WORKDIR /app

# ホスト側のファイルをコンテナ内にコピーし、所有者を appuser に設定
COPY --chown=appuser:appgroup . .

# 一般ユーザーに切り替え
USER appuser

# コンテナ起動時に Zig ビルドシステムを使って run を実行
CMD ["zig", "build", "run"]
