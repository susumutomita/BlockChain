# ベースイメージに Alpine Linux を使用
FROM alpine:latest

# zig の公式バイナリをダウンロードするために必要なツールをインストール
# xz パッケージを追加して tar が .tar.xz を解凍できるようにする
RUN apk add --no-cache curl tar xz

# Zig のバージョンを指定可能にするビルド引数（デフォルトは 0.14.0）
ARG ZIG_VERSION=0.14.0
# ここでは x86_64 用のバイナリを使用する例です
ENV ZIG_DIST=zig-linux-x86_64-${ZIG_VERSION}
ENV ZIG_VERSION=${ZIG_VERSION}

# 指定された Zig のバージョンを公式サイトからダウンロードして解凍し、PATH に追加
RUN curl -LO https://ziglang.org/download/${ZIG_VERSION}/${ZIG_DIST}.tar.xz && \
  tar -xf ${ZIG_DIST}.tar.xz && \
  rm ${ZIG_DIST}.tar.xz
ENV PATH="/${ZIG_DIST}:${PATH}"

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
