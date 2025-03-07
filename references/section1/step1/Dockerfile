# ベースイメージにAlpine Linuxを使用
FROM alpine:latest

# Zigコンパイラをインストール
RUN apk add --no-cache zig

# 一般ユーザー 'appuser' を作成し、作業用ディレクトリを設定
RUN addgroup -S appgroup && \
  adduser -S appuser -G appgroup

# 作業ディレクトリを作成し、所有者をappuserに設定
RUN mkdir -p /app && chown -R appuser:appgroup /app

# 作業ディレクトリを指定
WORKDIR /app

# ホスト側のファイルをコンテナ内にコピーし、appuserに所有権を設定
COPY --chown=appuser:appgroup . .

# 一般ユーザーに切り替え
USER appuser

CMD ["zig", "build", "run"]
