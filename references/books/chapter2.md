---
title: "開発環境のセットアップ"
free: true
---

開発を始める前に必要な**環境セットアップ**を行います。
本章では、Zigの開発環境をDocker上に構築し、マルチノードのブロックチェイン実行環境やCI/CD（継続的インテグレーション/デリバリー）の設定方法について詳しく解説します。
Dockerコンテナ内でZigをビルド・実行する方法からはじめ、Docker Composeによる複数ノードの協調動作、そしてGitHub Actionsを使ったCI/CD導入の背景までを行います。

## はじめに

ZigはC言語に近い構文と性能を持ちながらも、メモリセーフティやエラーハンドリングなどの機能を備えています。ブロックチェインのような**高い信頼性が求められるアプリケーション**にも適しており、本チュートリアルではその特性を活かしてブロックチェインの基本構造を実装していきます。
本チュートリアルでは、Zigを使って**ブロックチェインの基本要素**（ブロック、トランザクション、ハッシュ計算、Proof of Work）を実装し、最終的には**シンプルなブロックチェイン**を完成させます。ブロックチェインの仕組みやZigの基本的な使い方についても解説しますので、Zigやブロックチェインに興味がある方はぜひお試しください。

学習ソースとしては[Zig Book](https://github.com/pedropark99/zig-book)がオススメです。

## Zigの環境セットアップ

まずはZigの開発環境を整えます。

### Zigのインストール方法

Zig公式サイトから各プラットフォーム向けのバイナリをダウンロードし、パスを通すのが最も手軽な方法です ([Getting Started⚡Zig Programming Language](https://ziglang.org/learn/getting-started/))。Zigはインストールがシンプルで、単一の実行ファイルを好きな場所に置いてパスを設定すれば利用できます。
インストール後、ターミナル/コマンドプロンプトで `zig version` を実行し、バージョンが表示されれば成功です。Mac + Homebrewの場合は`brew install zig`でインストールできます。

```bash
❯ zig version
0.14.0
```

### ビルドツールとエディタの準備

Zigは独自のビルドシステムを備えており、`zig build`コマンドでプロジェクトのコンパイルや実行が可能です。プロジェクトを開始するには、空のディレクトリで `zig init` コマンドを実行すると、ビルド用の設定ファイルとサンプルのソースコードが生成されます。生成された`build.zig`と`src/main.zig`を使って、`zig build run`とするだけでHello Worldプログラムをビルド&実行できます。Zig製の実行ファイルはネイティブなバイナリで、特別なVMは不要です。
エディタはお好みのものを使用できますが、**VSCode**には公式のZig拡張機能がありシンタックスハイライトや補完が利用できます。また、Zig用の言語サーバー (Zig Language Server, *ZLS*) も提供されており、より高度なエディタ連携が可能です。主要なテキストエディタにはZigのシンタックスハイライトが用意されていますので、まずはコードが見やすい環境を整えましょう。

### プロジェクトの作成

```bash
❯ zig init
info: created build.zig
info: created build.zig.zon
info: created src/main.zig
info: created src/root.zig
info: see `zig build --help` for a menu of options
```

### 簡単なHello Worldプログラムの実行

環境確認のため、簡単なZigプログラムを作成してみます。src/main.zigを更新して、以下のコードを書いてください。

```zig
const std = @import("std");

pub fn main() !void {
    const stdout = std.io.getStdOut().writer();
    try stdout.print("Hello, {s}\n", .{"world"});
}
```

次に、準備したターミナルで次のコマンドを実行してみましょう。

```bash
zig build run
```

`zig run`コマンドはソースをビルドして即座に実行してくれます。正しく環境構築できていれば、コンソールに **Hello, world** と表示されるはずです。これでZigの開発環境は準備完了です。

## DockerでZigを動作させる環境を構築する

Zigは静的コンパイル言語であり、生成されたバイナリは他の依存関係が少ないためコンテナなしでも動作させやすいという特長があります。
しかし、一台の開発環境としてDockerを利用することで**ローカルにツールチェインをインストールせずに**済み、チームで統一された環境を手軽に再現できます。
ここではDockerコンテナ内でZigを使うためのセットアップ手順を紹介します。

**Dockerイメージの作成**: まず、Zigコンパイラを含むDockerイメージを用意します。公式には軽量なAlpine LinuxでZigをインストールする方法があります。Alpineの最新リリース（edge）では`apk`パッケージマネージャからZigを導入できます。以下にシンプルなDockerfileの例を示します。

```Dockerfile
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
```

上記のDockerfileでは、Alpineイメージを基に[ダウンロードサイト](https://ziglang.org/download/)からZigをインストールしています。`WORKDIR /app`は作業ディレクトリを設定しており、後でソースコードをここに配置してビルドできるようにしています。

## Docker ComposeでDockerを動作させる

ブロックチェインの学習やテストのために、単一マシン上で**複数のノード**を動作させ、相互に通信させることがあります。Docker Compose(以下Compose)を使うと、複数のコンテナ（サービス）を一括して定義・管理でき、各コンテナ同士のネットワーク設定も自動的に行ってくれます。Composeを用いることで、例えば3台のノードが協調して動作するプライベートなブロックチェインネットワークを1つのマシン上に構築可能です。

**コンテナ間通信とネットワーク**: 同じdocker-compose.yml内で定義されたコンテナ同士は、デフォルトで**共通のネットワーク**に接続されます ([link](https://docs.docker.jp/compose/networking.html#))。そのため、特別な設定をしなくても互いに通信可能で、各コンテナはサービス名をホスト名（DNS名）としてお互いを認識できます。つまり、Composeで定義したサービス`node1`からサービス`node2`に対しては、コンテナ内でホスト名`node2`を指定することで通信できます。

以下に、3つのノードサービスを持つdocker-compose.ymlを作成します。各サービスは同じイメージ（先ほど作成した`myzigapp`など、Zigで実装したブロックチェインノードの実行環境）を使い、ポートと環境変数で区別しています。
プロジェクトのルートディレクトリに`docker-compose.yml`を作成し、以下の内容を記述してください。

```yaml
services:
  node1:
    build: .
    platform: linux/amd64
    container_name: node1
    ports:
      - "3001:3000"
    environment:
      - NODE_ID=1
  node2:
    build: .
    platform: linux/amd64
    container_name: node2
    ports:
      - "3002:3000"
    environment:
      - NODE_ID=2
  node3:
    build: .
    platform: linux/amd64
    container_name: node3
    ports:
      - "3003:3000"
    environment:
      - NODE_ID=3
```

上記Composeファイルでは、`node1`〜`node3`という3つのサービスが定義されています。
それぞれ同じイメージからコンテナを立ち上げますが、環境変数`NODE_ID`に異なる値を与えることでノードごとの設定を変えています。例えばZigのプログラムが`NODE_ID`を読んでポートやピア接続先を変える実装にしておけば、コンテナごとに振る舞いを変えることができます。`ports`で各ノードのホスト側ポートをずらして割り当てているのは、同一ホスト上でポート競合を避けつつ、必要なら個別ノードにホストマシンからアクセスできるようにするためです。

Composeを使ってこの構成を起動すれば、`node1`, `node2`, `node3`のコンテナが立ち上がり、前述のように相互にホスト名で発見しあえるネットワークに接続されます。例えば`node1`コンテナ内から`node2:3000`（コンテナ名`node2`のポート3000）にリクエストを送ることで、ノード2との通信が可能です。

複数のノードをこのようにコンテナで再現することで、1台の開発マシン上でも疑似的な分散環境を構築できます。各ノードは独立したプロセス（コンテナ）として動作するため、ノード間通信やネットワークの挙動を検証しやすくなります。

## Docker Composeで複数ノードを動作させる

Composeを使って複数ノードを動作させてみます。以下のコマンドを実行してComposeを起動します。

```bash
❯ docker compose up
[+] Running 3/3
 ✔ Container node1  Recreate...                   0.1s
 ✔ Container node3  Recreate...                   0.1s
 ✔ Container node2  Recreate...                   0.1s
Attaching to node1, node2, node3
node2  | Hello, world
node1  | Hello, world
node3  | Hello, world
node2 exited with code 0
node3 exited with code 0
node1 exited with code 0
```

上記のように、3つのノードがそれぞれHello Worldプログラムを実行して終了しました。Composeを終了するには`Ctrl+C`を押してください。

## GitHub Actions導入

最後に、GitHub Actionsを用いたCI/CDを導入する理由とそのメリットについて説明します。
ソフトウェア開発における**CI/CD（継続的インテグレーション/継続的デリバリー）**とは、コードのビルド・テストからデプロイまでの一連のプロセスを自動化し、継続的に実行する手法です。
CI/CDを導入しておくと開発者がコードをリポジトリにコミットすると自動でビルドとテストが走るため、バグやコンパイルエラーを早い段階で発見できます。
本書ではGitHub Actionsを使ってCI/CDを導入します。

**GitHub Actionsとは**: [GitHub Actions](https://docs.github.com/en/actions/about-github-actions)はGitHubに統合されたCI/CDプラットフォームです。GitHub Actionsを使うとリポジトリ上で発生したイベントをトリガーにして自動的にワークフローを実行できます。
GitHub上でホストされたLinux/Windows/macOSのランナー（仮想マシン）上でジョブを実行できるので、外部に専用のCIサーバーを用意する必要がありません。
.github/workflows/ci.ymlというファイルを作成し、以下の内容を記述してください。

```yaml
name: Zig CI

permissions:
  contents: read

on:
  push: {}
  pull_request: {}

jobs:
  build-and-test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Setup Zig
        uses: goto-bus-stop/setup-zig@v2
        with:
          version: 0.14.0
          cache: false

      - name: Run tests
        run: zig build test
```

上記のYAMLでは、`main`ブランチへのプッシュやプルリクエストをトリガーとしてワークフローが走ります。ジョブはUbuntu環境で実行され、まずリポジトリのコードをチェックアウトします。次にコミュニティ提供の`goto-bus-stop/setup-zig`アクションを使ってZigコンパイラをインストールしています。`with:`セクションでZigのバージョンを指定して利用するZigのバージョンを固定しています。最後に`zig build test`を実行し、プロジェクトのビルドおよびテスト（Zigのビルトインテストを利用）を行います。
このCI設定により、GitHub上でコード変更があるたびに自動でコンテナ内と同じ環境でビルド・テストが行われ、その結果がGitHub上で確認できます。仮にテストが失敗した場合は開発者に通知されるため、問題を早期に発見して修正できます。GitHub Actionsの設定はリポジトリと一緒にバージョン管理されるため、プロジェクトに参加した他の開発者も同じCIパイプラインを共有できます。また、ActionsはGitHubに組み込まれているので、追加のサービス契約なしに利用開始でき、オープンソースであれば無料枠内で相当数の実行が可能です。
