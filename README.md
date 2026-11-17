# x86_cpu_fpga

Tang Primer 25K (Gowin GW5A-LV25MG121) 上で動作する x86互換 32ビット CPU を
ゼロから設計・実装するプロジェクトです。

## 目標

x86 命令セットのサブセットを段階的に実装し、最終的にアセンブリで書いた
ゲームプログラムを実行できる CPU + SoC を構築します。

## 開発ロードマップ

| Phase | 内容 | 状態 |
|:------|:-----|:-----|
| 1 | 開発環境セットアップ & LED点滅 | ✅ 完了 |
| 2 | 基本コンポーネント (ALU, レジスタ, メモリ) | ✅ 完了 |
| 3 | 最小限CPUコア (8086互換) | ✅ 完了 (シミュレーション検証、実機は未確認) |
| 4 | UART & デバッグ環境 | ✅ 完了 (シミュレーション検証、実機は未確認) |
| 5 | 8086命令セット拡張 | 🔧 次のステップ |
| 6 | 32ビット拡張 (i386) | ⬜ |
| 7 | SDRAMコントローラ | ⬜ |
| 8 | 周辺機器 & ゲーム環境 | ⬜ |

## ディレクトリ構成

```
x86_cpu_fpga/
├── src/                      # Verilog ソースファイル
│   ├── x86_defines.vh        # 共通定義 (ALU演算コード, レジスタ番号, CPUステート等)
│   ├── blinky.v              # LED点滅テスト (Phase 1)
│   ├── alu.v                 # 32ビットALU (x86フラグ完全対応)
│   ├── register_file.v       # x86レジスタファイル (8/16/32bit対応)
│   ├── memory_controller.v   # メモリコントローラ (B-SRAM, 同期読み出し)
│   ├── cpu_core.v            # CPUコア (8086互換サブセット, Phase 3)
│   ├── uart.v                # UART 送受信 (115200 baud, 受信FIFO付き, Phase 4)
│   ├── debug_reporter.v      # CPU停止時に IP とオペコードを UART へ出力
│   └── soc_top.v             # 実機用トップ (CPU + ROM + RAM + UART + LED/ボタン)
├── sim/                      # テストベンチ
│   ├── tb_blinky.v
│   ├── tb_alu.v
│   ├── tb_register_file.v
│   ├── tb_memory_controller.v
│   ├── tb_cpu_core.v         # CPUコア テスト (自己診断プログラムを実行)
│   ├── tb_cpu_cosim.v        # 差分テスト用トレース出力 (tools/cosim.py が使用)
│   ├── tb_uart.v
│   ├── tb_soc_top.v          # 実機用トップのテスト (LEDデモを実行)
│   ├── tb_soc_monitor.v      # 実機用トップのテスト (UARTモニタを操作)
│   └── programs/
│       ├── cpu_test.asm      # 自己診断プログラム (NASM)
│       ├── cpu_test.hex      # ↑ のアセンブル結果 ($readmemh 形式)
│       └── hello_upload.txt  # hello.asm を書き込むモニタコマンド (tb_soc_monitor 用)
├── firmware/                 # 実機で動かすプログラム
│   ├── monitor.asm           # UARTモニタ (ROM の既定の内容)
│   ├── monitor.hex
│   ├── led_demo.asm          # LEDカウンタ デモ (UART を使わない動作確認用)
│   ├── led_demo.hex
│   └── examples/
│       └── hello.asm         # モニタから読み込んで実行するプログラムの例
├── tools/
│   ├── bin2hex.py            # NASM の出力 (.bin) → .hex 変換
│   ├── cosim.py              # Unicorn エミュレータとの差分テスト
│   └── upload.py             # UARTモニタ経由でプログラムを書き込んで実行
├── constraints/              # FPGA制約ファイル
│   ├── tang_primer_25k.cst   # ピン制約
│   └── timing.sdc            # タイミング制約
└── README.md
```

## CPUコア (Phase 3)

`src/cpu_core.v` は 16ビット リアルモードで動作するマルチサイクル CPU です。
`alu.v` と `register_file.v` を内部で使用し、`memory_controller.v` と接続して動作します。
リセット後は `F000:FFF0` から実行を開始します。

### 実行の流れ

```
FETCH → MODRM → DISP → IMM → EA → LOAD → EXECUTE → STORE
```

命令に不要なステートは飛ばします (例: `MOV AX, imm16` は FETCH → IMM → EXECUTE)。
メモリは同期読み出しのため、読み出し 1 回に 2 クロックかかります
(FETCH・MODRM・DISP・IMM・LOAD が各 2 クロック、EA・EXECUTE・STORE が各 1 クロック)。
自己診断プログラムでの平均は 1 命令あたり約 5.3 クロックです。

### 実装済みの命令

| 分類 | 命令 |
|:-----|:-----|
| データ転送 | `MOV` (レジスタ/メモリ/即値/セグメントレジスタ/moffs), `LEA`, `PUSH`, `POP` |
| 算術・論理 | `ADD` `OR` `ADC` `SBB` `AND` `SUB` `XOR` `CMP` `TEST` `INC` `DEC` `NOT` `NEG` |
| 分岐 | `JMP` (short/near/far/間接), `Jcc`, `CALL` (near/間接), `RET`, `LOOP` `LOOPE` `LOOPNE` `JCXZ` |
| フラグ | `CLC` `STC` `CMC` `CLI` `STI` `CLD` `STD` |
| I/O | `IN` `OUT` (imm8 / DX) |
| その他 | `NOP`, `HLT`, セグメントオーバーライド (`ES:` `CS:` `SS:` `DS:`) |

アドレッシングモードは 16ビットの ModR/M 全種類 (`[BX+SI+disp]` など) に対応しています。

### 未実装 (Phase 5 以降)

割り込み (`INT`/`IRET`)、ストリング命令 (`MOVS` 等と `REP`)、シフト・ローテート、`MUL`/`DIV`、
far `CALL`/`RETF`、`PUSHF`/`POPF`、`XCHG` など。
未実装の命令を実行しようとすると CPU は停止し、`fault` 出力が 1 になります
(`dbg_ip` / `dbg_opcode` で場所と命令コードを確認できます)。

### 外部インターフェース

| 信号 | 説明 |
|:-----|:-----|
| `mem_addr` `mem_wdata` `mem_rdata` `mem_size` `mem_rd` `mem_wr` `mem_ready` | メモリバス。`mem_ready` が 1 になるまで要求を保持するので、ウェイトを挿入するメモリも接続可能 |
| `io_addr` `io_wdata` `io_rdata` `io_size` `io_rd` `io_wr` | I/O ポートバス (`IN`/`OUT` 命令) |
| `halted` | `HLT` で停止中 |
| `fault` | 未実装命令で停止中 |
| `inst_done` `dbg_ip` `dbg_opcode` | デバッグ用 (命令完了パルス、実行中の命令の IP とオペコード) |

## 実機で動かす (Tang Primer 25K)

`src/soc_top.v` は CPUコア・ROM・RAM・UART・LED/ボタンをまとめた実機用のトップモジュールです。

> シミュレーションと yosys での合成確認までで、実機ではまだ動作確認していません。

### Gowin EDA での手順

1. プロジェクトに次のファイルを追加します。
   - `src/soc_top.v` `src/cpu_core.v` `src/alu.v` `src/register_file.v`
     `src/memory_controller.v` `src/uart.v` `src/debug_reporter.v` `src/x86_defines.vh`
   - `constraints/tang_primer_25k.cst` `constraints/timing.sdc`
2. トップモジュールを `soc_top` にします (`blinky.v` は不要です)。
3. LED のピン (E8, D7) は READY / DONE との兼用ピンです。`blinky.v` のときと同じく、
   Dual-Purpose Pin の設定で READY と DONE を通常の I/O として使う設定にします。
4. 合成・配置配線して書き込みます。

ROM の内容は `firmware/monitor.hex` (UARTモニタ) から読み込みます (`soc_top` の `INIT_FILE` パラメータ)。
相対パスのため、合成時にファイルが見つからない場合は `INIT_FILE` を絶対パスに変更してください。

### 期待する動作

- LED 0 が点灯します (モニタが動作中)。
- PC からシリアルポート (115200 baud, 8N1) を開いてリセットボタンを押すと、
  `x86_cpu_fpga monitor (? = help)` と表示され、`> ` のプロンプトが出ます。
- 2 個の LED が交互に点滅し続ける場合は、CPU が未実装命令で停止しています (`fault`)。

UART がうまく動かないときは、`INIT_FILE` を `firmware/led_demo.hex` に変えると UART を使わずに
CPU の動作だけを確認できます (2 個の LED が 2 進カウンタとして 1 ステップ約 0.26 秒で変化し、
ユーザーボタンを押している間は逆向きにカウントします)。

### 合成後に確認する点

- リソース使用量: B-SRAM が 18 ブロック使われていること (RAM 32KB = 16、ROM 4KB = 2)。
  yosys での概算は LUT 約 5,400 / 23,040、FF 約 500 です。
  B-SRAM が 0 で LUT が大幅に増えている場合は、メモリが B-SRAM として推論されていません。
- タイミング: 50 MHz (20 ns) を満たしていること。満たさない場合はクロックを下げる必要があります。

### メモリマップ

| 物理アドレス | 内容 |
|:-------------|:-----|
| `0x00000` - `0x7FFFF` | RAM 32KB (繰り返し)。通常は `0000:0000` - `0000:7FFF` として使用 |
| `0x80000` - `0xFFFFF` | ROM 4KB (繰り返し、書き込み不可)。通常は `F000:F000` - `F000:FFFF` として使用 |

リセット後は `F000:FFF0` (ROM の末尾 16 バイト) から実行を開始します。

### I/O ポート

| ポート | 方向 | 内容 |
|:-------|:-----|:-----|
| `0x00` | 書き込み / 読み出し | LED レジスタ (bit 0 = `led[0]`, bit 1 = `led[1]`) |
| `0x01` | 読み出し | ボタン (bit 0 = ユーザーボタン) |
| `0x10` | 書き込み | UART 送信 (送信中の書き込みは無視されます) |
| `0x10` | 読み出し | UART 受信 (受信 FIFO から 1 バイト取り出します。FIFO は 16 バイト) |
| `0x11` | 読み出し | UART ステータス (bit 0 = 受信データあり, bit 1 = 送信可能) |

### ROM のプログラムの変更

`firmware/monitor.asm` や `firmware/led_demo.asm` を変更したら `.hex` を作り直して、再度合成します。

```bash
nasm -f bin -o firmware/monitor.bin firmware/monitor.asm
python3 tools/bin2hex.py firmware/monitor.bin firmware/monitor.hex
```

## UART モニタ (Phase 4)

ROM に入っているモニタ (`firmware/monitor.asm`) を使うと、PC のシリアルターミナルから
メモリの読み書きとプログラムの実行ができます。FPGA を再合成せずにプログラムを試せます。

### 接続

ボード上の USB デバッガのシリアルポートを 115200 baud, 8 データビット, パリティなし,
ストップビット 1 で開きます。行末は CR (Enter キー) です。

### コマンド

数値はすべて 16 進数、アドレスはセグメント 0 のオフセットです。

| コマンド | 内容 |
|:---------|:-----|
| `d ADDR [LEN]` | メモリを LEN バイト表示 (省略時 40) |
| `w ADDR BYTE...` | メモリにバイト列を書き込み |
| `g ADDR` | `0000:ADDR` のプログラムを実行 |
| `?` | ヘルプ |

```
x86_cpu_fpga monitor (? = help)
> w 0200 de ad be ef
> d 200 4
0200: DE AD BE EF
>
```

入力に誤りがあると `?` と表示されます。

### プログラムの書き込みと実行 (tools/upload.py)

`tools/upload.py` はモニタの `w` コマンドでプログラムを RAM に書き込み、`d` で読み返して照合し、
`g` で実行します。実行後はプログラムの出力を表示し続けます (Ctrl-C で終了)。

```bash
pip install pyserial

nasm -f bin -o firmware/examples/hello.bin firmware/examples/hello.asm
python3 tools/upload.py COM5 firmware/examples/hello.bin     # Linux では /dev/ttyUSB1 など
```

```
loading 53 bytes at 0100 ...
verify ok
running (Ctrl-C to quit)
g 0100
Hello from RAM!

x86_cpu_fpga monitor (? = help)
>
```

### モニタから実行するプログラムの書き方

`firmware/examples/hello.asm` を参考にしてください。

- `org 0x100` でアセンブルします (読み込み先は `--addr` で変更できます)。
- 開始時は `CS=DS=ES=SS=0` で、スタックは設定済みです。
- モニタに戻るときは `jmp 0xF000:0xF000` を実行します (モニタが再起動します)。
- RAM の `7E00` - `7FFF` はモニタが使用します。
- 文字の送信は、ポート `0x11` の bit 1 が 1 になるのを待ってからポート `0x10` に書き込みます。

### CPU 停止時のレポート

CPU が停止すると、ハードウェア (`debug_reporter.v`) が停止した命令のアドレスとオペコードを
UART に 1 行出力します。未実装命令を踏んだ場所がすぐに分かります。

```
*** FAULT IP=0300 OP=0F      未実装命令で停止
*** HALT  IP=0311 OP=F4      HLT 命令で停止
```

停止後はリセットボタンでモニタに戻ります。RAM の内容はリセットしても残ります。

## ターゲットボード

- **FPGA**: Sipeed Tang Primer 25K (Gowin GW5A-LV25MG121NC1/I0)
- **LUT4**: 23,040
- **FF**: 23,040
- **B-SRAM**: 1,008 Kbits (56ブロック)
- **クロック**: 50 MHz

## シミュレーション実行方法

コマンドはすべてリポジトリのルートで実行します。

### Icarus Verilog を使用する場合

```bash
# ALU テスト
iverilog -I src -o sim/tb_alu.out sim/tb_alu.v src/alu.v
vvp sim/tb_alu.out

# レジスタファイル テスト
iverilog -I src -o sim/tb_regfile.out sim/tb_register_file.v src/register_file.v
vvp sim/tb_regfile.out

# メモリコントローラ テスト
iverilog -I src -o sim/tb_mem.out sim/tb_memory_controller.v src/memory_controller.v
vvp sim/tb_mem.out

# CPUコア テスト (自己診断プログラム cpu_test.hex を実行)
iverilog -I src -o sim/tb_cpu_core.out sim/tb_cpu_core.v src/cpu_core.v src/alu.v src/register_file.v src/memory_controller.v
vvp sim/tb_cpu_core.out

# UART テスト
iverilog -o sim/tb_uart.out sim/tb_uart.v src/uart.v
vvp sim/tb_uart.out

# 実機用トップ テスト (firmware/led_demo.hex を実行)
iverilog -I src -o sim/tb_soc_top.out sim/tb_soc_top.v src/soc_top.v src/cpu_core.v src/alu.v src/register_file.v src/memory_controller.v src/uart.v src/debug_reporter.v
vvp sim/tb_soc_top.out

# 実機用トップ テスト (UARTモニタを操作し、hello.asm を書き込んで実行)
iverilog -I src -o sim/tb_soc_monitor.out sim/tb_soc_monitor.v src/soc_top.v src/cpu_core.v src/alu.v src/register_file.v src/memory_controller.v src/uart.v src/debug_reporter.v
vvp sim/tb_soc_monitor.out
```

CPUコア テストに `+trace` を付けると、実行した命令ごとにレジスタの値を表示します。
モニタのテストに `+show` を付けると、UART に出力された文字をそのまま表示します。

```bash
vvp sim/tb_cpu_core.out +trace
vvp sim/tb_soc_monitor.out +show
```

### テストプログラムの再アセンブル

`sim/programs/cpu_test.asm` を変更した場合は `.hex` を作り直します。

```bash
nasm -f bin -o sim/programs/cpu_test.bin sim/programs/cpu_test.asm
python3 tools/bin2hex.py sim/programs/cpu_test.bin sim/programs/cpu_test.hex
```

`firmware/examples/hello.asm` を変更した場合は、モニタのテストが使うコマンドファイルを作り直します。

```bash
nasm -f bin -o firmware/examples/hello.bin firmware/examples/hello.asm
python3 tools/upload.py --script sim/programs/hello_upload.txt firmware/examples/hello.bin
```

### Unicorn エミュレータとの差分テスト

実装済みの命令からランダムなプログラムを生成し、CPUコア (RTL) と x86 エミュレータ
[Unicorn](https://www.unicorn-engine.org/) の両方で実行して、1 命令ごとのレジスタ・フラグ、
メモリ書き込み、I/O アクセスを比較します。CPUコアを変更したら実行してください。

```bash
pip install unicorn

python3 tools/cosim.py              # 200 シード
python3 tools/cosim.py -n 1000      # シード数を増やす
python3 tools/cosim.py --stall      # メモリにランダムなウェイトを挿入して実行
python3 tools/cosim.py --seed 42    # 失敗したシードを再現
```

### 波形表示

```bash
gtkwave tb_alu.vcd
```

## ツール

- **Gowin EDA** - 論理合成・配置配線
- **Icarus Verilog** - シミュレーション
- **GTKWave** - 波形表示
- **NASM** - x86アセンブラ
- **Python 3 + Unicorn** - 差分テスト (任意)
- **Python 3 + pyserial** - プログラムの書き込み (`tools/upload.py`)